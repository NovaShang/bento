package acphost

// The design doc's route for step 3 (docs/tmux-host-design.md §测试路线),
// end to end against a REAL tmux on a private -L socket: ensure → statekv
// snapshot present and parseable → attach a pane → write into it → %output
// arrives as sequenced stdio units → reattach with HaveSeq replays only the
// tail → an outside structure change reaches clients as `statechanged`.
//
// Uses the same client rig the ACP tests use (newServerIn/newPlainClient) —
// which is the point: a tmux pane speaks the exact protocol an ACP
// instance does.

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	tmuxhost "github.com/novashang/bento/daemon/internal/host/tmux"
)

// newTmuxLiveServer builds a Server whose tmux host is pinned to a
// throwaway -L socket (kill-server on cleanup) and a fixture config that
// forces default-shell /bin/sh, so pane echo is plain and marker matching
// deterministic. Skips when tmux is absent; where it is installed the test
// must actually run.
func newTmuxLiveServer(t *testing.T) *Server {
	t.Helper()
	bin, err := exec.LookPath("tmux")
	if err != nil {
		t.Skip("tmux not installed — tmux pane live test skipped")
	}
	socket := fmt.Sprintf("bento-acp-live-%d-%d", os.Getpid(), time.Now().UnixNano())
	t.Cleanup(func() { _ = exec.Command(bin, "-L", socket, "kill-server").Run() })

	conf := filepath.Join(t.TempDir(), "tmux.conf")
	if err := os.WriteFile(conf, []byte("set -g default-shell /bin/sh\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	server, _, _ := newServerIn(t, t.TempDir(), false)
	// Pinned before the first tmux spawn — the host is built lazily from
	// this config on that spawn.
	server.tmuxCfg = tmuxhost.Config{TmuxPath: bin, SocketName: socket, ConfigFile: conf}
	return server
}

// tmuxCLI runs one tmux command against the server's private socket — the
// "outside actor" half of the structure tests (a user in a terminal).
func tmuxCLI(t *testing.T, server *Server, args ...string) {
	t.Helper()
	full := append([]string{"-L", server.tmuxCfg.SocketName}, args...)
	if out, err := exec.Command(server.tmuxCfg.TmuxPath, full...).CombinedOutput(); err != nil {
		t.Fatalf("tmux %v: %v (%s)", args, err, out)
	}
}

// collectStdioUntil drains a client's units, accumulating stdio payloads
// (controls pass by) until the marker shows up, and returns everything
// gathered — the caller asserts on the whole buffer.
func collectStdioUntil(t *testing.T, p *plainClient, marker string, timeout time.Duration) []byte {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var seen []byte
	for {
		remain := time.Until(deadline)
		if remain <= 0 {
			t.Fatalf("marker %q not seen in pane stdio; got %q", marker, seen)
		}
		typ, payload := p.nextUnit(t, remain)
		if typ != unitTypeStdio {
			continue
		}
		seen = append(seen, payload...)
		if bytes.Contains(seen, []byte(marker)) {
			return seen
		}
	}
}

// fetchStructure getstates and decodes the structure mirror.
func fetchStructure(t *testing.T, p *plainClient) tmuxStructureState {
	t.Helper()
	p.control(Control{Op: "getstate", Key: tmuxStructureKey("local")})
	for {
		ctrl := p.nextControl(t, 5*time.Second)
		if ctrl.Op != "statedata" {
			continue // statechanged fan-out can interleave; skip past it
		}
		if ctrl.Data == "" {
			t.Fatal("structure mirror missing from statekv")
		}
		raw, err := base64.StdEncoding.DecodeString(ctrl.Data)
		if err != nil {
			t.Fatalf("mirror not base64: %v", err)
		}
		var doc tmuxStructureState
		if err := json.Unmarshal(raw, &doc); err != nil {
			t.Fatalf("mirror not parseable: %v (%s)", err, raw)
		}
		return doc
	}
}

func TestLiveTmuxEnsureStateKVAttachWriteAndCatchup(t *testing.T) {
	server := newTmuxLiveServer(t)

	// --- ensure (spawn kind=tmux) ---
	ensure := newPlainClient(server)
	ensure.control(Control{Op: "spawn", Kind: "tmux", SessionID: "work"})
	// The ensure's own mirror write fans statechanged to every established
	// stream — this one included — and EnsureLocal returns only after that
	// write, so the wire order here is deterministic: statechanged, ack.
	if ctrl := ensure.nextControl(t, 30*time.Second); ctrl.Op != "statechanged" ||
		ctrl.Key != tmuxStructureKey("local") {
		t.Fatalf("expected the mirror's statechanged first, got %+v", ctrl)
	}
	if ack := ensure.nextControl(t, 5*time.Second); ack.Op != "attached" ||
		ack.AgentID != "tmux:local" || !ack.Running {
		t.Fatalf("expected session-level attached ack, got %+v", ack)
	}

	// --- the statekv snapshot is present and parseable ---
	doc := fetchStructure(t, ensure)
	if doc.Rev < 1 || doc.Target != "local" || doc.Session != "work" {
		t.Fatalf("mirror identity wrong: %+v", doc)
	}
	panes := doc.Structure.AllPanes()
	if len(doc.Structure.Windows) != 1 || len(panes) != 1 {
		t.Fatalf("fresh session shape wrong: %s", doc.Structure.DebugJSON())
	}
	t.Logf("statekv mirror rev=%d: %s", doc.Rev, doc.Structure.DebugJSON())
	agentID := fmt.Sprintf("tmux:local:%s", panes[0])

	// --- attach the pane and type into it ---
	viewer := newPlainClient(server)
	viewer.control(Control{Op: "attach", AgentID: agentID, Catchup: true})
	at := viewer.nextControl(t, 10*time.Second)
	if at.Op != "attached" || at.AgentID != agentID || !at.Running {
		t.Fatalf("pane attach failed: %+v", at)
	}
	if at.Replay {
		t.Fatalf("nothing was logged yet — no replay expected: %+v", at)
	}

	// The marker is split in the typed command so the shell's ECHO can
	// never satisfy the match — only printf's actual output can.
	viewer.stdioRaw([]byte("printf 'BEN''TO_MARK_ONE\\n'\r"))
	collectStdioUntil(t, viewer, "BENTO_MARK_ONE", 15*time.Second)

	// --- full catch-up: a second viewer replays the history from seq 0 ---
	v2 := newPlainClient(server)
	v2.control(Control{Op: "attach", AgentID: agentID, Catchup: true})
	at2 := v2.nextControl(t, 10*time.Second)
	if at2.Op != "attached" || !at2.Replay || at2.HeadSeq == 0 || at2.StartSeq != 1 {
		t.Fatalf("full catch-up not granted: %+v", at2)
	}
	collectStdioUntil(t, v2, "BENTO_MARK_ONE", 10*time.Second)
	cursor := at2.HeadSeq // covers everything up to and including marker one

	// --- write more, then a third viewer catches up from the cursor ---
	viewer.stdioRaw([]byte("printf 'BEN''TO_MARK_TWO\\n'\r"))
	collectStdioUntil(t, viewer, "BENTO_MARK_TWO", 15*time.Second)
	collectStdioUntil(t, v2, "BENTO_MARK_TWO", 10*time.Second) // v2 joined the live set

	v3 := newPlainClient(server)
	v3.control(Control{Op: "attach", AgentID: agentID, Catchup: true, HaveSeq: cursor})
	at3 := v3.nextControl(t, 10*time.Second)
	if at3.Op != "attached" || !at3.Replay {
		t.Fatalf("tail catch-up not granted: %+v", at3)
	}
	tail := collectStdioUntil(t, v3, "BENTO_MARK_TWO", 10*time.Second)
	if bytes.Contains(tail, []byte("BENTO_MARK_ONE")) {
		t.Fatalf("HaveSeq=%d must replay only the tail, but marker one came back: %q", cursor, tail)
	}
	t.Logf("tail-only catch-up from seq %d verified (%d bytes replayed)", cursor, len(tail))

	// --- an outside structure change reaches clients via statechanged ---
	tmuxCLI(t, server, "split-window", "-t", "work:")
	if ctrl := ensure.nextControl(t, 10*time.Second); ctrl.Op != "statechanged" ||
		ctrl.Key != tmuxStructureKey("local") {
		t.Fatalf("expected statechanged for the split, got %+v", ctrl)
	}
	doc2 := fetchStructure(t, ensure)
	if len(doc2.Structure.AllPanes()) != 2 {
		t.Fatalf("mirror missed the split: %s", doc2.Structure.DebugJSON())
	}
	if doc2.Rev <= doc.Rev {
		t.Fatalf("mirror rev must be monotonic: %d then %d", doc.Rev, doc2.Rev)
	}

	// --- re-ensure is idempotent: adopt, don't duplicate ---
	ensure2 := newPlainClient(server)
	ensure2.control(Control{Op: "spawn", Kind: "tmux", SessionID: "work"})
	if ack := ensure2.nextControl(t, 10*time.Second); ack.Op != "attached" || ack.AgentID != "tmux:local" {
		t.Fatalf("re-ensure must adopt the live control client, got %+v", ack)
	}
}

// A dead pane must report exit to its viewers and vanish from the registry,
// so the id slot is free the moment tmux reuses the pane number.
func TestLiveTmuxPaneCloseReportsExit(t *testing.T) {
	server := newTmuxLiveServer(t)

	ensure := newPlainClient(server)
	ensure.control(Control{Op: "spawn", Kind: "tmux", SessionID: "work"})
	waitAttached := func(p *plainClient) Control {
		t.Helper()
		for {
			ctrl := p.nextControl(t, 30*time.Second)
			if ctrl.Op == "attached" || ctrl.Op == "attachFailed" {
				return ctrl
			}
		}
	}
	if ack := waitAttached(ensure); ack.Op != "attached" {
		t.Fatalf("ensure failed: %+v", ack)
	}
	doc := fetchStructure(t, ensure)

	// Two panes, so killing one leaves the session (and the control client)
	// alive — this test is about the PANE dying, not the server.
	tmuxCLI(t, server, "split-window", "-t", "work:")
	if ctrl := ensure.nextControl(t, 10*time.Second); ctrl.Op != "statechanged" {
		t.Fatalf("expected statechanged for the split, got %+v", ctrl)
	}
	doc = fetchStructure(t, ensure)
	if len(doc.Structure.AllPanes()) != 2 {
		t.Fatalf("expected 2 panes, got %s", doc.Structure.DebugJSON())
	}
	victim := doc.Structure.AllPanes()[0]
	agentID := fmt.Sprintf("tmux:local:%s", victim)

	viewer := newPlainClient(server)
	viewer.control(Control{Op: "attach", AgentID: agentID, Catchup: true})
	if at := waitAttached(viewer); at.Op != "attached" || !at.Running {
		t.Fatalf("pane attach failed: %+v", at)
	}

	tmuxCLI(t, server, "kill-pane", "-t", victim.String())
	deadline := time.Now().Add(15 * time.Second)
	for {
		ctrl := viewer.nextControl(t, time.Until(deadline))
		if ctrl.Op == "exit" {
			if ctrl.AgentID != agentID || ctrl.Error != "" {
				t.Fatalf("pane exit shape wrong: %+v", ctrl)
			}
			break
		}
	}
	// The registry slot is free again: a fresh attach must refuse with
	// "no pane", not hand back the corpse.
	v2 := newPlainClient(server)
	v2.control(Control{Op: "attach", AgentID: agentID, Catchup: true})
	if at := waitAttached(v2); at.Op != "attachFailed" {
		t.Fatalf("attach to a dead pane must fail cleanly, got %+v", at)
	}
}
