package acphost

// The daemon-side pty pane (docs/hybrid-workbench-design.md §3, §5 P1+P2):
// `spawn` kind=pty starts a real process under a real pty — the user's login
// shell by default, any command by name — and exposes it as a virtual
// instance `pty:<uuid>` on the EXISTING attach/detach/credit/kill ops.
// instanceCore gives it the attached set, the sequenced event log, catch-up
// replay and exit bookkeeping — the machinery every hosted instance
// already run on — and internal/host/pty owns the process, the read pump and
// the resize/kill edges. The ACP instance is this type's sibling: the
// attach/feed/join shapes are deliberately kept in lockstep rather than
// abstracted further, so either can move without contorting the other. The
// wire surface is documented in proto.go (the pty extension).
//
// Unlike an ACP ensure, spawn kind=pty is ALWAYS a fresh process start, and
// it binds the spawning stream like an ACP spawn does. There is nothing to
// adopt: a pty process is daemon-hosted and daemon-mortal — it survives any
// client detaching (the whole point), and dies with the daemon. After a
// daemon restart the id is simply unknown, and attach refuses cleanly.

import (
	"errors"
	"fmt"

	"github.com/google/uuid"
	ptyhost "github.com/novashang/bento/daemon/internal/host/pty"
)

// ptyIDPrefix namespaces pty pane instance ids: `pty:<uuid>`, minted at
// spawn and returned on the attached ack. `list` does not report pty panes —
// the client's own workspace structure (statekv) is their directory, exactly
// as the workspace mirror is for chat panes.
const ptyIDPrefix = "pty:"

// ---- server side: process start + registry ----

// startPtyPane spawns the process and registers the virtual instance.
func (s *Server) startPtyPane(c Control) (*ptyPane, error) {
	id := ptyIDPrefix + uuid.NewString()
	p := &ptyPane{
		instanceCore: instanceCore{
			id:     id,
			subs:   make(map[*session]bool),
			events: newEventLog(s.warnf),
			// logRoot deliberately "": a pty pane's scrollback lives in the
			// memory tail only. Decided by symmetry with the other two pane
			// kinds: ACP logs are durable because the CONVERSATION is
			// resumable — a respawned agent continues the same transcript, so
			// the history has a future reader. A pty process is not
			// resumable: a daemon restart kills it, and no later process can
			// continue its byte stream, so durable history would be bytes
			// addressed to a reader that can never exist — the same reasoning
			// a pane whose id does not survive a daemon
			// restart. Cross-restart terminal history
			// is the client's scrollback buffer's job today, and the P3 vt
			// grid is the daemon-side upgrade path.
		},
		onGone: func(p *ptyPane) { s.dropPtyPane(id, p) },
	}
	proc, err := ptyhost.Start(ptyhost.Options{
		Cmd:  expandHome(c.Cmd),
		Args: c.Args,
		Cwd:  expandHome(c.Cwd),
		Env:  augmentedEnv(c.Env),
		Cols: c.Cols,
		Rows: c.Rows,
		// feed appends + broadcasts under the one-unit-one-seq invariant;
		// it blocks on the slowest viewer's credit window, which stalls the
		// pump, fills the kernel pty buffer, and backpressures the process —
		// the pty-shaped analogue of the ACP stdout-pipe backpressure.
		OnOutput: p.feed,
		OnExit: func(code int, errMsg string) {
			p.noteExit(code, errMsg)
			if p.onGone != nil {
				p.onGone(p)
			}
		},
	})
	if err != nil {
		return nil, err
	}
	p.proc = proc
	s.ptyMu.Lock()
	// A command can exit before we get here (spawn `/bin/sh -c "exit 7"`);
	// its OnExit→drop then ran against an absent entry, so registering now
	// would park a corpse in the registry forever. The flag is set before
	// the drop, so checking it under ptyMu closes the window: either we see
	// it and skip, or the drop is still queued behind this lock and cleans
	// up after us.
	if !p.exitedFlag.Load() {
		s.ptyPanes[id] = p
	}
	s.ptyMu.Unlock()
	return p, nil
}

// ptyPaneByID returns the live registered pane, nil when unknown (never
// spawned, exited, or minted by a previous daemon life — a pty process does
// not survive a daemon restart, so a stale id must land here).
func (s *Server) ptyPaneByID(id string) *ptyPane {
	s.ptyMu.Lock()
	defer s.ptyMu.Unlock()
	return s.ptyPanes[id]
}

// dropPtyPane forgets a pane the moment its process exits. Immediate, like
// Unlike gcExited's grace period: a dead pty has no durable
// history and cannot be resumed, so the only honest answer to a later attach
// is a clean refusal — the same one a daemon restart produces.
func (s *Server) dropPtyPane(id string, p *ptyPane) {
	s.ptyMu.Lock()
	if s.ptyPanes[id] == p {
		delete(s.ptyPanes, id)
	}
	s.ptyMu.Unlock()
}

// ---- stream side: the routed ops ----

// spawnPty is `spawn` with kind=pty: a fresh process start that binds the
// spawning stream (mirroring the ACP spawn, not an ensure — see the
// file comment).
func (t *session) spawnPty(c Control) {
	t.mu.Lock()
	already := t.instance != nil
	t.mu.Unlock()
	if already {
		t.sendControl(Control{Op: "attachFailed", Error: "stream already attached to an agent"})
		return
	}
	p, err := t.server.startPtyPane(c)
	if err != nil {
		t.sendControl(Control{Op: "attachFailed", Error: err.Error()})
		return
	}
	t.log.Info("pty pane spawned", "pane", p.id, "cmd", c.Cmd, "cwd", c.Cwd,
		"cols", c.Cols, "rows", c.Rows)
	t.mu.Lock()
	t.instance = p
	t.window = InitialWindow
	t.mu.Unlock()
	t.windowCond.Broadcast()
	p.attach(t, c.HaveSeq, c.Catchup)
}

// attachPty is the attach op for the pty id namespace.
func (t *session) attachPty(c Control) {
	p := t.server.ptyPaneByID(c.AgentID)
	if p == nil || p.exitedFlag.Load() {
		t.sendControl(Control{Op: "attachFailed", AgentID: c.AgentID,
			Error: "unknown pty pane (pty processes do not survive a daemon restart)"})
		return
	}
	t.mu.Lock()
	previous := t.instance
	t.mu.Unlock()
	if previous != nil && previous != hostedInstance(p) {
		previous.detach(t)
	}
	t.mu.Lock()
	t.instance = p
	t.window = InitialWindow
	t.mu.Unlock()
	t.windowCond.Broadcast()
	p.attach(t, c.HaveSeq, c.Catchup)
}

// handleResizePty is the `resize` op for pty ids: the pty resize ioctl,
// through which the kernel delivers SIGWINCH to the pane's foreground
// process group. Acked with the shapes chosen —
// structureApplied / structureFailed carrying agent_id — minus Rev: a pty
// pane has no structure mirror to version, and the ioctl is synchronous, so
// the ack itself means "applied".
func (t *session) handleResizePty(c Control) {
	fail := func(err error) {
		t.sendControl(Control{Op: "structureFailed", AgentID: c.AgentID, Error: err.Error()})
	}
	p := t.server.ptyPaneByID(c.AgentID)
	if p == nil || p.exitedFlag.Load() {
		fail(errors.New("unknown pty pane"))
		return
	}
	if c.Cols <= 0 || c.Rows <= 0 {
		fail(fmt.Errorf("resize wants positive cols and rows, got %dx%d", c.Cols, c.Rows))
		return
	}
	if err := p.proc.Resize(c.Cols, c.Rows); err != nil {
		fail(err)
		return
	}
	t.log.Info("pty pane resized", "pane", c.AgentID, "cols", c.Cols, "rows", c.Rows)
	t.sendControl(Control{Op: "structureApplied", AgentID: c.AgentID})
}

// ---- the virtual instance ----

// ptyPane is one pty process exposed as a hosted instance: no
// JSON-RPC, no id rewriting, no `_seq` injection — log entries are raw
// output chunks, and the wire contract is one log entry per stdio unit
// (proto.go) so a client keeps its catch-up cursor by counting units.
type ptyPane struct {
	instanceCore
	proc *ptyhost.Proc
	// onGone drops this pane from the server registry once it exits.
	onGone func(*ptyPane)
}

// attach: the log is the only history channel a pane has, plus one edge an
// ACP instance reaches differently — a pane that exited
// before this stream joined the attached set (a short-lived command racing
// its own spawn ack) hands the exit over point-to-point, because noteExit's
// broadcast snapshotted its targets under the same mu this attach runs
// under, provably without this stream in it.
func (p *ptyPane) attach(s *session, haveSeq uint64, catchup bool) {
	p.mu.Lock()
	running := !p.exited
	exitCode, exitErr := p.exitCode, p.exitErr
	head := p.events.head()
	start := p.events.start()
	replay := catchup && haveSeq < head && haveSeq+1 >= start
	if !replay {
		p.subs[s] = false
	}
	viewers := len(p.subs)
	if replay {
		viewers++
	}
	p.mu.Unlock()

	s.setCatchupServed(false) // the ACP session/load cache never applies here
	s.log.Info("pty pane attached", "pane", p.id, "have_seq", haveSeq,
		"head_seq", head, "start_seq", start, "replay", replay, "viewers", viewers)
	s.sendControl(Control{
		Op: "attached", AgentID: p.id, Running: running,
		HeadSeq: head, StartSeq: start, Replay: replay,
	})
	if replay {
		go p.replayAndJoin(s, haveSeq, func() func() { return p.joinLocked(s, running) })
		return
	}
	if !running {
		s.sendControl(Control{Op: "exit", AgentID: p.id, Code: exitCode, Error: exitErr})
	}
}

// joinLocked runs under p.mu at the instant a replaying stream joins the
// live set, re-checking liveness for the window the replay left uncovered
// (exit controls go point-to-point to the attached set) — same contract as
// the ACP instance's joinLocked.
func (p *ptyPane) joinLocked(s *session, wasRunning bool) func() {
	missedExit := wasRunning && p.exited
	code, errMsg := p.exitCode, p.exitErr
	return func() {
		if missedExit {
			s.sendControl(Control{Op: "exit", AgentID: p.id, Code: code, Error: errMsg})
		}
		if s.isClosed() {
			p.detach(s)
		}
	}
}

// feed is the pane's inbound path, called by the ptyhost pump — one
// goroutine, chunks in read order. Append and target snapshot share ONE
// critical section (the invariant instanceCore.replayAndJoin builds on);
// the sends happen after unlock because sendStdio blocks on the receiver's
// credit window — which stalls the pump and backpressures the process
// through the kernel pty buffer.
//
// Chunks are split at StdioChunk so every log entry is exactly one wire
// unit — the 1:1 that makes counting units a valid client cursor.
func (p *ptyPane) feed(chunk []byte) {
	for len(chunk) > 0 {
		n := min(len(chunk), StdioChunk)
		piece := chunk[:n]
		chunk = chunk[n:]
		p.mu.Lock()
		if p.exited {
			p.mu.Unlock()
			return
		}
		p.events.append(piece)
		targets := make([]*session, 0, len(p.subs))
		for s := range p.subs {
			targets = append(targets, s)
		}
		p.mu.Unlock()
		for _, s := range targets {
			s.sendStdio(piece)
		}
	}
}

// handleClientStdio forwards a viewer's bytes into the pty. Raw and
// unframed on purpose — terminal input has no line discipline to reassemble
// (contrast agentInstance's per-stream JSON-RPC line buffers).
func (p *ptyPane) handleClientStdio(s *session, b []byte) {
	if err := p.proc.Write(b); err != nil {
		s.sendControl(Control{Op: "stderr", Line: "[bento] pty pane write failed: " + err.Error()})
	}
}

func (p *ptyPane) detach(s *session) {
	p.mu.Lock()
	delete(p.subs, s)
	p.mu.Unlock()
}

// kill really kills: the daemon owns
// this process outright, and `kill` is its only lifecycle op. Exit reaches
// the viewers through the pump's OnExit → noteExit.
func (p *ptyPane) kill() { p.proc.Kill() }
