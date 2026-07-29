package acphost

// The 步骤 5.5 batch (docs/tmux-host-design.md), live against a REAL tmux on
// a private -L socket plus two non-tmux invariants:
//
//   - viewport / setSizePolicy round-trips: declarations and policy land in
//     the mirror's sizing block (policy + owner label + resolved size), the
//     control client's declared size follows (asserted via tmux's own
//     list-clients / list-windows — see assertDeclaredSize; the reflow is
//     also visible as the mirror's pane width tracking the governing cols,
//     which is the %layout-change → mirror path);
//   - pinned follows its owner and releases to latest when the owner stream
//     closes; smallest is the per-axis minimum; bogus policies and ownerless
//     pins refuse loudly;
//   - SnapshotWindow.Active tracks select-window, including an OUTSIDE
//     select-window (the %session-window-changed → refresh path);
//   - a tmux pane that died before a stream joined still hands that stream
//     the exit control exactly once (ptyPane.attach's mu-proven pattern);
//   - AgentCounts counts pty panes (daemon-mortal) and refuses to count tmux
//     panes (the tmux server outlives the daemon).

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	tmuxhost "github.com/novashang/bento/daemon/internal/host/tmux"
)

// waitSizing polls the mirror until its sizing block satisfies cond,
// returning the matching document. Polling rather than counting statechanged
// fan-outs: refresh passes run concurrently and their broadcasts interleave
// freely, but the KV read is the actual contract.
func waitSizing(t *testing.T, c *plainClient, what string,
	cond func(tmuxhost.Sizing) bool) tmuxStructureState {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for {
		doc := fetchStructure(t, c)
		if doc.Sizing != nil && cond(*doc.Sizing) {
			return doc
		}
		if time.Now().After(deadline) {
			t.Fatalf("mirror sizing never became %s; last %+v", what, doc.Sizing)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func sizingIs(policy, owner string, cols, rows int) func(tmuxhost.Sizing) bool {
	return func(s tmuxhost.Sizing) bool {
		return s.Policy == policy && s.OwnerDevice == owner && s.Cols == cols && s.Rows == rows
	}
}

// assertDeclaredSize checks the governing size reached tmux itself: the
// control client's declared width (list-clients; #{client_height} is empty
// on tmux 3.7b, see the call site) and the window geometry that follows it
// under window-size latest. Polled briefly — the refresh-client is queued on
// the control connection, and the CLI reads through a different one.
func assertDeclaredSize(t *testing.T, server *Server, cols, rows int) {
	t.Helper()
	want := fmt.Sprintf("%dx%d", cols, rows)
	deadline := time.Now().Add(10 * time.Second)
	for {
		width := strings.TrimSpace(tmuxCLIOut(t, server, "list-clients", "-F", "#{client_width}"))
		win := strings.TrimSpace(tmuxCLIOut(t, server, "list-windows", "-t", "work:",
			"-F", "#{window_width}x#{window_height}"))
		if width == fmt.Sprintf("%d", cols) && !strings.Contains(win, "\n") && win == want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("declared size never reached tmux: client_width=%q window=%q, want %s",
				width, win, want)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func TestLiveTmuxViewportAndSizePolicyRoundTrip(t *testing.T) {
	server := newTmuxLiveServer(t)
	observer := ensureTmuxWork(t, server) // never declares; reads the mirror

	// The ensure's first mirror already carries the sizing block: policy
	// latest, nobody declared, the 200×50 launch default.
	doc := fetchStructure(t, observer)
	if doc.Sizing == nil || !sizingIs("latest", "", 200, 50)(*doc.Sizing) {
		t.Fatalf("fresh mirror sizing wrong: %+v", doc.Sizing)
	}
	pane := doc.Structure.AllPanes()[0]

	// --- viewport under latest: the declaration governs ---
	a := newPlainClient(server)
	a.control(Control{Op: "viewport", Cols: 120, Rows: 40})
	doc = waitSizing(t, observer, "latest/120x40", sizingIs("latest", "", 120, 40))
	t.Logf("mirror sizing after A declares: %+v (rev %d)", *doc.Sizing, doc.Rev)

	// The control client really declared it to tmux (refresh-client -C) —
	// asserted via tmux's own listings, the flake-free stand-in for watching
	// the reflow byte-stream. #{client_width} carries the declaration;
	// #{client_height} evaluates EMPTY on tmux 3.7b (verified by hand — the
	// declared height still takes effect), so the height is asserted through
	// the window, which under window-size latest tracks the governing size
	// exactly (control clients render no status line).
	assertDeclaredSize(t, server, 120, 40)
	// And tmux reflowed: the pane's width in the mirror follows the
	// governing cols (%layout-change → refresh → the one write path).
	deadline := time.Now().Add(15 * time.Second)
	for paneDetail(t, doc, pane).Width != 120 {
		if time.Now().After(deadline) {
			t.Fatalf("pane never reflowed to 120 cols: %s", doc.Structure.DebugJSON())
		}
		time.Sleep(100 * time.Millisecond)
		doc = fetchStructure(t, observer)
	}

	// --- latest wins by declaration order: B declares later, B governs ---
	b := newPlainClient(server)
	b.control(Control{Op: "viewport", Cols: 100, Rows: 30})
	waitSizing(t, observer, "latest/100x30", sizingIs("latest", "", 100, 30))

	// --- pinned: A pins; the owner's grid governs though B declared later ---
	rev := mustApply(t, a, StructureVerb{
		Kind: "setSizePolicy", Policy: "pinned", OwnerDevice: "Shang iPad Air",
	})
	doc = structureAtRev(t, observer, rev)
	if doc.Sizing == nil || !sizingIs("pinned", "Shang iPad Air", 120, 40)(*doc.Sizing) {
		t.Fatalf("pinned sizing wrong at ack rev %d: %+v", rev, doc.Sizing)
	}

	// A non-owner declaration must not move the governing size…
	b.control(Control{Op: "viewport", Cols: 90, Rows: 25})
	time.Sleep(700 * time.Millisecond) // give a wrong implementation time to move it
	doc = fetchStructure(t, observer)
	if !sizingIs("pinned", "Shang iPad Air", 120, 40)(*doc.Sizing) {
		t.Fatalf("non-owner declaration moved a pinned size: %+v", doc.Sizing)
	}
	// …while the owner's re-declaration follows immediately.
	a.control(Control{Op: "viewport", Cols: 130, Rows: 40})
	waitSizing(t, observer, "pinned/130x40", sizingIs("pinned", "Shang iPad Air", 130, 40))

	// --- owner stream closes: pin released, latest resumes (B is the most
	// recent surviving declarer) — the %client-detached role, rehomed ---
	_ = a.sess.Close()
	waitSizing(t, observer, "released latest/90x25", sizingIs("latest", "", 90, 25))

	// --- smallest: per-axis minimum over B(90×25) and C(200×20) → 90×20 ---
	c := newPlainClient(server)
	c.control(Control{Op: "viewport", Cols: 200, Rows: 20})
	rev = mustApply(t, b, StructureVerb{Kind: "setSizePolicy", Policy: "smallest"})
	doc = structureAtRev(t, observer, rev)
	if doc.Sizing == nil || !sizingIs("smallest", "", 90, 20)(*doc.Sizing) {
		t.Fatalf("smallest sizing wrong at ack rev %d: %+v", rev, doc.Sizing)
	}
	assertDeclaredSize(t, server, 90, 20)

	// --- refusals: bogus policy; pinning without a declaration ---
	mustRefuse(t, b, StructureVerb{Kind: "setSizePolicy", Policy: "frobnicate"})
	undeclared := newPlainClient(server)
	mustRefuse(t, undeclared, StructureVerb{Kind: "setSizePolicy", Policy: "pinned"})
	wire, _ := json.Marshal(doc.Sizing)
	t.Logf("sizing round-trip verified through mirror rev %d; wire block: %s", doc.Rev, wire)
}

func TestLiveTmuxWindowActiveTracksSelectWindow(t *testing.T) {
	server := newTmuxLiveServer(t)
	c := ensureTmuxWork(t, server)

	doc := fetchStructure(t, c)
	if len(doc.Structure.Windows) != 1 || !doc.Structure.Windows[0].Active {
		t.Fatalf("a session's only window must be active: %s", doc.Structure.DebugJSON())
	}
	p0 := doc.Structure.AllPanes()[0]
	firstIndex := doc.Structure.Windows[0].Index

	// newPane = new-window, which selects the new window: the mirror at the
	// ack rev must show active having MOVED — exactly one active window, and
	// it is the one holding the new pane.
	rev := mustApply(t, c, StructureVerb{Kind: "newPane", Session: "work"})
	doc = structureAtRev(t, c, rev)
	if len(doc.Structure.Windows) != 2 {
		t.Fatalf("expected 2 windows: %s", doc.Structure.DebugJSON())
	}
	activeCount := 0
	for _, w := range doc.Structure.Windows {
		if !w.Active {
			continue
		}
		activeCount++
		for _, p := range w.Panes {
			if p == p0 {
				t.Fatalf("active window still holds the OLD pane: %s", doc.Structure.DebugJSON())
			}
		}
	}
	if activeCount != 1 {
		t.Fatalf("want exactly one active window, got %d: %s", activeCount, doc.Structure.DebugJSON())
	}

	// An OUTSIDE select-window changes no layout — %session-window-changed
	// is the only signal — and the mirror must still track it.
	tmuxCLI(t, server, "select-window", "-t", fmt.Sprintf("work:%d", firstIndex))
	deadline := time.Now().Add(15 * time.Second)
	for {
		doc = fetchStructure(t, c)
		var active *int
		for i, w := range doc.Structure.Windows {
			if w.Active {
				i := i
				active = &i
			}
		}
		if active != nil && doc.Structure.Windows[*active].Index == firstIndex {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("mirror never tracked the outside select-window: %s", doc.Structure.DebugJSON())
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Log("window-active tracked through verb AND outside select-window")
}

// A tmux pane can die between tmuxPaneFor returning it live and the joining
// stream entering the attached set; noteExit's broadcast then provably
// missed that stream (targets are snapshotted under the same p.mu attach
// adds under). The point-to-point hand-off in tmuxPane.attach — copied from
// ptyPane.attach — must deliver the exit exactly once. Driven directly
// (attach on an already-exited pane) because that interleaving is precisely
// the state the wire cannot set up deterministically.
func TestTmuxPaneExitBeforeJoinHandsExitToJoiner(t *testing.T) {
	server, _, _ := newServer(t, false)
	c := newPlainClient(server)

	p := &tmuxPane{instanceCore: instanceCore{
		id:     "tmux:local:%9",
		subs:   make(map[*session]bool),
		events: newEventLog(server.warnf),
	}}
	p.noteExit(1, "pane closed") // broadcast hit an empty attached set

	p.attach(c.sess, 0, false)
	at := c.nextControl(t, 5*time.Second)
	if at.Op != "attached" || at.Running {
		t.Fatalf("attach to a dead pane must ack Running=false: %+v", at)
	}
	ex := c.nextControl(t, 5*time.Second)
	if ex.Op != "exit" || ex.AgentID != p.id || ex.Code != 1 || ex.Error != "pane closed" {
		t.Fatalf("exit hand-off wrong: %+v", ex)
	}
	// Exactly once: the next control after a ping must be its pong, with no
	// second exit squeezed in between.
	c.control(Control{Op: "ping"})
	if next := c.nextControl(t, 5*time.Second); next.Op != "pong" {
		t.Fatalf("expected pong (no duplicate exit), got %+v", next)
	}
}

// AgentCounts backs the menubar's "restarting kills N agents" warning, so it
// must count what a restart actually kills: pty panes die with the daemon
// (counted), tmux panes live in the tmux server's own process tree and
// survive it (not counted).
func TestAgentCountsCountsPtyPanes(t *testing.T) {
	server, _, _ := newServer(t, false)
	viewer, id := spawnShPane(t, server)
	if live, busy := server.AgentCounts(); live != 1 || busy != 0 {
		t.Fatalf("after pty spawn: live=%d busy=%d, want 1/0", live, busy)
	}
	viewer.control(Control{Op: "kill", AgentID: id})
	waitFor(t, 5*time.Second, "the killed pty pane to stop counting", func() bool {
		live, busy := server.AgentCounts()
		return live == 0 && busy == 0
	})
}

func TestLiveTmuxPanesDoNotCountInAgentCounts(t *testing.T) {
	server := newTmuxLiveServer(t)
	c := ensureTmuxWork(t, server)

	// A live, attached tmux pane — as hosted as a pane gets — still counts
	// for nothing: the daemon restarting does not kill it.
	doc := fetchStructure(t, c)
	viewer := newPlainClient(server)
	if at := attachPane(t, viewer, doc.Structure.AllPanes()[0], 0); at.Op != "attached" {
		t.Fatalf("pane attach failed: %+v", at)
	}
	if live, busy := server.AgentCounts(); live != 0 || busy != 0 {
		t.Fatalf("tmux panes must not count: live=%d busy=%d, want 0/0", live, busy)
	}

	// …while a pty pane on the very same server immediately does.
	spawnShPane(t, server)
	if live, _ := server.AgentCounts(); live != 1 {
		t.Fatalf("pty pane on the same server must count: live=%d, want 1", live)
	}
}
