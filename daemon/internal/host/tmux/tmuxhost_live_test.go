package tmuxhost

// Live tests against a REAL tmux server, following the design doc's route
// for the host layer (docs/tmux-host-design.md §测试路线): ensure → snapshot
// → subscribe → write → %output → outside change → structure event → pane
// kill → subscription close; plus the multi-session mirror (every session
// on the server, ensure switches, outside create/kill tracked) and the
// launch single-flight guarantee.
//
// Isolation follows internal/tmuxcm/live_test.go, via the ONE socket
// override the production code honors: BENTO_TMUX_SOCKET names a throwaway
// -L socket per run (this server can never see the user's — the user's
// REAL tmux server on the default socket is sacred and no test may touch
// it), a fixture config replaces ~/.tmux.conf, and kill-server runs in a
// cleanup. Skips when tmux is absent — where it IS installed the suite must
// actually run.

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
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

// privateSocket points BENTO_TMUX_SOCKET at a throwaway -L socket and
// registers its kill-server cleanup. EVERY live test goes through this —
// none may ever run against the default server.
func privateSocket(t *testing.T, bin string) string {
	t.Helper()
	socket := fmt.Sprintf("bento-tmuxhost-%d-%d", os.Getpid(), time.Now().UnixNano())
	t.Setenv(socketEnv, socket)
	t.Cleanup(func() { _ = exec.Command(bin, "-L", socket, "kill-server").Run() })
	return socket
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

// structEvent is one OnStructure delivery, as the tests consume it.
type structEvent struct {
	current  string
	sessions []SessionStructure
}

func (e structEvent) session(name string) *SessionStructure {
	for i := range e.sessions {
		if e.sessions[i].Name == name {
			return &e.sessions[i]
		}
	}
	return nil
}

func waitForEvent(t *testing.T, ch <-chan structEvent, what string,
	timeout time.Duration, cond func(structEvent) bool) structEvent {
	t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case ev := <-ch:
			if cond(ev) {
				return ev
			}
		case <-deadline:
			t.Fatalf("no structure event became %s in time", what)
		}
	}
}

func newLiveHost(t *testing.T, bin string) (*Host, chan structEvent) {
	t.Helper()
	structCh := make(chan structEvent, 64)
	h := New(Config{
		TmuxPath:   bin,
		ConfigFile: testConfigFile(t),
		OnStructure: func(target, current string, sessions []SessionStructure) {
			if target != LocalTarget {
				panic("wrong mirror target: " + target)
			}
			structCh <- structEvent{current: current, sessions: sessions}
		},
	})
	t.Cleanup(h.Close)
	return h, structCh
}

func TestLiveEnsureSubscribeWriteAndStructureEvents(t *testing.T) {
	bin := requireTmux(t)
	socket := privateSocket(t, bin)
	h, structCh := newLiveHost(t, bin)

	cli, err := h.EnsureLocal("work")
	if err != nil {
		t.Fatalf("ensure: %v", err)
	}

	sessions := cli.Structure()
	if len(sessions) != 1 || sessions[0].Name != "work" ||
		len(sessions[0].Snap.Windows) != 1 || len(sessions[0].Snap.AllPanes()) != 1 {
		t.Fatalf("fresh server shape wrong: %+v", sessions)
	}
	if !strings.HasPrefix(sessions[0].ID, "$") {
		t.Fatalf("session row must carry the $N id, got %q", sessions[0].ID)
	}
	t.Logf("live ensure: initial snapshot current=%s %s", cli.SessionName(), sessions[0].Snap.DebugJSON())

	// The ensure contract: the first OnStructure delivery completed BEFORE
	// EnsureLocal returned (acphost acks the ensure on that promise).
	select {
	case first := <-structCh:
		if first.current != "work" || first.session("work") == nil {
			t.Fatalf("first structure event shape wrong: %+v", first)
		}
	default:
		t.Fatal("EnsureLocal returned before the first OnStructure delivery")
	}

	// Re-ensure adopts the live client — never a second launch.
	if again, err := h.EnsureLocal("work"); err != nil || again != cli {
		t.Fatalf("re-ensure must adopt the live client (err=%v)", err)
	}

	pane := sessions[0].Snap.AllPanes()[0]
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
	waitForEvent(t, structCh, "2 panes in work", 10*time.Second, func(ev structEvent) bool {
		s := ev.session("work")
		return s != nil && len(s.Snap.AllPanes()) == 2
	})

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

// The multi-session mirror: every session on the server is listed; ensure
// of another name attach-or-creates it on the SAME control client; outside
// creates and kills are tracked (%sessions-changed → server-wide re-list);
// output streams from the session ensure switched to.
func TestLiveMultiSessionMirrorAndEnsure(t *testing.T) {
	bin := requireTmux(t)
	socket := privateSocket(t, bin)
	h, structCh := newLiveHost(t, bin)

	cli, err := h.EnsureLocal("work")
	if err != nil {
		t.Fatalf("ensure work: %v", err)
	}

	// An OUTSIDE actor creates a session: the mirror must pick it up with
	// no ensure involved.
	if out, err := exec.Command(bin, "-L", socket, "new-session", "-d", "-s", "beta").CombinedOutput(); err != nil {
		t.Fatalf("cli new-session: %v (%s)", err, out)
	}
	waitForEvent(t, structCh, "beta listed", 10*time.Second, func(ev structEvent) bool {
		return ev.session("beta") != nil && ev.current == "work"
	})

	// Ensure of beta adopts the SAME client and switches it there.
	cli2, err := h.EnsureLocal("beta")
	if err != nil {
		t.Fatalf("ensure beta: %v", err)
	}
	if cli2 != cli {
		t.Fatal("ensure of a second session must reuse the one control client per target")
	}
	if got := cli.SessionName(); got != "beta" {
		t.Fatalf("ensure must switch the client to the ensured session, current=%q", got)
	}
	// The switch itself republishes (current changed), and EnsureSession's
	// barrier completed before the ensure returned — read the client state.
	sessions := cli.Structure()
	if len(sessions) != 2 {
		t.Fatalf("mirror must list both sessions, got %+v", sessions)
	}

	// %output flows for the CURRENT session's panes: subscribe beta's pane
	// and type a marker.
	beta := sessions[0]
	if beta.Name != "beta" {
		beta = sessions[1]
	}
	if beta.Name != "beta" || len(beta.Snap.AllPanes()) != 1 {
		t.Fatalf("beta row wrong: %+v", sessions)
	}
	pane := beta.Snap.AllPanes()[0]
	outCh := make(chan []byte, 1024)
	cancel, err := cli.SubscribePane(pane, func(b []byte) { outCh <- b }, nil)
	if err != nil {
		t.Fatalf("subscribe beta pane: %v", err)
	}
	defer cancel()
	if err := cli.WritePane(pane, []byte("printf 'BEN''TO_BETA_MARK\\n'\r")); err != nil {
		t.Fatalf("write: %v", err)
	}
	waitForOutput(t, outCh, "BENTO_BETA_MARK", 15*time.Second)

	// A third session via ensure: created AND switched to.
	if _, err := h.EnsureLocal("gamma"); err != nil {
		t.Fatalf("ensure gamma: %v", err)
	}
	if got := cli.SessionName(); got != "gamma" {
		t.Fatalf("current must follow the latest ensure, got %q", got)
	}
	if got := len(cli.Structure()); got != 3 {
		t.Fatalf("mirror must list 3 sessions, got %d", got)
	}

	// An OUTSIDE kill of a NON-current session drops it from the mirror.
	if out, err := exec.Command(bin, "-L", socket, "kill-session", "-t", "beta").CombinedOutput(); err != nil {
		t.Fatalf("cli kill-session: %v (%s)", err, out)
	}
	waitForEvent(t, structCh, "beta gone", 10*time.Second, func(ev structEvent) bool {
		return ev.session("beta") == nil && len(ev.sessions) == 2 && ev.current == "gamma"
	})
	t.Log("multi-session mirror: outside create, ensure switch, output-after-switch, outside kill all verified")
}

// Launch single-flight: N racing ensures on a fresh target must produce ONE
// control client (h.mu is held across the existing-check AND the launch).
// The definitive count is tmux's own list-clients — the ps line alone lies:
// on macOS the forked tmux SERVER keeps the client's argv, so client+server
// look like "two clients" to a grep (the production incident's red herring).
func TestLiveEnsureSingleFlight(t *testing.T) {
	bin := requireTmux(t)
	socket := privateSocket(t, bin)
	h, _ := newLiveHost(t, bin)

	const racers = 8
	clients := make([]*Client, racers)
	errs := make([]error, racers)
	var wg sync.WaitGroup
	for i := 0; i < racers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			clients[i], errs[i] = h.EnsureLocal("work")
		}(i)
	}
	wg.Wait()
	for i := 0; i < racers; i++ {
		if errs[i] != nil {
			t.Fatalf("racer %d failed: %v", i, errs[i])
		}
		if clients[i] != clients[0] {
			t.Fatalf("racer %d got a different client — launch was not single-flight", i)
		}
	}
	out, err := exec.Command(bin, "-L", socket, "list-clients", "-F", "#{client_name}").CombinedOutput()
	if err != nil {
		t.Fatalf("list-clients: %v (%s)", err, out)
	}
	if lines := strings.Fields(strings.TrimSpace(string(out))); len(lines) != 1 {
		t.Fatalf("expected exactly 1 control client attached, got %d: %q", len(lines), out)
	}
	t.Logf("single-flight verified: %d racing ensures, one control client", racers)
}
