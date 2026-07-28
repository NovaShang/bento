package acphost

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/google/uuid"
)

// agentInstance is one running ACP agent, decoupled from any stream — the
// unit of persistence (the tmux-session analogue). Clients attach and
// detach; the agent keeps running in between.
//
// Attachment is MULTI-SUBSCRIBER: any number of streams may be attached at
// once (Mac + iPhone co-viewing one agent). Agent→client traffic broadcasts
// to every attached stream; client→agent traffic is merged. The daemon must
// be minimally JSON-RPC aware to make that safe:
//
//   - client→agent request ids are rewritten into the instance's own id
//     space so concurrent attachments can both use "1" without collision;
//     each response is mapped back and delivered ONLY to the stream that
//     issued the request (JSON-RPC responses are point-to-point). Other
//     attached streams learn of a finished turn via a `turnDone` control.
//   - agent→client REQUESTS split by who can answer them. The ones for the
//     USER (permission, elicitation) are broadcast to every attached stream
//     and queued until answered; the FIRST answer wins, later duplicates are
//     dropped (the agent must see exactly one response), and answering
//     broadcasts `requestAnswered` so the other viewers' cards go away
//     instead of lingering forever. While nobody is attached they stay
//     queued and replay on the next attach — a mid-turn permission simply
//     waits. The ones for the HOST (fs, terminal) never reach a viewer at
//     all: a phone has neither the files nor the processes.
//   - agent→client NOTIFICATIONS (session/update) are stamped with a
//     monotonic `_seq`, appended to the conversation's event log (memory
//     tail + durable segments, see eventlog.go), and broadcast to the
//     attached streams. A stream attaching with Catchup+HaveSeq gets the
//     missing tail replayed point-to-point from the log (no agent
//     involvement, no broadcast) and only then joins the live set —
//     co-viewers never see another client's catch-up. While none is
//     attached the log still records, so the next attach catches up
//     without a session/load; and because the log is durable, so does the
//     next attach AFTER a daemon restart.
//   - `initialize` is answered from cache per requesting stream (an agent
//     process is initialized once); session ids are sniffed so `list` can
//     report them. The last session/new / session/load RESULT (modes,
//     models, config options) is cached too: a catchup stream's
//     session/load is answered from that cache — the agent is never asked
//     to re-replay history it already streamed through the log.
type agentInstance struct {
	ID        string
	Cmd       string
	Args      []string
	Cwd       string
	CreatedAt time.Time

	mu    sync.Mutex
	proc  *exec.Cmd
	stdin io.WriteCloser
	// Attached streams → whether that stream was served a scrollback replay
	// on attach (it therefore already holds the transcript, and must not be
	// sent an unlogged session/load re-replay of the same history).
	attached    map[*session]bool
	nextAgentID int64
	idMap       map[string]clientReq // agent-side id → original client request
	pendingReqs []json.RawMessage    // agent→client requests awaiting an answer
	pendingByID map[string]int       // id key → index marker (for removal)
	turnActive  bool
	lastStop    string
	// Lock-free mirror of `exited` for the server's conversation registry,
	// which must never take inst.mu (it is claimed from under it).
	exitedFlag   atomic.Bool
	acpSessionID string
	initResult   json.RawMessage
	initialized  bool
	exited       bool
	exitCode     int
	exitErr      string
	// Partial inbound line per attached stream. Client stdio units are
	// chunks of a newline-delimited byte stream; with several writers the
	// reassembly must be per-stream or their fragments would interleave.
	lineBufs map[*session][]byte

	// Sequenced scrollback of notifications (see eventlog.go) and the
	// session-result cache that answers a catchup stream's session/load.
	updates *eventLog
	// Where conversation directories live; "" = memory-only (tests).
	logRoot string
	// Claims a conversation for this instance (indexing it by conversation
	// as a side effect). False = another live process owns it.
	claimConversation func(*agentInstance, string) bool
	// Closed once the daemon has finished handing a respawned process its
	// conversation back; nil when no restore was needed. Client requests for
	// initialize / session/load wait on it so they read the cache the restore
	// fills instead of racing the agent for the same work.
	restored chan struct{}
	// In-flight session/load forwards whose agent replay must NOT be
	// sequenced/logged: the load re-transmits history the log already holds
	// (a rebuild, or a gap fallback) — logging it would duplicate entries
	// for every other viewer. A load that BEGINS on an empty log (a brand
	// new conversation, or one whose durable history was evicted) is the
	// opposite: its replay IS the history, so it is logged; that keeps the
	// log complete from the conversation's start, not the process's.
	loadUnlogged int
	// Streams awaiting an unlogged load's replay, by outstanding load count.
	// That replay is a REBUILD for whoever asked: it goes only to them, and
	// only if they weren't already served the same history from the log.
	// Everyone else is holding a transcript this replay would duplicate.
	unloggedTargets map[*session]int
	// Raw `result` of the last session/new or session/load response —
	// modes/models/config options. Answers session/load from cache for
	// streams that got a scrollback replay (transcript already delivered),
	// so history is never re-replayed by the agent mid-turn.
	cachedSessionResult json.RawMessage
}

type clientReq struct {
	origID json.RawMessage
	method string
	origin *session // stream that issued the request; response goes here only
	// Set when the DAEMON issued this request for itself (restoring a
	// respawned agent). The response is delivered here and forwarded to
	// nobody — there is no client behind it.
	internal chan json.RawMessage
	// session/load only: this load's replay is being sequenced into the
	// scrollback (it began on an empty log); cleared on its response.
	logsLoad bool
}

// bindConversation attaches this instance's event log to the durable
// directory for `id`, recovering any history a previous daemon process (or
// an earlier agent process for the same conversation) already wrote.
//
// Called as soon as the conversation id is known and ALWAYS before the
// replay it governs: at spawn when the client names the conversation it is
// resuming, otherwise on the session/load request or the session/new
// response. Caller holds inst.mu.
//
// Binding requires CLAIMING the conversation: if another live process
// already owns it (an older client that spawned unnamed and then loaded a
// conversation someone else is running) this instance stays memory-only
// rather than interleaving a second seq stream into one file.
func (inst *agentInstance) bindConversation(id string) {
	if id == "" {
		return
	}
	// Claim first and unconditionally: the registry behind it is what makes
	// a later spawn adopt this process, and that must hold whether or not
	// durable logging is configured.
	owned := true
	if inst.claimConversation != nil {
		owned = inst.claimConversation(inst, id)
	}
	if inst.logRoot == "" || inst.updates.dir != "" {
		return
	}
	if !owned {
		inst.updates.log("acp event log: conversation already owned by a live agent; "+
			"keeping this process's scrollback in memory", "conversation", id)
		return
	}
	if err := inst.updates.bind(conversationDir(inst.logRoot, id)); err != nil {
		// Durability is best-effort: the memory tail still serves live
		// viewers and near-term catch-up, so a bad disk must never take the
		// conversation down with it.
		inst.updates.log("acp event log: bind failed", "conversation", id, "err", err)
	}
}

// InstanceInfo is the `list` control response row.
type InstanceInfo struct {
	ID           string `json:"id"`
	Cmd          string `json:"cmd"`
	Cwd          string `json:"cwd"`
	Running      bool   `json:"running"`
	Attached     bool   `json:"attached"`
	TurnActive   bool   `json:"turn_active"`
	AwaitingPerm bool   `json:"awaiting_perm"`
	ACPSessionID string `json:"acp_session_id,omitempty"`
	CreatedAtUx  int64  `json:"created_at"`
}

func (inst *agentInstance) info() InstanceInfo {
	inst.mu.Lock()
	defer inst.mu.Unlock()
	return InstanceInfo{
		ID:           inst.ID,
		Cmd:          inst.Cmd,
		Cwd:          inst.Cwd,
		Running:      !inst.exited,
		Attached:     len(inst.attached) > 0,
		TurnActive:   inst.turnActive,
		AwaitingPerm: len(inst.pendingReqs) > 0,
		ACPSessionID: inst.acpSessionID,
		CreatedAtUx:  inst.CreatedAt.Unix(),
	}
}

// instanceHooks is the server-side wiring one instance needs: where durable
// history lives, where to complain, and the two lifecycle callbacks.
type instanceHooks struct {
	// logRoot is where conversation event logs live ("" = memory only).
	logRoot string
	logf    func(string, ...any)
	onExit  func(*agentInstance)
	// claim makes an instance the process of record for a conversation;
	// false means another live process already is.
	claim func(*agentInstance, string) bool
}

// spawnInstance starts the agent process and its always-on reader loops.
// When the spawn names a conversation, its durable history is bound
// immediately — before any agent output — which is what makes a resume after
// a daemon restart continue the existing log instead of starting a rival.
func spawnInstance(c Control, h instanceHooks) (*agentInstance, error) {
	if c.Cmd == "" {
		return nil, fmt.Errorf("spawn: empty command")
	}
	env := augmentedEnv(c.Env)
	path, err := lookPath(c.Cmd, env)
	if err != nil {
		return nil, fmt.Errorf("agent not found: %s", c.Cmd)
	}
	cmd := exec.Command(path, c.Args...)
	cmd.Env = env
	if c.Cwd != "" {
		dir := expandHome(c.Cwd)
		// Go reports a chdir failure as "fork/exec <binary>: no such file or
		// directory", which sends everyone looking for a missing agent — the
		// binary is right there and the DIRECTORY is what's gone (a pane
		// whose project was moved or deleted, or one carrying a path from
		// another machine). Say which.
		if info, err := os.Stat(dir); err != nil || !info.IsDir() {
			return nil, fmt.Errorf("working directory not found: %s", c.Cwd)
		}
		cmd.Dir = dir
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}

	inst := &agentInstance{
		ID:                uuid.NewString()[:8],
		Cmd:               c.Cmd,
		Args:              c.Args,
		Cwd:               c.Cwd,
		CreatedAt:         time.Now(),
		proc:              cmd,
		stdin:             stdin,
		attached:          make(map[*session]bool),
		idMap:             make(map[string]clientReq),
		pendingByID:       make(map[string]int),
		lineBufs:          make(map[*session][]byte),
		unloggedTargets:   make(map[*session]int),
		updates:           newEventLog(h.logf),
		logRoot:           h.logRoot,
		claimConversation: h.claim,
	}
	if c.SessionID != "" {
		inst.acpSessionID = c.SessionID
		inst.bindConversation(c.SessionID)
	}

	go inst.readLoop(stdout)
	// A named conversation with history behind it is a RESUME: the process is
	// new and holds none of it. Restoring is the daemon's job, not the first
	// client's to happen along.
	if c.SessionID != "" && inst.updates.head() > 0 {
		inst.restored = make(chan struct{})
		go inst.restoreConversation(c.SessionID, c.Cwd)
	}
	go inst.stderrLoop(stderr)
	go func() {
		err := cmd.Wait()
		inst.mu.Lock()
		inst.exited = true
		inst.exitedFlag.Store(true)
		if cmd.ProcessState != nil {
			inst.exitCode = cmd.ProcessState.ExitCode()
		}
		if err != nil {
			inst.exitErr = err.Error()
		}
		// The history stays on disk for the next process on this
		// conversation; only this process's handle goes away.
		inst.updates.close()
		targets := inst.attachedLocked()
		code, msg := inst.exitCode, inst.exitErr
		inst.mu.Unlock()
		for _, s := range targets {
			s.sendControl(Control{Op: "exit", AgentID: inst.ID, Code: code, Error: msg})
		}
		if h.onExit != nil {
			h.onExit(inst)
		}
	}()
	return inst, nil
}

// attachedLocked snapshots the attached set. Callers hold inst.mu; the
// returned slice is used AFTER unlocking (sendStdio blocks on the credit
// window, so nothing may hold inst.mu across a send).
func (inst *agentInstance) attachedLocked() []*session {
	out := make([]*session, 0, len(inst.attached))
	for s := range inst.attached {
		out = append(out, s)
	}
	return out
}

// broadcastStdio delivers one agent line to every attached stream. Serial
// on purpose: each target's credit window backpressures the loop, so the
// agent is paced by the slowest attached client — the same bound a single
// attachment always had, now the price of co-viewing.
func (inst *agentInstance) broadcastStdio(line []byte) {
	inst.mu.Lock()
	targets := inst.attachedLocked()
	inst.mu.Unlock()
	for _, s := range targets {
		s.sendStdio(line)
	}
}

func (inst *agentInstance) broadcastControl(c Control) {
	inst.mu.Lock()
	targets := inst.attachedLocked()
	inst.mu.Unlock()
	for _, s := range targets {
		s.sendControl(c)
	}
}

// attach adds a stream to this instance's subscriber set, replays queued
// agent requests to it, and reports state. Existing attachments stay —
// co-viewing, not displacement.
//
// A Catchup attach with a gapless cursor (have+1 ≥ log start) is granted a
// point-to-point scrollback replay FIRST and joins the live broadcast set
// only once drained — never both channels at once, so no line is doubled
// and none is lost. The replay runs on its own goroutine: handleControl
// executes inline on the shared inbound read loop, and a replay that blocks
// on this stream's credit window there would deadlock the credit refills.
func (inst *agentInstance) attach(s *session, haveSeq uint64, catchup bool, holdsTranscript bool) {
	inst.mu.Lock()
	running := !inst.exited
	turnActive := inst.turnActive
	acpSessionID := inst.acpSessionID
	head := inst.updates.head()
	start := inst.updates.start()
	replay := catchup && haveSeq < head && haveSeq+1 >= start
	// "Served" means this stream's transcript is current. Never inferred from
	// the cursor alone: a cursor says what to SEND, not what the client
	// rendered, and a client can sit at the log head with an empty transcript
	// (a fresh view, a rebuild in flight). Suppressing its load's replay on
	// that basis published an empty buffer over eight live panes.
	// Either the daemon just handed this stream the history, or the client
	// told us it already has it AND its cursor is at the head. The second
	// half is the client's own assertion — never the daemon's guess.
	served := replay || (catchup && holdsTranscript && head > 0 && haveSeq >= head)
	if !replay {
		// The map's value IS the "holds the transcript" flag the broadcast
		// path reads; a replaying stream joins later, already marked true.
		inst.attached[s] = served
	}
	// Count this stream either way: when a replay was granted it joins the
	// set only after draining, so the map alone would under-report it.
	viewers := len(inst.attached)
	if replay {
		viewers++
	}
	pending := make([]json.RawMessage, len(inst.pendingReqs))
	copy(pending, inst.pendingReqs)
	inst.mu.Unlock()

	s.setCatchupServed(served)
	// The one line that answers "where did this viewer's transcript come
	// from" — the question every multi-viewer bug starts with.
	s.log.Info("stream attached", "agent", inst.ID, "have_seq", haveSeq,
		"head_seq", head, "start_seq", start, "replay", replay,
		"catchup", catchup, "viewers", viewers)
	s.sendControl(Control{
		Op: "attached", AgentID: inst.ID, Running: running,
		TurnActive: turnActive, ACPSessionID: acpSessionID,
		HeadSeq: head, StartSeq: start, Replay: replay,
	})
	if replay {
		go inst.replayAndJoin(s, haveSeq, attachedState{turnActive: turnActive, running: running})
		return
	}
	for _, raw := range pending {
		s.sendStdio(append(append([]byte{}, raw...), '\n'))
	}
}

// attachedState is what the `attached` control told a replaying stream about
// the instance's liveness. Compared against the truth at join time so a
// change that happened during the replay isn't lost (see replayAndJoin).
type attachedState struct {
	turnActive bool
	running    bool
}

// replayAndJoin streams the scrollback tail after `cursor` to one stream,
// then atomically joins it to the live set. The join happens in the SAME
// critical section that observed an empty remainder; sequenceNotification
// appends + snapshots targets under that lock too, so every line lands via
// exactly one channel: appended while joined → broadcast; appended before →
// picked up by the next replay batch.
//
// That guarantee covers NOTIFICATIONS (they go through the log). Controls do
// not: `turnDone` and `exit` are sent point-to-point to the attached set, and
// this stream is deliberately absent from it until the join below — so a turn
// that ends, or an agent that dies, while the replay drains would reach every
// co-viewer except the one client that just asked for the state. The `at`
// snapshot is re-checked at the join for exactly that window: the client was
// told `turn_active: true` and has no other way to learn otherwise (its own
// prompt response belongs to the connection that issued it — gone across a
// restart), so it would show a turn running forever, with a cancel finding no
// live turn to stop.
func (inst *agentInstance) replayAndJoin(s *session, cursor uint64, at attachedState) {
	const batchLines = 64
	warnedGap := false
	for {
		inst.mu.Lock()
		batch := inst.updates.since(cursor, batchLines)
		if len(batch) == 0 {
			inst.attached[s] = true
			pending := make([]json.RawMessage, len(inst.pendingReqs))
			copy(pending, inst.pendingReqs)
			missedTurnDone := at.turnActive && !inst.turnActive
			missedExit := at.running && inst.exited
			stop, code, exitErr := inst.lastStop, inst.exitCode, inst.exitErr
			inst.mu.Unlock()
			for _, raw := range pending {
				s.sendStdio(append(append([]byte{}, raw...), '\n'))
			}
			if missedTurnDone {
				s.sendControl(Control{Op: "turnDone", AgentID: inst.ID, Line: stop})
			}
			if missedExit {
				s.sendControl(Control{Op: "exit", AgentID: inst.ID, Code: code, Error: exitErr})
			}
			// The stream can close mid-replay; a post-join close raced our
			// insert. Re-check so a dead session never lingers in the set.
			if s.isClosed() {
				inst.detach(s)
			}
			return
		}
		inst.mu.Unlock()

		// Flood while replaying can evict past the cursor (extreme; the cap
		// is generous). Surface the hole instead of silently skipping.
		if !warnedGap && batch[0].seq > cursor+1 {
			warnedGap = true
			s.sendControl(Control{Op: "stderr",
				Line: "[bento] scrollback overflowed during catch-up — some history is missing"})
		}
		for _, e := range batch {
			s.sendStdio(e.line)
			cursor = e.seq
		}
		if s.isClosed() {
			return
		}
	}
}

func (inst *agentInstance) detach(s *session) {
	inst.mu.Lock()
	delete(inst.attached, s)
	delete(inst.lineBufs, s)
	delete(inst.unloggedTargets, s)
	inst.mu.Unlock()
}

func (inst *agentInstance) kill() {
	inst.mu.Lock()
	proc := inst.proc
	inst.mu.Unlock()
	if proc == nil || proc.Process == nil {
		return
	}
	pid := proc.Process.Pid
	_ = syscall.Kill(-pid, syscall.SIGTERM)
	go func() {
		time.Sleep(3 * time.Second)
		_ = syscall.Kill(-pid, syscall.SIGKILL)
	}()
}

// ---- agent → client direction ----

// readLoop consumes the agent's stdout line by line. bufio.Scanner is
// deliberately NOT used: past its buffer cap it fails and the loop would
// exit silently — agent output would stop forever while the process runs.
// Instead, lines accumulate up to maxAgentLine; anything longer is dropped
// with a stderr notice and the loop keeps going.
func (inst *agentInstance) readLoop(stdout io.Reader) {
	r := bufio.NewReaderSize(stdout, 64*1024)
	var line []byte
	oversized := false
	for {
		frag, err := r.ReadSlice('\n')
		if !oversized {
			line = append(line, frag...)
			if len(line) > maxAgentLine {
				oversized = true
				line = nil
				inst.noticeOversizedLine()
			}
		}
		if err == bufio.ErrBufferFull {
			continue // mid-line; keep accumulating (or draining, if oversized)
		}
		if err == nil {
			if !oversized && len(line) > 1 {
				raw := make([]byte, len(line)-1) // strip '\n'
				copy(raw, line[:len(line)-1])
				inst.handleAgentLine(raw)
			}
			line = nil
			oversized = false
			continue
		}
		// EOF or read error: deliver any trailing unterminated line, then stop.
		if !oversized && len(line) > 0 {
			inst.handleAgentLine(append([]byte{}, line...))
		}
		return
	}
}

// noticeOversizedLine surfaces a dropped >maxAgentLine JSON-RPC line to the
// attached clients (if any) so the stall isn't silent.
func (inst *agentInstance) noticeOversizedLine() {
	inst.broadcastControl(Control{
		Op:   "stderr",
		Line: fmt.Sprintf("[bento] dropped an agent message over %d MiB", maxAgentLine>>20),
	})
}

func (inst *agentInstance) stderrLoop(stderr io.Reader) {
	scanner := bufio.NewScanner(stderr)
	scanner.Buffer(make([]byte, 64*1024), 1<<20)
	for scanner.Scan() {
		text := scanner.Text()
		if len(text) > 2048 {
			text = text[:2048]
		}
		if text != "" {
			inst.broadcastControl(Control{Op: "stderr", Line: text})
		}
	}
}

type rpcShape struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Result json.RawMessage `json:"result"`
	Error  json.RawMessage `json:"error"`
}

func idKey(raw json.RawMessage) string { return string(raw) }

// hostSideMethod reports whether an agent→client request belongs to the
// machine hosting the agent rather than to whoever is watching it.
func hostSideMethod(method string) bool {
	return strings.HasPrefix(method, "fs/") || strings.HasPrefix(method, "terminal/")
}

// answerHostSideRequest replies on the host's behalf. It currently declines,
// which is exactly what the viewers used to answer (no client implements the
// filesystem or terminal capability, and we advertise neither) — what changed
// is WHERE the answer comes from. Implementing these for real belongs here
// too: the daemon is what has the files and can own a pty, and owning them is
// the precondition for advertising the capabilities at all.
func (inst *agentInstance) answerHostSideRequest(shape rpcShape) {
	kind := "fs"
	if strings.HasPrefix(shape.Method, "terminal/") {
		kind = "terminal"
	}
	resp, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      shape.ID,
		"error": map[string]any{
			"code":    -32601, // JSON-RPC method not found
			"message": kind + " not supported",
		},
	})
	if err != nil {
		return
	}
	inst.writeStdin(append(resp, '\n'))
}

func (inst *agentInstance) handleAgentLine(raw []byte) {
	var shape rpcShape
	if err := json.Unmarshal(raw, &shape); err != nil {
		return // agents sometimes log to stdout; ignore
	}

	switch {
	case shape.Method != "" && shape.ID != nil && hostSideMethod(shape.Method):
		// A request about the MAC — its filesystem, its processes. A phone
		// has neither, so this must never go to the viewers: broadcasting it
		// asked every device to answer for a disk only one of them has, and
		// burned relay bandwidth to collect N identical refusals of which the
		// daemon kept one. The host answers for the host.
		inst.answerHostSideRequest(shape)

	case shape.Method != "" && shape.ID != nil:
		// Agent request the USER answers (permission, elicitation): queue
		// until answered, broadcast to everyone — first device wins.
		inst.mu.Lock()
		inst.pendingReqs = append(inst.pendingReqs, json.RawMessage(raw))
		inst.pendingByID[idKey(shape.ID)] = 1
		inst.mu.Unlock()
		inst.broadcastStdio(append(append([]byte{}, raw...), '\n'))

	case shape.Method != "":
		// Notification: stamp + log + broadcast. Sequencing, the log append
		// and the target snapshot share ONE critical section — that is the
		// invariant that lets a catch-up replay join the live set without
		// ever double-delivering or dropping a line (see replayAndJoin).
		line, targets := inst.sequenceNotification(raw)
		for _, s := range targets {
			s.sendStdio(line)
		}

	case shape.ID != nil:
		inst.forwardAgentResponse(raw, shape)
	}
}

// sequenceNotification stamps a notification with the next seq, appends it
// to the event log and snapshots the live broadcast set, atomically.
//
// While an UNLOGGED session/load replay is in flight the line passes through
// verbatim (no seq, no log) and goes ONLY to the streams that asked for that
// load and hold no copy of the history already: it re-transmits what the log
// holds, so broadcasting it would duplicate every co-viewer's transcript —
// and a stream that was served a scrollback replay on attach has that
// history too, even though it issued the load (it wanted the session state,
// not the transcript).
func (inst *agentInstance) sequenceNotification(raw []byte) (line []byte, targets []*session) {
	inst.mu.Lock()
	defer inst.mu.Unlock()
	line = append(append([]byte{}, raw...), '\n')
	if inst.loadUnlogged > 0 {
		return line, inst.unloggedReplayTargets()
	}
	if stamped, ok := injectSeq(raw, inst.updates.nextSeq); ok {
		inst.updates.append(stamped)
		line = stamped
	}
	return line, inst.attachedLocked()
}

// unloggedReplayTargets is the subset of attached streams that requested an
// in-flight unlogged load and were not already served the same history from
// the log. Caller holds inst.mu.
func (inst *agentInstance) unloggedReplayTargets() []*session {
	var out []*session
	for s := range inst.unloggedTargets {
		if catchupServed, ok := inst.attached[s]; ok && !catchupServed {
			out = append(out, s)
		}
	}
	return out
}

// forwardAgentResponse maps an agent response back to the originating
// client id and stream, updating bookkeeping (turn state, cached init,
// session id). The response goes ONLY to the origin; other attached
// streams get a `turnDone` control for finished prompts so their state
// catches up without a point-to-point response they never asked for.
func (inst *agentInstance) forwardAgentResponse(raw []byte, shape rpcShape) {
	key := idKey(shape.ID)
	inst.mu.Lock()
	req, ok := inst.idMap[key]
	if ok {
		delete(inst.idMap, key)
	}

	if ok {
		switch req.method {
		case "initialize":
			if shape.Result != nil {
				inst.initResult = append(json.RawMessage{}, shape.Result...)
				inst.initialized = true
			}
		case "session/prompt":
			inst.turnActive = false
			var pr struct {
				StopReason string `json:"stopReason"`
			}
			_ = json.Unmarshal(shape.Result, &pr)
			inst.lastStop = pr.StopReason
		case "session/new":
			var nr struct {
				SessionID string `json:"sessionId"`
			}
			_ = json.Unmarshal(shape.Result, &nr)
			if nr.SessionID != "" {
				inst.acpSessionID = nr.SessionID
				// A brand-new conversation finally has an id: give its event
				// log a durable home (anything buffered before now flushes).
				inst.bindConversation(nr.SessionID)
			}
			if shape.Result != nil && shape.Error == nil {
				inst.cachedSessionResult = append(json.RawMessage{}, shape.Result...)
			}
		case "session/load":
			// The load's replay finished streaming (its response is the
			// ordering boundary) — stop suppressing/logging accordingly,
			// and cache the state for catchup-served session/loads.
			if req.logsLoad {
				// logged load: nothing to undo
			} else if inst.loadUnlogged > 0 {
				inst.loadUnlogged--
				if req.origin != nil {
					if n := inst.unloggedTargets[req.origin]; n > 1 {
						inst.unloggedTargets[req.origin] = n - 1
					} else {
						delete(inst.unloggedTargets, req.origin)
					}
				}
			}
			if shape.Result != nil && shape.Error == nil {
				inst.cachedSessionResult = append(json.RawMessage{}, shape.Result...)
			}
		}
	}
	var originAlive bool
	var observers []*session
	stop := inst.lastStop
	if ok {
		_, originAlive = inst.attached[req.origin]
		for s := range inst.attached {
			if s != req.origin {
				observers = append(observers, s)
			}
		}
	}
	inst.mu.Unlock()

	if !ok {
		return // unknown response id — nowhere to route
	}

	if req.internal != nil {
		// The daemon asked; the daemon answers. Bookkeeping above already
		// cached what mattered (initialize result, session state).
		select {
		case req.internal <- append(json.RawMessage{}, raw...):
		default:
		}
		return
	}

	// Finished prompts update every non-origin viewer (and, when the origin
	// left mid-turn, whoever is still watching).
	if req.method == "session/prompt" {
		for _, s := range observers {
			s.sendControl(Control{Op: "turnDone", AgentID: inst.ID, Line: stop})
		}
	}
	if !originAlive {
		return
	}

	// Rewrite the id back to the client's original.
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return
	}
	obj["id"] = req.origID
	out, err := json.Marshal(obj)
	if err != nil {
		return
	}
	req.origin.sendStdio(append(out, '\n'))
}

// ---- client → agent direction ----

// handleClientStdio consumes stdio bytes from one attached stream (whole
// or partial JSON-RPC lines) and forwards them with id translation. The
// partial-line buffer is per-stream — concurrent writers must not have
// their fragments interleaved.
func (inst *agentInstance) handleClientStdio(s *session, p []byte) {
	inst.mu.Lock()
	buf := append(inst.lineBufs[s], p...)
	// A client that streams forever without a newline must not grow daemon
	// memory unboundedly; past the line cap the partial line is dropped.
	if len(buf) > maxAgentLine {
		buf = nil
	}
	var lines [][]byte
	for {
		idx := -1
		for i, b := range buf {
			if b == '\n' {
				idx = i
				break
			}
		}
		if idx < 0 {
			break
		}
		line := make([]byte, idx)
		copy(line, buf[:idx])
		buf = buf[idx+1:]
		if len(line) > 0 {
			lines = append(lines, line)
		}
	}
	inst.lineBufs[s] = buf
	inst.mu.Unlock()

	for _, line := range lines {
		inst.handleClientLine(s, line)
	}
}

func (inst *agentInstance) handleClientLine(s *session, raw []byte) {
	var shape rpcShape
	if err := json.Unmarshal(raw, &shape); err != nil {
		return
	}

	switch {
	case shape.Method != "" && shape.ID != nil:
		inst.forwardClientRequest(s, raw, shape)

	case shape.ID != nil:
		// Client answers an agent request: with several viewers the same
		// request was broadcast to all of them, and the agent must see
		// exactly ONE response — first answer wins, the rest are dropped.
		inst.mu.Lock()
		key := idKey(shape.ID)
		_, wasPending := inst.pendingByID[key]
		var observers []*session
		if wasPending {
			delete(inst.pendingByID, key)
			kept := inst.pendingReqs[:0]
			for _, r := range inst.pendingReqs {
				var rs rpcShape
				if json.Unmarshal(r, &rs) == nil && idKey(rs.ID) == key {
					continue
				}
				kept = append(kept, r)
			}
			inst.pendingReqs = kept
			for other := range inst.attached {
				if other != s {
					observers = append(observers, other)
				}
			}
		}
		inst.mu.Unlock()
		if wasPending {
			inst.writeStdin(append(append([]byte{}, raw...), '\n'))
			// Everyone else is still showing this request. Without this they
			// would show it forever: the agent has moved on, so no further
			// traffic mentions it, and a stale card left up is not merely
			// cosmetic — it makes the next request arrive into an occupied
			// slot, where clients historically auto-declined it and that
			// decline could beat the real answer.
			for _, other := range observers {
				other.sendControl(Control{
					Op: "requestAnswered", AgentID: inst.ID, RequestID: key})
			}
		}

	case shape.Method != "":
		inst.writeStdin(append(append([]byte{}, raw...), '\n'))
	}
}

func (inst *agentInstance) forwardClientRequest(s *session, raw []byte, shape rpcShape) {
	// These two are what a restore fills the cache with. Racing it would send
	// the agent a second initialize, or a second full replay of the history
	// it is already loading.
	if shape.Method == "initialize" || shape.Method == "session/load" {
		inst.awaitRestore()
	}
	inst.mu.Lock()
	// An agent process is initialized exactly once; later attachments get
	// the cached result.
	if shape.Method == "initialize" && inst.initialized {
		cached := inst.initResult
		inst.mu.Unlock()
		resp, _ := json.Marshal(map[string]json.RawMessage{
			"jsonrpc": json.RawMessage(`"2.0"`),
			"id":      shape.ID,
			"result":  cached,
		})
		s.sendStdioOffLoop(append(resp, '\n'))
		return
	}

	// A stream that already got its transcript via scrollback replay asks
	// session/load only for the session STATE (modes/models/config). Answer
	// from the cached result: the agent never re-replays history (turn-safe,
	// no broadcast), and the client sees a normal LoadSessionResponse. Only
	// when the log is complete — an evicted head means the replay had a hole
	// the real load must fill.
	if shape.Method == "session/load" && s.catchupServedNow() &&
		inst.cachedSessionResult != nil && !inst.updates.evicted {
		cached := inst.cachedSessionResult
		inst.mu.Unlock()
		resp, _ := json.Marshal(map[string]json.RawMessage{
			"jsonrpc": json.RawMessage(`"2.0"`),
			"id":      shape.ID,
			"result":  cached,
		})
		s.sendStdioOffLoop(append(resp, '\n'))
		return
	}

	inst.nextAgentID++
	agentID, _ := json.Marshal(inst.nextAgentID)
	req := clientReq{
		origID: append(json.RawMessage{}, shape.ID...),
		method: shape.Method,
		origin: s,
	}
	var turnObservers []*session
	if shape.Method == "session/prompt" {
		inst.turnActive = true
		// Only the prompting stream can infer a turn started; every other
		// viewer would sit there looking idle while output streams in — and
		// worse, would send its own prompt straight through instead of
		// queueing it, because "is a turn running" is the gate for that.
		// `turnDone` has always been broadcast; this is its missing half.
		for other := range inst.attached {
			if other != s {
				turnObservers = append(turnObservers, other)
			}
		}
	}
	if shape.Method == "session/load" {
		var lr struct {
			Params struct {
				SessionID string `json:"sessionId"`
			} `json:"params"`
		}
		if json.Unmarshal(raw, &lr) == nil && lr.Params.SessionID != "" {
			inst.acpSessionID = lr.Params.SessionID
			// Bind BEFORE deciding logged/unlogged: the conversation's
			// durable history is exactly what makes that call correct after
			// a daemon restart — a client that spawns and then loads must
			// not re-log history the log already holds.
			inst.bindConversation(lr.Params.SessionID)
		}
		// Loads that begin on an EMPTY log are the conversation's first
		// restore here: their replay IS the history — sequence it into the
		// log so later attachers catch up without another load. Any other
		// load re-transmits what the log already holds — mark it unlogged so
		// the replay isn't duplicated into the scrollback.
		if inst.updates.head() == 0 {
			req.logsLoad = true
		} else {
			inst.loadUnlogged++
			inst.unloggedTargets[s]++
		}
	}
	inst.idMap[idKey(agentID)] = req
	inst.mu.Unlock()

	// Ahead of the stdin write, so a viewer learns the turn began before any
	// of its output arrives.
	for _, other := range turnObservers {
		other.sendControl(Control{Op: "turnStarted", AgentID: inst.ID})
	}

	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return
	}
	obj["id"] = agentID
	out, err := json.Marshal(obj)
	if err != nil {
		return
	}
	inst.writeStdin(append(out, '\n'))
}

func (inst *agentInstance) writeStdin(line []byte) {
	inst.mu.Lock()
	stdin := inst.stdin
	exited := inst.exited
	inst.mu.Unlock()
	if stdin == nil || exited {
		return
	}
	_, _ = stdin.Write(line)
}
