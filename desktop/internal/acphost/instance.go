package acphost

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"sync"
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
//   - agent→client REQUESTS (permission, fs) are broadcast to every
//     attached stream and queued until answered; the FIRST answer wins and
//     is forwarded, later duplicates are dropped (the agent must see
//     exactly one response). While nobody is attached they stay queued and
//     replay on the next attach — a mid-turn permission simply waits.
//   - agent→client NOTIFICATIONS (session/update) broadcast to all
//     attached streams and are dropped while none is attached: the agent
//     persists its own conversation, and clients recover history through
//     session/load on reattach.
//   - `initialize` is answered from cache per requesting stream (an agent
//     process is initialized once); session ids are sniffed so `list` can
//     report them.
type agentInstance struct {
	ID        string
	Cmd       string
	Args      []string
	Cwd       string
	CreatedAt time.Time

	mu           sync.Mutex
	proc         *exec.Cmd
	stdin        io.WriteCloser
	attached     map[*session]struct{}
	nextAgentID  int64
	idMap        map[string]clientReq // agent-side id → original client request
	pendingReqs  []json.RawMessage    // agent→client requests awaiting an answer
	pendingByID  map[string]int       // id key → index marker (for removal)
	turnActive   bool
	lastStop     string
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
}

type clientReq struct {
	origID json.RawMessage
	method string
	origin *session // stream that issued the request; response goes here only
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

// spawnInstance starts the agent process and its always-on reader loops.
func spawnInstance(c Control, onExit func(*agentInstance)) (*agentInstance, error) {
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
		cmd.Dir = expandHome(c.Cwd)
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
		ID:          uuid.NewString()[:8],
		Cmd:         c.Cmd,
		Args:        c.Args,
		Cwd:         c.Cwd,
		CreatedAt:   time.Now(),
		proc:        cmd,
		stdin:       stdin,
		attached:    make(map[*session]struct{}),
		idMap:       make(map[string]clientReq),
		pendingByID: make(map[string]int),
		lineBufs:    make(map[*session][]byte),
	}

	go inst.readLoop(stdout)
	go inst.stderrLoop(stderr)
	go func() {
		err := cmd.Wait()
		inst.mu.Lock()
		inst.exited = true
		if cmd.ProcessState != nil {
			inst.exitCode = cmd.ProcessState.ExitCode()
		}
		if err != nil {
			inst.exitErr = err.Error()
		}
		targets := inst.attachedLocked()
		code, msg := inst.exitCode, inst.exitErr
		inst.mu.Unlock()
		for _, s := range targets {
			s.sendControl(Control{Op: "exit", AgentID: inst.ID, Code: code, Error: msg})
		}
		if onExit != nil {
			onExit(inst)
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
func (inst *agentInstance) attach(s *session) {
	inst.mu.Lock()
	inst.attached[s] = struct{}{}
	running := !inst.exited
	turnActive := inst.turnActive
	pending := make([]json.RawMessage, len(inst.pendingReqs))
	copy(pending, inst.pendingReqs)
	acpSessionID := inst.acpSessionID
	inst.mu.Unlock()

	s.sendControl(Control{
		Op: "attached", AgentID: inst.ID, Running: running,
		TurnActive: turnActive, ACPSessionID: acpSessionID,
	})
	for _, raw := range pending {
		s.sendStdio(append(append([]byte{}, raw...), '\n'))
	}
}

func (inst *agentInstance) detach(s *session) {
	inst.mu.Lock()
	delete(inst.attached, s)
	delete(inst.lineBufs, s)
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

func (inst *agentInstance) handleAgentLine(raw []byte) {
	var shape rpcShape
	if err := json.Unmarshal(raw, &shape); err != nil {
		return // agents sometimes log to stdout; ignore
	}

	switch {
	case shape.Method != "" && shape.ID != nil:
		// Agent request (permission/fs/terminal): queue until answered,
		// broadcast to everyone — whichever device answers first wins.
		inst.mu.Lock()
		inst.pendingReqs = append(inst.pendingReqs, json.RawMessage(raw))
		inst.pendingByID[idKey(shape.ID)] = 1
		inst.mu.Unlock()
		inst.broadcastStdio(append(append([]byte{}, raw...), '\n'))

	case shape.Method != "":
		// Notification: live-broadcast only; session/load rebuilds history.
		inst.broadcastStdio(append(append([]byte{}, raw...), '\n'))

	case shape.ID != nil:
		inst.forwardAgentResponse(raw, shape)
	}
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
		}
		inst.mu.Unlock()
		if wasPending {
			inst.writeStdin(append(append([]byte{}, raw...), '\n'))
		}

	case shape.Method != "":
		inst.writeStdin(append(append([]byte{}, raw...), '\n'))
	}
}

func (inst *agentInstance) forwardClientRequest(s *session, raw []byte, shape rpcShape) {
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
		s.sendStdio(append(resp, '\n'))
		return
	}

	inst.nextAgentID++
	agentID, _ := json.Marshal(inst.nextAgentID)
	inst.idMap[idKey(agentID)] = clientReq{
		origID: append(json.RawMessage{}, shape.ID...),
		method: shape.Method,
		origin: s,
	}
	if shape.Method == "session/prompt" {
		inst.turnActive = true
	}
	if shape.Method == "session/load" {
		var lr struct {
			Params struct {
				SessionID string `json:"sessionId"`
			} `json:"params"`
		}
		if json.Unmarshal(raw, &lr) == nil && lr.Params.SessionID != "" {
			inst.acpSessionID = lr.Params.SessionID
		}
	}
	inst.mu.Unlock()

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
