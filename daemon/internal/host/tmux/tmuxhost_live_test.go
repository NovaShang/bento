package tmuxhost

// Live tests against a REAL tmux server, following the design doc's route
// for the host layer (docs/tmux-host-design.md §测试路线): ensure → snapshot
// → subscribe → write → %output → outside change → structure event → pane
// kill → subscription close.
//
// Isolation follows internal/tmuxcm/live_test.go: a throwaway -L socket per
// run (this server can never see the user's), a fixture config instead of
// ~/.tmux.conf, and kill-server in a cleanup. Skips when tmux is absent —
// where it IS installed the suite must actually run.

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/novashang/bento/daemon/internal/tmuxcm"
)

// requireTmux skips when tmux is not installed and returns its path.
func requireTmux(t *testing.T) string {
	t.Helper()
	bin, err := exec.LookPath("tmux")
	if err != nil {
		t.Skip("tmux not installed — tmuxhost live test skipped")
	}
	return bin
}

// testConfigFile pins default-shell to /bin/sh: the pane must echo typed
// commands plainly, not through whatever line editor the developer's login
// shell runs (a zsh redraw would garble marker matching, and a slow rc file
// would eat the timeout).
func testConfigFile(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "tmux.conf")
	if err := os.WriteFile(path, []byte("set -g default-shell /bin/sh\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func waitForOutput(t *testing.T, ch <-chan []byte, marker string, timeout time.Duration) {
	t.Helper()
	var seen []byte
	deadline := time.After(timeout)
	for {
		select {
		case b := <-ch:
			seen = append(seen, b...)
			if bytes.Contains(seen, []byte(marker)) {
				return
			}
		case <-deadline:
			t.Fatalf("marker %q not seen in pane output; got %q", marker, seen)
		}
	}
}

func waitForPaneCount(t *testing.T, ch <-chan tmuxcm.StructureSnapshot, want int, timeout time.Duration) {
	t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case snap := <-ch:
			if len(snap.AllPanes()) == want {
				return
			}
		case <-deadline:
			t.Fatalf("no structure event reached %d panes in time", want)
		}
	}
}

func TestLiveEnsureSubscribeWriteAndStructureEvents(t *testing.T) {
	bin := requireTmux(t)
	socket := fmt.Sprintf("bento-tmuxhost-%d-%d", os.Getpid(), time.Now().UnixNano())
	t.Cleanup(func() { _ = exec.Command(bin, "-L", socket, "kill-server").Run() })

	structCh := make(chan tmuxcm.StructureSnapshot, 16)
	h := New(Config{
		TmuxPath:   bin,
		SocketName: socket,
		ConfigFile: testConfigFile(t),
		OnStructure: func(target, session string, snap tmuxcm.StructureSnapshot) {
			if target != LocalTarget || session != "work" {
				panic(fmt.Sprintf("wrong mirror identity: %s/%s", target, session))
			}
			structCh <- snap
		},
	})
	defer h.Close()

	cli, err := h.EnsureLocal("work")
	if err != nil {
		t.Fatalf("ensure: %v", err)
	}

	snap := cli.Structure()
	if len(snap.Windows) != 1 || len(snap.AllPanes()) != 1 {
		t.Fatalf("fresh session shape wrong: %s", snap.DebugJSON())
	}
	t.Logf("live ensure: initial snapshot %s", snap.DebugJSON())

	// The ensure contract: the first OnStructure delivery completed BEFORE
	// EnsureLocal returned (acphost acks the ensure on that promise).
	select {
	case first := <-structCh:
		if len(first.AllPanes()) != 1 {
			t.Fatalf("first structure event shape wrong: %s", first.DebugJSON())
		}
	default:
		t.Fatal("EnsureLocal returned before the first OnStructure delivery")
	}

	// Re-ensure adopts; a different session name refuses loudly.
	if again, err := h.EnsureLocal("work"); err != nil || again != cli {
		t.Fatalf("re-ensure must adopt the live client (err=%v)", err)
	}
	if _, err := h.EnsureLocal("other"); err == nil {
		t.Fatal("a second session on one target must refuse (multi-session is a later step)")
	}

	pane := snap.AllPanes()[0]
	outCh := make(chan []byte, 1024)
	closedCh := make(chan error, 1)
	cancel, err := cli.SubscribePane(pane,
		func(b []byte) { outCh <- b },
		func(err error) { closedCh <- err })
	if err != nil {
		t.Fatalf("subscribe: %v", err)
	}
	defer cancel()
	if _, err := cli.SubscribePane(pane, nil, nil); err == nil {
		t.Fatal("a second subscription on one pane must refuse (acphost multiplexes above)")
	}

	// Write into the pane. The marker is split in the command so the shell
	// ECHO can never satisfy the match — only printf's actual output can.
	if err := cli.WritePane(pane, []byte("printf 'BEN''TO_HOST_MARK\\n'\r")); err != nil {
		t.Fatalf("write: %v", err)
	}
	waitForOutput(t, outCh, "BENTO_HOST_MARK", 15*time.Second)

	// An OUTSIDE actor (a user in a terminal) splits the window: the change
	// must surface as a structure event, driven by %layout-change alone.
	if out, err := exec.Command(bin, "-L", socket, "split-window", "-t", "work:").CombinedOutput(); err != nil {
		t.Fatalf("cli split: %v (%s)", err, out)
	}
	waitForPaneCount(t, structCh, 2, 10*time.Second)

	// Killing the subscribed pane ends its subscription with a nil reason
	// (the pane closed; the control client lives on).
	if out, err := exec.Command(bin, "-L", socket, "kill-pane", "-t", pane.String()).CombinedOutput(); err != nil {
		t.Fatalf("cli kill-pane: %v (%s)", err, out)
	}
	select {
	case err := <-closedCh:
		if err != nil {
			t.Fatalf("pane close must report nil (pane gone, client alive), got %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("pane subscription did not observe the kill")
	}
	t.Log("live host route: ensure → subscribe → write → output → split event → pane-close all verified")
}
