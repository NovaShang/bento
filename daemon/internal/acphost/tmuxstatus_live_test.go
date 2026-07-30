package acphost

// The tmuxpanes status op end to end against a REAL tmux (private -L
// socket, same rig as the other live tests): rows carry the pane's live
// working directory (pane_current_path) — the call-time cwd reading behind
// file preview and the directory pickers, deliberately absent from the
// structure mirror (it flaps with every cd; no revs may be minted for it).

import (
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
