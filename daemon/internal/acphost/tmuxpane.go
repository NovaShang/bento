package acphost

// The daemon-side tmux integration (docs/tmux-host-design.md): every tmux
// pane is a VIRTUAL instance. instanceCore gives it the attached set, the
// sequenced event log, catch-up replay and exit bookkeeping — the exact
// machinery ACP instances run on — and tmuxPane adds only the tmux-shaped
// edges: %output chunks in (via internal/host/tmux, which owns the
// control-mode client), send-keys bytes out. The wire surface is documented
// in proto.go: `spawn` kind=tmux (an ENSURE), the `tmux:<target>:%N` id
// namespace on the ordinary attach/detach/credit ops, and the structure
// mirror under the statekv key `tmux/<target>/structure`.

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"

	tmuxhost "github.com/novashang/bento/daemon/internal/host/tmux"
	"github.com/novashang/bento/daemon/internal/tmuxcm"
)

// tmuxStructureState is the JSON stored (base64, like every statekv value)
// under `tmux/<target>/structure`. Rev is monotonic per target — statekv
// values are last-write-wins blobs with no order of their own — and
// continues across daemon restarts by seeding from whatever the persisted
// statekv already holds, so a client never sees a rev move backwards.
//
// THE WIRE SHAPE (the Swift projection decodes exactly this; keep every
// change additive):
//
//	{
//	  "rev":     12,                // uint, monotonic per target
//	  "target":  "local",
//	  "session": "bento",           // the control client's CURRENT session
//	                                //   ("" = the server has no sessions —
//	                                //   killSession took the last one)
//	  "structure": {"windows":[…]}, // the CURRENT session's snapshot
//	                                //   (StructureSnapshot: windows ⊃
//	                                //   panes/details; empty when session "")
//	  "sizing":  {"policy":"latest","owner_device":"","cols":200,"rows":50},
//	  "sessions": [                 // EVERY session on the server, in
//	                                //   list-sessions order
//	    {"id":"$0","name":"bento","attached":true,"structure":{"windows":[…]}},
//	    {"id":"$4","name":"work","structure":{"windows":[…]}}
//	  ]
//	}
//
// Per sessions[] row: `id` is the tmux session id ("$N"), stable across
// renames; `name` is the current name; `attached` (omitted when false)
// marks the ONE session the daemon's control client is on — the session
// whose panes stream %output; `structure` is that session's windows ⊃ panes
// tree in the exact StructureSnapshot shape `structure` at the top level
// uses. The top-level `session`/`structure` pair duplicates the attached
// row — it predates multi-session and stays for additive decodability (an
// old value simply lacks `sessions`; a reader that understands `sessions`
// should prefer it and treat the top-level pair as the attached alias).
//
// Sizing is the session-size authority block (docs/tmux-host-design.md
// 步骤 5.5): policy + pinning device's label + the governing size the
// daemon's control client declares. Additive (a pre-5.5 value simply lacks
// it); every write from this daemon carries it. It governs the ATTACHED
// session's windows — tmux sizes windows off attached clients, and the
// daemon's control client is only attached to one session at a time.
type tmuxStructureState struct {
	Rev       uint64                   `json:"rev"`
	Target    string                   `json:"target"`
	Session   string                   `json:"session"`
	Structure tmuxcm.StructureSnapshot `json:"structure"`
	Sizing    *tmuxhost.Sizing         `json:"sizing,omitempty"`
	Sessions  []tmuxSessionState       `json:"sessions,omitempty"`
}

// tmuxSessionState is one session's row in the mirror — see the wire-shape
// comment on tmuxStructureState.
type tmuxSessionState struct {
	ID        string                   `json:"id,omitempty"`
	Name      string                   `json:"name"`
	Attached  bool                     `json:"attached,omitempty"`
	Structure tmuxcm.StructureSnapshot `json:"structure"`
}

func tmuxStructureKey(target string) string { return "tmux/" + target + "/structure" }

// parseTmuxAgentID splits `tmux:<target>:%N`. Parsed from the right: a pane
// id never contains a colon, a future ssh:// target might.
func parseTmuxAgentID(id string) (target string, pane tmuxcm.PaneID, ok bool) {
	rest, found := strings.CutPrefix(id, "tmux:")
	if !found {
		return "", 0, false
	}
	i := strings.LastIndexByte(rest, ':')
	if i <= 0 {
		return "", 0, false
	}
	pane, pok := tmuxcm.ParsePaneID(rest[i+1:])
	if !pok {
		return "", 0, false
	}
	return rest[:i], pane, true
}

// ---- server side: ensure + structure mirror + pane registry ----

// ensureTmuxSession is spawn kind=tmux's engine: bring up (or adopt) the
// control client for target+session. The tmux host itself is created
// lazily, on the first tmux-kind spawn — a daemon that is never asked for
// tmux never launches one, and cmd/bento-daemon needs no wiring at all.
func (s *Server) ensureTmuxSession(target, name string) (*tmuxhost.Client, error) {
	if target != tmuxhost.LocalTarget {
		// The id namespace and the statekv key are already target-shaped;
		// only the transport is missing (design doc §远程).
		return nil, fmt.Errorf("unsupported tmux target %q (v1 is local-only)", target)
	}
	s.tmuxMu.Lock()
	if s.tmuxHost == nil {
		cfg := s.tmuxCfg
		cfg.OnStructure = s.mirrorTmuxStructure // the Server owns the mirror
		if cfg.Logf == nil {
			cfg.Logf = func(format string, args ...any) {
				if s.log != nil {
					s.log.Debug("tmuxhost: " + fmt.Sprintf(format, args...))
				}
			}
		}
		s.tmuxHost = tmuxhost.New(cfg)
	}
	h := s.tmuxHost
	s.tmuxMu.Unlock()
	// Outside tmuxMu: an ensure can launch a whole tmux server (slow), and
	// EnsureLocal serializes racing ensures itself.
	return h.EnsureLocal(name)
}

// mirrorTmuxStructure publishes a target's server-wide structure snapshot
// (every session) through the EXISTING statekv machinery — setState
// persists it and fans `statechanged` out to every established stream — so
// clients discover sessions and panes exactly the way they read workspace
// structure today: re-pull on change. No parallel channel (design doc
// §结构镜像). Called from the control client's refresher goroutine,
// serialized per target (plus the one killSession-of-the-last-session call,
// which runs strictly after that client's refresher has exited — see
// applyKillSession).
func (s *Server) mirrorTmuxStructure(target, current string, sessions []tmuxhost.SessionStructure) {
	key := tmuxStructureKey(target)
	s.tmuxMu.Lock()
	rev := s.tmuxRev[target]
	if rev == 0 {
		// First write since this daemon started: continue the persisted rev
		// line rather than restarting it under a client comparing revs.
		if data := s.getState(key); data != "" {
			var prev tmuxStructureState
			if raw, err := base64.StdEncoding.DecodeString(data); err == nil &&
				json.Unmarshal(raw, &prev) == nil {
				rev = prev.Rev
			}
		}
	}
	rev++
	s.tmuxRev[target] = rev
	s.tmuxMu.Unlock()

	rows := make([]tmuxSessionState, 0, len(sessions))
	var currentSnap tmuxcm.StructureSnapshot
	for _, ses := range sessions {
		attached := ses.Name == current
		if attached {
			currentSnap = ses.Snap
		}
		rows = append(rows, tmuxSessionState{
			ID: ses.ID, Name: ses.Name, Attached: attached, Structure: ses.Snap,
		})
	}

	// After the rev section on purpose: currentTmuxSizing takes sizingMu,
	// which is itself held while taking tmuxMu (resolveAndPushLocked) —
	// nesting them here in the other order would complete a cycle.
	sizing := s.currentTmuxSizing(target)
	raw, err := json.Marshal(tmuxStructureState{
		Rev: rev, Target: target, Session: current, Structure: currentSnap,
		Sizing: &sizing, Sessions: rows,
	})
	if err != nil {
		s.warnf("tmux structure mirror: marshal failed", "err", err)
		return
	}
	s.setState(key, base64.StdEncoding.EncodeToString(raw), nil)
}

// tmuxPaneFor returns the live virtual instance for a pane id, creating it
// on first attach. Created lazily per pane rather than eagerly per snapshot
// because a pane only needs an event log once somebody watches it.
func (s *Server) tmuxPaneFor(id, target string, pane tmuxcm.PaneID) (*tmuxPane, error) {
	s.tmuxMu.Lock()
	if p := s.tmuxPanes[id]; p != nil && !p.exitedFlag.Load() {
		s.tmuxMu.Unlock()
		return p, nil
	}
	s.tmuxMu.Unlock()
	cli, err := s.tmuxClientFor(target)
	if err != nil {
		return nil, err
	}
	p := &tmuxPane{
		instanceCore: instanceCore{
			id:     id,
			subs:   make(map[*session]bool),
			events: newEventLog(s.warnf),
			// logRoot deliberately "": a pane's scrollback lives in the
			// memory tail. Pane ids do not survive a tmux SERVER restart,
			// so durably keying history by them could resurrect the wrong
			// pane's bytes; capture-pane seeding below is what covers the
			// fresh-instance blankness instead.
		},
		target: target,
		pane:   pane,
		host:   cli,
		onGone: func(p *tmuxPane) { s.dropTmuxPane(id, p) },
	}
	// Seed the empty log with the pane's current screen BEFORE subscribing,
	// so every seed entry precedes every live chunk (docs/tmux-host-design.md
	// §顺序 5). A fresh daemon adopting a pre-existing session thus shows the
	// screen, not blankness. Seed entries are ordinary entries — seqs from 1,
	// one entry per wire unit, nothing marks them synthetic (proto.go). Best
	// effort: a pane that vanishes mid-seed fails the subscribe below anyway.
	if seed, err := cli.CapturePaneText(pane); err != nil {
		s.warnf("tmux pane seed capture failed", "pane", id, "err", err)
	} else if len(seed) > 0 {
		p.mu.Lock()
		for off := 0; off < len(seed); off += StdioChunk {
			p.events.append(seed[off:min(off+StdioChunk, len(seed))])
		}
		p.mu.Unlock()
	}
	cancel, err := cli.SubscribePane(pane, p.feed, p.paneClosed)
	if err != nil {
		return nil, err
	}
	s.tmuxMu.Lock()
	if existing := s.tmuxPanes[id]; existing != nil && !existing.exitedFlag.Load() {
		// Lost a racing creation; theirs is live — use it.
		s.tmuxMu.Unlock()
		cancel()
		return existing, nil
	}
	s.tmuxPanes[id] = p
	s.tmuxMu.Unlock()
	return p, nil
}

// dropTmuxPane forgets a pane instance the moment its pane (or its control
// client) is gone. Immediate, unlike gcExited's grace period: tmux reuses
// pane numbers, so a corpse parked under `tmux:local:%3` would sit exactly
// where the NEXT pane named %3 must go.
func (s *Server) dropTmuxPane(id string, p *tmuxPane) {
	s.tmuxMu.Lock()
	if s.tmuxPanes[id] == p {
		delete(s.tmuxPanes, id)
	}
	s.tmuxMu.Unlock()
}

// ---- stream side: the two routed ops ----

// spawnTmux is `spawn` with kind=tmux: an ENSURE, not a process start. It
// does NOT bind the stream to an instance — panes are attached one by one
// through the ordinary attach op, with ids the client digs out of the
// structure mirror this ensure just wrote (EnsureLocal returns only after
// that first mirror has been published, so by the time this ack lands a
// getstate cannot read empty).
func (t *session) spawnTmux(c Control) {
	target := c.Target
	if target == "" {
		target = tmuxhost.LocalTarget
	}
	name := c.SessionID
	if name == "" {
		name = "bento"
	}
	if _, err := t.server.ensureTmuxSession(target, name); err != nil {
		t.sendControl(Control{Op: "attachFailed", Error: err.Error()})
		return
	}
	// Re-push the size authority onto the (possibly fresh) control client:
	// a viewport declared before this ensure — or before a control-client
	// respawn — must govern the new client too (tmuxsizing.go).
	t.server.recomputeTmuxSizing(target)
	t.log.Info("tmux session ensured", "target", target, "session", name)
	t.sendControl(Control{Op: "attached", AgentID: "tmux:" + target, Running: true})
}

// attachTmux is the attach op for the tmux id namespace. The virtual
// instance is created on the first attach and persists across detaches, so
// its seq cursor and scrollback behave exactly like an ACP instance's.
func (t *session) attachTmux(c Control) {
	target, paneID, ok := parseTmuxAgentID(c.AgentID)
	if !ok {
		t.sendControl(Control{Op: "attachFailed", AgentID: c.AgentID, Error: "malformed tmux agent id"})
		return
	}
	p, err := t.server.tmuxPaneFor(c.AgentID, target, paneID)
	if err != nil {
		t.sendControl(Control{Op: "attachFailed", AgentID: c.AgentID, Error: err.Error()})
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

// ---- the virtual instance ----

// tmuxPane is one tmux pane exposed as a hosted instance. No JSON-RPC, no
// id rewriting, no `_seq` injection: log entries are raw output chunks, and
// the wire contract is one log entry per stdio unit (proto.go) so a client
// can keep its catch-up cursor by counting units — raw terminal bytes,
// unlike ACP notifications, have nowhere to carry a stamp in-band.
type tmuxPane struct {
	instanceCore
	target string
	pane   tmuxcm.PaneID
	host   *tmuxhost.Client
	// onGone drops this pane from the server registry once it exits.
	onGone func(*tmuxPane)
}

// attach mirrors agentInstance.attach minus the ACP half: no queued agent
// requests to replay, no session-result cache, no holds-transcript
// asymmetry — the log is the only history channel a pane has.
func (p *tmuxPane) attach(s *session, haveSeq uint64, catchup bool) {
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
	s.log.Info("tmux pane attached", "pane", p.id, "have_seq", haveSeq,
		"head_seq", head, "start_seq", start, "replay", replay, "viewers", viewers)
	s.sendControl(Control{
		Op: "attached", AgentID: p.id, Running: running,
		HeadSeq: head, StartSeq: start, Replay: replay,
	})
	if replay {
		was := running
		go p.replayAndJoin(s, haveSeq, func() func() { return p.joinLocked(s, was) })
		return
	}
	// Exited before this stream joined (the pane died between tmuxPaneFor
	// returning it live and this attach): hand the exit over point-to-point,
	// exactly once — ptyPane.attach's mu-proven pattern. noteExit snapshots
	// its broadcast targets under the same p.mu this attach adds `s` under,
	// so the two are mutually exclusive: exit-then-add reads running=false
	// here (broadcast provably missed us), add-then-exit reads running=true
	// (the broadcast provably covers us).
	if !running {
		s.sendControl(Control{Op: "exit", AgentID: p.id, Code: exitCode, Error: exitErr})
	}
}

// joinLocked runs under p.mu at the instant a replaying stream joins the
// live set. Like agentInstance.replayJoinLocked, it re-checks liveness for
// the window the replay left uncovered: exit controls go point-to-point to
// the attached set, which this stream was not yet part of.
func (p *tmuxPane) joinLocked(s *session, wasRunning bool) func() {
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

// feed is the pane's inbound path, called by the tmuxhost pane pump — one
// goroutine, chunks in output order. Append and target snapshot share ONE
// critical section (the invariant instanceCore.replayAndJoin builds on,
// same as sequenceNotification); the sends happen after unlock because
// sendStdio blocks on the receiver's credit window.
//
// Chunks are split at StdioChunk so every log entry is exactly one wire
// unit — the 1:1 that makes counting units a valid client cursor.
func (p *tmuxPane) feed(chunk []byte) {
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

// paneClosed is the subscription's terminal callback: the pane itself
// closed (err nil) or the control client died under it. Either way this
// virtual instance is over — a later ensure+attach builds a fresh one — so
// the registry forgets it immediately (see dropTmuxPane).
func (p *tmuxPane) paneClosed(err error) {
	msg := ""
	if err != nil {
		msg = err.Error()
	}
	p.noteExit(0, msg)
	if p.onGone != nil {
		p.onGone(p)
	}
}

// handleClientStdio forwards a viewer's bytes into the pane. Raw and
// unframed on purpose — terminal input has no line discipline to reassemble
// (contrast agentInstance's per-stream JSON-RPC line buffers) — and
// send-keys -H carries every byte intact through tmux's parser.
func (p *tmuxPane) handleClientStdio(s *session, b []byte) {
	if err := p.host.WritePane(p.pane, b); err != nil {
		s.sendControl(Control{Op: "stderr", Line: "[bento] tmux pane write failed: " + err.Error()})
	}
}

func (p *tmuxPane) detach(s *session) {
	p.mu.Lock()
	delete(p.subs, s)
	p.mu.Unlock()
}

// kill is a deliberate no-op: pane lifecycle belongs to the `structure` op
// (kill-pane and friends), reserved for the next step — see proto.go. A
// client's kill today must not be able to take a tmux pane down by
// accident.
func (p *tmuxPane) kill() {}
