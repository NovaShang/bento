package acphost

// Live coverage for P7 steps 4+5 (docs/tmux-host-design.md §协议扩展 3–4,
// §测试路线), against a REAL tmux on a private -L socket:
//
//   - every implemented structure verb round-trips: verb → structureApplied
//     rev → the statekv mirror at that rev shows the effect;
//   - the not-faithfully-translatable verbs refuse loudly;
//   - the resize op round-trips (mirror AND list-panes report the size);
//   - capture-pane seeding: a pre-populated pane's screen arrives on first
//     attach, before any live bytes, as ordinary seq-1.. entries;
//   - the per-session credit window stalls a tmux pane broadcast and credit
//     resumes it — the same window discipline ACP instances live under.

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/novashang/bento/daemon/internal/tmuxcm"
)

// ensureTmuxWork spawns kind=tmux for session "work" and waits out the ack.
func ensureTmuxWork(t *testing.T, server *Server) *plainClient {
	t.Helper()
	c := newPlainClient(server)
	c.control(Control{Op: "spawn", Kind: "tmux", SessionID: "work"})
	for {
		ctrl := c.nextControl(t, 30*time.Second)
		if ctrl.Op == "attachFailed" {
			t.Fatalf("tmux ensure failed: %+v", ctrl)
		}
		if ctrl.Op == "attached" {
			return c
		}
	}
}

// applyVerb sends one structure verb and returns its applied/failed reply.
func applyVerb(t *testing.T, c *plainClient, verb StructureVerb) Control {
	t.Helper()
	c.control(Control{Op: "structure", Verb: &verb})
	for {
		ctrl := c.nextControl(t, 25*time.Second)
		if ctrl.Op == "structureApplied" || ctrl.Op == "structureFailed" {
			return ctrl
		}
	}
}

// mustApply asserts the verb landed and returns the ack rev.
func mustApply(t *testing.T, c *plainClient, verb StructureVerb) uint64 {
	t.Helper()
	ctrl := applyVerb(t, c, verb)
	if ctrl.Op != "structureApplied" || ctrl.Rev == 0 {
		t.Fatalf("verb %s not applied: %+v", verb.Kind, ctrl)
	}
	return ctrl.Rev
}

// mustRefuse asserts the verb failed loudly.
func mustRefuse(t *testing.T, c *plainClient, verb StructureVerb) {
	t.Helper()
	ctrl := applyVerb(t, c, verb)
	if ctrl.Op != "structureFailed" || ctrl.Error == "" {
		t.Fatalf("verb %s must refuse with an error, got %+v", verb.Kind, ctrl)
	}
	t.Logf("verb %s refused as designed: %s", verb.Kind, ctrl.Error)
}

// structureAtRev fetches the mirror and asserts the ack's promise: the
// readable rev is at least the acked one (the acked value is never older).
func structureAtRev(t *testing.T, c *plainClient, rev uint64) tmuxStructureState {
	t.Helper()
	doc := fetchStructure(t, c)
	if doc.Rev < rev {
		t.Fatalf("mirror rev %d is older than the ack rev %d", doc.Rev, rev)
	}
	return doc
}

// paneDetail digs one pane's reading out of the mirror.
func paneDetail(t *testing.T, doc tmuxStructureState, id tmuxcm.PaneID) tmuxcm.SnapshotPane {
	t.Helper()
	for _, w := range doc.Structure.Windows {
		for _, d := range w.Details {
			if d.ID == id {
				return d
			}
		}
	}
	t.Fatalf("pane %s missing from mirror details: %s", id, doc.Structure.DebugJSON())
	return tmuxcm.SnapshotPane{}
}

// attachPane attaches a client to a pane and returns the attached /
// attachFailed reply, skipping any interleaved statechanged fan-out (mirror
// refreshes run concurrently and their broadcasts are legal here).
func attachPane(t *testing.T, c *plainClient, pane tmuxcm.PaneID, haveSeq uint64) Control {
	t.Helper()
	c.control(Control{
		Op: "attach", AgentID: fmt.Sprintf("tmux:local:%s", pane),
		Catchup: true, HaveSeq: haveSeq,
	})
	for {
		ctrl := c.nextControl(t, 10*time.Second)
		if ctrl.Op == "attached" || ctrl.Op == "attachFailed" {
			return ctrl
		}
	}
}

// tmuxCLIOut runs one tmux command against the private socket and returns
// its output (the read-side counterpart of tmuxCLI).
func tmuxCLIOut(t *testing.T, server *Server, args ...string) string {
	t.Helper()
	full := append([]string{"-L", server.tmuxCfg.SocketName}, args...)
	out, err := exec.Command(server.tmuxCfg.TmuxPath, full...).CombinedOutput()
	if err != nil {
		t.Fatalf("tmux %v: %v (%s)", args, err, out)
	}
	return string(out)
}

func TestLiveTmuxStructureVerbsPaneRoundTrip(t *testing.T) {
	server := newTmuxLiveServer(t)
	c := ensureTmuxWork(t, server)

	doc := fetchStructure(t, c)
	if len(doc.Structure.AllPanes()) != 1 {
		t.Fatalf("fresh session shape wrong: %s", doc.Structure.DebugJSON())
	}
	p0 := doc.Structure.AllPanes()[0]
	prevRev := doc.Rev

	step := func(verb StructureVerb) tmuxStructureState {
		t.Helper()
		rev := mustApply(t, c, verb)
		if rev <= prevRev {
			t.Fatalf("%s: ack rev %d did not advance past %d", verb.Kind, rev, prevRev)
		}
		prevRev = rev
		return structureAtRev(t, c, rev)
	}

	// splitPane: one window, two panes.
	doc = step(StructureVerb{Kind: "splitPane", Session: "work", Target: int(p0), Horizontal: true})
	if len(doc.Structure.Windows) != 1 || len(doc.Structure.AllPanes()) != 2 {
		t.Fatalf("split effect missing at ack rev: %s", doc.Structure.DebugJSON())
	}
	var p1 tmuxcm.PaneID
	for _, p := range doc.Structure.AllPanes() {
		if p != p0 {
			p1 = p
		}
	}

	// renamePane: pane_title lands in the mirror's Details.
	doc = step(StructureVerb{Kind: "renamePane", Pane: int(p1), To: "build-pane"})
	if got := paneDetail(t, doc, p1).Title; got != "build-pane" {
		t.Fatalf("renamePane effect missing at ack rev: title %q", got)
	}

	// selectPane: split focused p1; select p0 back.
	doc = step(StructureVerb{Kind: "selectPane", Pane: int(p0)})
	if !paneDetail(t, doc, p0).Active || paneDetail(t, doc, p1).Active {
		t.Fatalf("selectPane effect missing at ack rev: %s", doc.Structure.DebugJSON())
	}

	// toggleZoom: zoomed flag on, then off.
	doc = step(StructureVerb{Kind: "toggleZoom", Pane: int(p0)})
	if !paneDetail(t, doc, p0).Zoomed {
		t.Fatalf("zoom effect missing at ack rev: %s", doc.Structure.DebugJSON())
	}
	doc = step(StructureVerb{Kind: "toggleZoom", Pane: int(p0)})
	if paneDetail(t, doc, p0).Zoomed {
		t.Fatalf("unzoom effect missing at ack rev: %s", doc.Structure.DebugJSON())
	}

	// resizePane: the border moves by exactly the asked amount.
	before := paneDetail(t, doc, p0).Width
	doc = step(StructureVerb{Kind: "resizePane", Pane: int(p0), Direction: "R", Amount: 5})
	after := paneDetail(t, doc, p0).Width
	if diff := after - before; diff != 5 && diff != -5 {
		t.Fatalf("resizePane must move the border 5 cells, width went %d → %d", before, after)
	}

	// swapPanes: the two panes exchange geometry slots…
	d0, d1 := paneDetail(t, doc, p0), paneDetail(t, doc, p1)
	doc = step(StructureVerb{Kind: "swapPanes", A: int(p0), B: int(p1)})
	if got := paneDetail(t, doc, p0); got.X != d1.X || got.Width != d1.Width {
		t.Fatalf("swapPanes effect missing: p0 at x=%d w=%d, want x=%d w=%d",
			got.X, got.Width, d1.X, d1.Width)
	}
	// …and swapPane(up) with two panes swaps them straight back.
	doc = step(StructureVerb{Kind: "swapPane", Pane: int(p0), Up: true})
	if got := paneDetail(t, doc, p0); got.X != d0.X || got.Width != d0.Width {
		t.Fatalf("swapPane(up) effect missing: p0 at x=%d w=%d, want x=%d w=%d",
			got.X, got.Width, d0.X, d0.Width)
	}

	// renameSession: the mirror's Session field tracks the rename.
	doc = step(StructureVerb{Kind: "renameSession", Name: "work", To: "workbench"})
	if doc.Session != "workbench" {
		t.Fatalf("renameSession effect missing at ack rev: session %q", doc.Session)
	}

	// killPane: back down to one pane.
	doc = step(StructureVerb{Kind: "killPane", Pane: int(p1)})
	if len(doc.Structure.AllPanes()) != 1 {
		t.Fatalf("killPane effect missing at ack rev: %s", doc.Structure.DebugJSON())
	}
	t.Logf("pane verb round-trip verified through mirror rev %d", prevRev)
}

func TestLiveTmuxStructureVerbsWindowsAndTiling(t *testing.T) {
	server := newTmuxLiveServer(t)
	c := ensureTmuxWork(t, server)

	doc := fetchStructure(t, c)
	p0 := doc.Structure.AllPanes()[0]

	// newPane twice: each is a fresh one-pane window (the Parallel shape).
	rev := mustApply(t, c, StructureVerb{Kind: "newPane", Session: "work"})
	doc = structureAtRev(t, c, rev)
	if len(doc.Structure.Windows) != 2 || len(doc.Structure.AllPanes()) != 2 {
		t.Fatalf("newPane effect missing at ack rev: %s", doc.Structure.DebugJSON())
	}
	p1 := doc.Structure.AllPanes()[1]
	rev = mustApply(t, c, StructureVerb{Kind: "newPane", Session: "work"})
	doc = structureAtRev(t, c, rev)
	if len(doc.Structure.Windows) != 3 {
		t.Fatalf("second newPane effect missing: %s", doc.Structure.DebugJSON())
	}
	p2 := doc.Structure.AllPanes()[2]

	// reorderPanes: session-wide order becomes [p2, p0, p1].
	rev = mustApply(t, c, StructureVerb{
		Kind: "reorderPanes", Session: "work", Order: []int{int(p2), int(p0), int(p1)},
	})
	doc = structureAtRev(t, c, rev)
	if got := doc.Structure.AllPanes(); len(got) != 3 || got[0] != p2 || got[1] != p0 || got[2] != p1 {
		t.Fatalf("reorderPanes effect missing at ack rev: %v", got)
	}

	// applyTiled: gather everything into one tiled window, order preserved.
	rev = mustApply(t, c, StructureVerb{Kind: "applyTiled", Session: "work"})
	doc = structureAtRev(t, c, rev)
	if len(doc.Structure.Windows) != 1 {
		t.Fatalf("applyTiled must end with one window: %s", doc.Structure.DebugJSON())
	}
	if got := doc.Structure.AllPanes(); got[0] != p2 || got[1] != p0 || got[2] != p1 {
		t.Fatalf("applyTiled must keep the session order: %v", got)
	}

	// reorderPanes on a shared window has no faithful translation → refuse.
	mustRefuse(t, c, StructureVerb{
		Kind: "reorderPanes", Session: "work", Order: []int{int(p0), int(p1), int(p2)},
	})

	// dockPane: p1 docks onto p2's top edge (vertical, before).
	rev = mustApply(t, c, StructureVerb{
		Kind: "dockPane", Source: int(p1), At: int(p2), Horizontal: false, Before: true,
	})
	doc = structureAtRev(t, c, rev)
	dSrc, dAt := paneDetail(t, doc, p1), paneDetail(t, doc, p2)
	if len(doc.Structure.Windows) != 1 || dSrc.X != dAt.X || dSrc.Y >= dAt.Y {
		t.Fatalf("dockPane effect missing: src(x=%d,y=%d) at(x=%d,y=%d) in %s",
			dSrc.X, dSrc.Y, dAt.X, dAt.Y, doc.Structure.DebugJSON())
	}
	t.Log("window verbs + tiling round-trip verified")
}

func TestLiveTmuxStructureVerbsRefused(t *testing.T) {
	server := newTmuxLiveServer(t)
	c := ensureTmuxWork(t, server)

	// No faithful v1 translation — must refuse, never approximate.
	mustRefuse(t, c, StructureVerb{Kind: "createSession", Name: "second"})
	mustRefuse(t, c, StructureVerb{Kind: "killSession", Name: "work"})
	mustRefuse(t, c, StructureVerb{Kind: "movePane", Pane: 0, ToSession: "second"})

	// Malformed inputs fail loudly too.
	mustRefuse(t, c, StructureVerb{Kind: "frobnicate"})
	mustRefuse(t, c, StructureVerb{Kind: "resizePane", Pane: 0, Direction: "sideways", Amount: 2})
	mustRefuse(t, c, StructureVerb{Kind: "splitPane", Session: "other", Target: 0})
	mustRefuse(t, c, StructureVerb{Kind: "killPane", Pane: 999})

	// A refusal writes nothing: the mirror still shows the untouched session.
	doc := fetchStructure(t, c)
	if len(doc.Structure.AllPanes()) != 1 || doc.Session != "work" {
		t.Fatalf("refused verbs must not mutate: %s", doc.Structure.DebugJSON())
	}
}

func TestLiveTmuxResizeOpRoundTrip(t *testing.T) {
	server := newTmuxLiveServer(t)
	c := ensureTmuxWork(t, server)

	doc := fetchStructure(t, c)
	p0 := doc.Structure.AllPanes()[0]
	rev := mustApply(t, c, StructureVerb{Kind: "splitPane", Session: "work", Target: int(p0), Horizontal: true})
	doc = structureAtRev(t, c, rev)
	height := paneDetail(t, doc, p0).Height

	// The op proper: resize-pane -x 70 -y <current>.
	agentID := fmt.Sprintf("tmux:local:%s", p0)
	c.control(Control{Op: "resize", AgentID: agentID, Cols: 70, Rows: height})
	var ack Control
	for {
		ack = c.nextControl(t, 20*time.Second)
		if ack.Op == "structureApplied" || ack.Op == "structureFailed" {
			break
		}
	}
	if ack.Op != "structureApplied" || ack.AgentID != agentID || ack.Rev == 0 {
		t.Fatalf("resize not acked: %+v", ack)
	}

	// The mirror at the ack rev reports the new size…
	doc = structureAtRev(t, c, ack.Rev)
	if got := paneDetail(t, doc, p0); got.Width != 70 || got.Height != height {
		t.Fatalf("resize effect missing at ack rev: %dx%d, want 70x%d", got.Width, got.Height, height)
	}
	// …and so does tmux's own list-panes (the outside truth).
	listing := tmuxCLIOut(t, server, "list-panes", "-t", "work:", "-F", "#{pane_id}:#{pane_width}")
	if !strings.Contains(listing, fmt.Sprintf("%s:70", p0)) {
		t.Fatalf("list-panes does not report the resize: %q", listing)
	}

	// Failure shapes: non-tmux ids and non-positive geometry refuse.
	for _, bad := range []Control{
		{Op: "resize", AgentID: "agent-12345", Cols: 80, Rows: 24},
		{Op: "resize", AgentID: agentID, Cols: 0, Rows: 24},
	} {
		c.control(bad)
		for {
			ctrl := c.nextControl(t, 10*time.Second)
			if ctrl.Op == "structureFailed" {
				break
			}
			if ctrl.Op == "structureApplied" {
				t.Fatalf("bad resize %+v must fail", bad)
			}
		}
	}
	t.Logf("resize round-trip verified at rev %d", ack.Rev)
}

func TestLiveTmuxCapturePaneSeeding(t *testing.T) {
	server := newTmuxLiveServer(t)
	c := ensureTmuxWork(t, server)

	doc := fetchStructure(t, c)
	pane := doc.Structure.AllPanes()[0]

	// Pre-populate the pane BEFORE anyone attaches — the "fresh daemon
	// adopting a pre-existing tmux session" shape, driven from outside.
	tmuxCLI(t, server, "send-keys", "-t", pane.String(), "-l", `printf 'BEN''TO_SEED_MARK\n'`)
	tmuxCLI(t, server, "send-keys", "-t", pane.String(), "Enter")
	deadline := time.Now().Add(15 * time.Second)
	for {
		if strings.Contains(tmuxCLIOut(t, server, "capture-pane", "-p", "-t", pane.String()), "BENTO_SEED_MARK") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("marker never reached the pane screen")
		}
		time.Sleep(100 * time.Millisecond)
	}

	// First attach: the seed must be there already — Replay granted, log
	// starting at seq 1 — and the screen content arrives with NO live input.
	viewer := newPlainClient(server)
	at := attachPane(t, viewer, pane, 0)
	if at.Op != "attached" || !at.Replay || at.StartSeq != 1 || at.HeadSeq == 0 {
		t.Fatalf("seeded first attach must replay from seq 1: %+v", at)
	}
	seed := collectStdioUntil(t, viewer, "BENTO_SEED_MARK", 10*time.Second)
	t.Logf("capture seed replayed: %d bytes, head_seq=%d", len(seed), at.HeadSeq)

	// Live bytes continue after the seed on the same cursor line.
	viewer.stdioRaw([]byte("printf 'BEN''TO_LIVE_MARK\\n'\r"))
	collectStdioUntil(t, viewer, "BENTO_LIVE_MARK", 15*time.Second)

	// A later fresh viewer replays seed-then-live in order: the seed marker
	// precedes the live one in the byte stream.
	v2 := newPlainClient(server)
	if at2 := attachPane(t, v2, pane, 0); at2.Op != "attached" || !at2.Replay || at2.StartSeq != 1 {
		t.Fatalf("second attach must replay the full log: %+v", at2)
	}
	all := collectStdioUntil(t, v2, "BENTO_LIVE_MARK", 10*time.Second)
	iSeed := bytes.Index(all, []byte("BENTO_SEED_MARK"))
	iLive := bytes.Index(all, []byte("BENTO_LIVE_MARK"))
	if iSeed < 0 || iSeed > iLive {
		t.Fatalf("seed must precede live bytes (seed@%d live@%d)", iSeed, iLive)
	}
	_ = c
}

func TestLiveTmuxPaneCreditStallAndResume(t *testing.T) {
	server := newTmuxLiveServer(t)
	c := ensureTmuxWork(t, server)

	doc := fetchStructure(t, c)
	pane := doc.Structure.AllPanes()[0]

	viewer := newPlainClient(server)
	if at := attachPane(t, viewer, pane, 0); at.Op != "attached" {
		t.Fatalf("attach failed: %+v", at)
	}

	// Flood ≈ 600 KiB — far past InitialWindow (256 KiB) — then a marker.
	// Few, LARGE lines on purpose: while the pump is stalled the pane-sub
	// queue buffers at most paneSubQueue chunks and drops the overflow (the
	// documented backstop; capture-pane repair is a later step), so the test
	// keeps the flood's chunk count well under that budget — 600 lines of
	// 1000 chars, not thousands of short ones.
	viewer.stdioRaw([]byte(fmt.Sprintf(
		"x=%s; x=$x$x$x$x$x$x$x$x$x$x; i=0; while [ $i -lt 600 ]; do echo $x; i=$((i+1)); done; "+
			"printf 'BEN''TO_FLOOD_DONE\\n'\r",
		strings.Repeat("x", 100))))

	// Drain until the stream goes quiet: the credit window must have starved
	// the pump long before the flood (or its marker) got through.
	var got []byte
	received := 0
	drainUntilQuiet := func(idle time.Duration) {
		for {
			select {
			case u := <-viewer.out.units:
				if len(u) > 0 && u[0] == unitTypeStdio {
					received += len(u) - 1
					got = append(got, u[1:]...)
				}
			case <-time.After(idle):
				return
			}
		}
	}
	drainUntilQuiet(1500 * time.Millisecond)
	if received == 0 {
		t.Fatal("no pane output at all")
	}
	if received > InitialWindow+StdioChunk {
		t.Fatalf("credit window not enforced on tmux pane stdio: got %d bytes", received)
	}
	if bytes.Contains(got, []byte("BENTO_FLOOD_DONE")) {
		t.Fatalf("flood completed without credit (%d bytes)", received)
	}
	stalledAt := received
	t.Logf("pump stalled at %d bytes (window %d)", stalledAt, InitialWindow)

	// Credit resumes the pump; the whole flood then lands.
	viewer.control(Control{Op: "credit", Bytes: 8 << 20})
	deadline := time.Now().Add(60 * time.Second)
	for !bytes.Contains(got, []byte("BENTO_FLOOD_DONE")) {
		remain := time.Until(deadline)
		if remain <= 0 {
			t.Fatalf("flood never completed after credit (%d bytes)", received)
		}
		typ, payload := viewer.nextUnit(t, remain)
		if typ != unitTypeStdio {
			continue
		}
		received += len(payload)
		got = append(got, payload...)
	}
	if received <= stalledAt {
		t.Fatal("credit did not move the stream")
	}
	t.Logf("credit resumed the pump: %d bytes total", received)
	_ = c
}
