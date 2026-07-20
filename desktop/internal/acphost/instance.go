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
// The daemon must be minimally JSON-RPC aware to make that safe:
//
//   - client→agent request ids are rewritten into the instance's own id
//     space so successive attachments can both use "1" without collision;
//     responses are mapped back (or dropped if that attachment is gone).
//   - agent→client REQUESTS (permission, fs) need an answer to unblock the
//     agent, so while detached they are queued and replayed verbatim on the
//     next attach — a mid-turn permission simply waits for you, which is
//     exactly the old "awaiting input while you're away" semantics.
//   - agent→client NOTIFICATIONS (session/update) are dropped while
//     detached: the agent persists its own conversation, and the client
//     recovers history through session/load on reattach.
//   - `initialize` is answered from cache on reattach (an agent process is
//     initialized once); session ids are sniffed so `list` can report them.
type agentInstance struct {
	ID        string
	Cmd       string
	Args      []string
	Cwd       string
	CreatedAt time.Time

	mu           sync.Mutex
	proc         *exec.Cmd
	stdin        io.WriteCloser
	attached     *session
	attachGen    int
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
	lineBuf      []byte // partial inbound line from client stdio units
}

type clientReq struct {
	origID json.RawMessage
	method string
	gen    int
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
		Attached:     inst.attached != nil,
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
		idMap:       make(map[string]clientReq),
		pendingByID: make(map[string]int),
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
		attached := inst.attached
		code, msg := inst.exitCode, inst.exitErr
		inst.mu.Unlock()
		if attached != nil {
			attached.sendControl(Control{Op: "exit", AgentID: inst.ID, Code: code, Error: msg})
		}
		if onExit != nil {
			onExit(inst)
		}
	}()
	return inst, nil
}

// attach binds a stream to this instance, replays queued agent requests,
// and reports state. Any previous attachment is displaced.
func (inst *agentInstance) attach(s *session) {
	inst.mu.Lock()
	previous := inst.attached
	inst.attached = s
	inst.attachGen++
	running := !inst.exited
	turnActive := inst.turnActive
	pending := make([]json.RawMessage, len(inst.pendingReqs))
	copy(pending, inst.pendingReqs)
	acpSessionID := inst.acpSessionID
	inst.mu.Unlock()

	if previous != nil && previous != s {
		previous.sendControl(Control{Op: "detached", AgentID: inst.ID})
		previous.dropInstance(inst)
	}

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
	if inst.attached == s {
		inst.attached = nil
	}
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
// attached client (if any) so the stall isn't silent.
func (inst *agentInstance) noticeOversizedLine() {
	inst.mu.Lock()
	attached := inst.attached
	inst.mu.Unlock()
	if attached != nil {
		attached.sendControl(Control{
			Op:   "stderr",
			Line: fmt.Sprintf("[bento] dropped an agent message over %d MiB", maxAgentLine>>20),
		})
	}
}

func (inst *agentInstance) stderrLoop(stderr io.Reader) {
	scanner := bufio.NewScanner(stderr)
	scanner.Buffer(make([]byte, 64*1024), 1<<20)
	for scanner.Scan() {
		text := scanner.Text()
		if len(text) > 2048 {
			text = text[:2048]
		}
		inst.mu.Lock()
		attached := inst.attached
		inst.mu.Unlock()
		if attached != nil && text != "" {
			attached.sendControl(Control{Op: "stderr", Line: text})
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
		// Agent request (permission/fs/terminal): queue until answered.
		inst.mu.Lock()
		inst.pendingReqs = append(inst.pendingReqs, json.RawMessage(raw))
		inst.pendingByID[idKey(shape.ID)] = 1
		attached := inst.attached
		inst.mu.Unlock()
		if attached != nil {
			attached.sendStdio(append(append([]byte{}, raw...), '\n'))
		}

	case shape.Method != "":
		// Notification: live-forward only; session/load rebuilds history.
		inst.mu.Lock()
		attached := inst.attached
		inst.mu.Unlock()
		if attached != nil {
			attached.sendStdio(append(append([]byte{}, raw...), '\n'))
		}

	case shape.ID != nil:
		inst.forwardAgentResponse(raw, shape)
	}
}

// forwardAgentResponse maps an agent response back to the originating
// client id, updating bookkeeping (turn state, cached init, session id).
func (inst *agentInstance) forwardAgentResponse(raw []byte, shape rpcShape) {
	key := idKey(shape.ID)
	inst.mu.Lock()
	req, ok := inst.idMap[key]
	if ok {
		delete(inst.idMap, key)
	}
	attached := inst.attached
	gen := inst.attachGen

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
	inst.mu.Unlock()

	if !ok || attached == nil || req.gen != gen {
		// Originating client is gone. If the finished turn ended while
		// detached, tell whoever attaches next via `attached.turn_active`.
		if ok && req.method == "session/prompt" && attached != nil {
			attached.sendControl(Control{Op: "turnDone", AgentID: inst.ID, Line: inst.lastStop})
		}
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
	attached.sendStdio(append(out, '\n'))
}

// ---- client → agent direction ----

// handleClientStdio consumes stdio bytes from the attached stream (whole
// or partial JSON-RPC lines) and forwards them with id translation.
func (inst *agentInstance) handleClientStdio(s *session, p []byte) {
	inst.mu.Lock()
	inst.lineBuf = append(inst.lineBuf, p...)
	// A client that streams forever without a newline must not grow daemon
	// memory unboundedly; past the line cap the partial line is dropped.
	if len(inst.lineBuf) > maxAgentLine {
		inst.lineBuf = nil
	}
	var lines [][]byte
	for {
		idx := -1
		for i, b := range inst.lineBuf {
			if b == '\n' {
				idx = i
				break
			}
		}
		if idx < 0 {
			break
		}
		line := make([]byte, idx)
		copy(line, inst.lineBuf[:idx])
		inst.lineBuf = inst.lineBuf[idx+1:]
		if len(line) > 0 {
			lines = append(lines, line)
		}
	}
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
		// Client answers an agent request: clear it from the pending queue
		// and pass through verbatim (agent ids are never rewritten).
		inst.mu.Lock()
		key := idKey(shape.ID)
		if _, pending := inst.pendingByID[key]; pending {
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
		inst.writeStdin(append(append([]byte{}, raw...), '\n'))

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
		gen:    inst.attachGen,
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
