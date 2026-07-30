package acphost

// The tmuxpanes status op end to end against a REAL tmux (private -L
// socket, same rig as the other live tests): rows carry the pane's live
// working directory (pane_current_path) — the call-time cwd reading behind
// file preview and the directory pickers, deliberately absent from the
// structure mirror (it flaps with every cd; no revs may be minted for it).
//
// Plus the `tmuxcapture` op's two flavors: the plain visible screen the
// rule engine matches on, and the renderable whole-scrollback reply a
// client feeds a surface it binds fresh.

import (
	"encoding/base64"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLiveTmuxPanesOpCarriesPath(t *testing.T) {
	server := newTmuxLiveServer(t)

	ensure := newPlainClient(server)
	ensure.control(Control{Op: "spawn", Kind: "tmux", SessionID: "work"})
	if ctrl := ensure.nextControl(t, 30*time.Second); ctrl.Op != "statechanged" ||
		ctrl.Key != tmuxStructureKey("local") {
		t.Fatalf("expected the mirror's statechanged first, got %+v", ctrl)
	}
	if ack := ensure.nextControl(t, 5*time.Second); ack.Op != "attached" ||
		ack.AgentID != "tmux:local" || !ack.Running {
		t.Fatalf("expected session-level attached ack, got %+v", ack)
	}

	// A second window pinned to a KNOWN directory. EvalSymlinks because
	// macOS TempDir rides /var → /private/var, and pane_current_path
	// reports the kernel's resolved cwd.
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	tmuxCLI(t, server, "new-window", "-t", "work:", "-c", dir)

	ensure.control(Control{Op: "tmuxpanes", Target: "local"})
	for {
		ctrl := ensure.nextControl(t, 10*time.Second)
		if ctrl.Op != "tmuxpanesdata" {
			continue // the new-window's statechanged fan-out can interleave
		}
		if ctrl.Error != "" {
			t.Fatalf("tmuxpanes failed: %s", ctrl.Error)
		}
		if len(ctrl.Panes) < 2 {
			t.Fatalf("want ≥2 panes, got %+v", ctrl.Panes)
		}
		found := false
		for _, row := range ctrl.Panes {
			if !strings.HasPrefix(row.Path, "/") {
				t.Errorf("pane %s path not absolute: %q", row.Pane, row.Path)
			}
			if row.Path == dir {
				found = true
			}
		}
		if !found {
			t.Fatalf("no pane reports the pinned cwd %s: %+v", dir, ctrl.Panes)
		}
		return
	}
}

// TestLiveTmuxCaptureScrollbackReachesPastTheScreen pins the seam the
// fresh-bind fix rests on: `tmuxcapture` with scrollback:true must return
// what has SCROLLED OFF (capture-pane -e -J -S -), while the default flavor
// returns only the visible screen. Without this, a client re-binding a pane
// has no way to recover scrollback except replaying the pane's event log —
// which grows with session lifetime and is exactly the bug.
func TestLiveTmuxCaptureScrollbackReachesPastTheScreen(t *testing.T) {
	server := newTmuxLiveServer(t)
	c := ensureTmuxWork(t, server)

	doc := fetchStructure(t, c)
	panes := doc.Structure.AllPanes()
	if len(panes) != 1 {
		t.Fatalf("fresh session shape wrong: %s", doc.Structure.DebugJSON())
	}
	agentID := fmt.Sprintf("tmux:local:%s", panes[0])

	// Attach so the pane instance exists, then push far more than a screen
	// of output through it. The markers bracket the run: FIRST scrolls off,
	// LAST stays on screen.
	viewer := newPlainClient(server)
	viewer.control(Control{Op: "attach", AgentID: agentID, Catchup: true})
	if at := viewer.nextControl(t, 10*time.Second); at.Op != "attached" {
		t.Fatalf("pane attach failed: %+v", at)
	}
	viewer.stdioRaw([]byte("printf 'BEN''TO_SCROLL_FIRST\\n'; i=0; while [ $i -lt 400 ]; do echo \"filler line $i\"; i=$((i+1)); done; printf 'BEN''TO_SCROLL_LAST\\n'\r"))
	collectStdioUntil(t, viewer, "BENTO_SCROLL_LAST", 30*time.Second)

	capture := func(scrollback bool) string {
		t.Helper()
		c.control(Control{Op: "tmuxcapture", AgentID: agentID, Scrollback: scrollback})
		for {
			ctrl := c.nextControl(t, 10*time.Second)
			if ctrl.Op != "tmuxcapturedata" {
				continue // statechanged fan-out can interleave
			}
			if ctrl.Error != "" {
				t.Fatalf("tmuxcapture(scrollback=%v) failed: %s", scrollback, ctrl.Error)
			}
			if ctrl.Scrollback != scrollback {
				t.Fatalf("reply must echo the flavor asked for: %+v", ctrl)
			}
			raw, err := base64.StdEncoding.DecodeString(ctrl.Data)
			if err != nil {
				t.Fatalf("capture data not base64: %v", err)
			}
			return string(raw)
		}
	}

	screen := capture(false)
	if strings.Contains(screen, "BENTO_SCROLL_FIRST") {
		t.Fatalf("the visible screen cannot still hold the first marker:\n%s", screen)
	}
	if !strings.Contains(screen, "BENTO_SCROLL_LAST") {
		t.Fatalf("the visible screen must hold the last marker:\n%s", screen)
	}
	if strings.Contains(screen, "\r\n") {
		t.Errorf("the plain flavor must stay plain text (no \\r\\n rows)")
	}

	history := capture(true)
	if !strings.Contains(history, "BENTO_SCROLL_FIRST") {
		t.Fatalf("scrollback capture lost what scrolled off (%d bytes)", len(history))
	}
	if !strings.Contains(history, "BENTO_SCROLL_LAST") {
		t.Fatalf("scrollback capture lost the live screen (%d bytes)", len(history))
	}
	// Renderable: a surface fed bare LFs would staircase.
	if !strings.Contains(history, "\r\n") {
		t.Errorf("scrollback capture must carry \\r\\n row ends")
	}
	if len(history) <= len(screen) {
		t.Fatalf("scrollback (%d B) must exceed the visible screen (%d B)", len(history), len(screen))
	}
	t.Logf("visible screen %d B, whole scrollback %d B", len(screen), len(history))
}
