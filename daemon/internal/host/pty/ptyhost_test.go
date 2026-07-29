package ptyhost

// Live tests against a real pty and /bin/sh — nothing to install, nothing to
// skip: the package's whole contract is "bytes in, bytes out, exit code",
// and only a real pty can vouch for the SIGWINCH and login-shell edges.

import (
	"bytes"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// rig collects output under a lock and reports exit exactly once.
type rig struct {
	mu   sync.Mutex
	out  []byte
	exit chan int
	msgs chan string
}

func newRig() *rig {
	return &rig{exit: make(chan int, 1), msgs: make(chan string, 1)}
}

func (r *rig) onOutput(b []byte) {
	r.mu.Lock()
	r.out = append(r.out, b...)
	r.mu.Unlock()
}

func (r *rig) onExit(code int, msg string) {
	r.exit <- code
	r.msgs <- msg
}

func (r *rig) waitFor(t *testing.T, marker string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		r.mu.Lock()
		found := bytes.Contains(r.out, []byte(marker))
		snapshot := string(r.out)
		r.mu.Unlock()
		if found {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("marker %q not seen; output so far: %q", marker, snapshot)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func (r *rig) waitExit(t *testing.T, timeout time.Duration) int {
	t.Helper()
	select {
	case code := <-r.exit:
		return code
	case <-time.After(timeout):
		t.Fatal("no exit report")
		return 0
	}
}

func TestLiveShellEchoResizeAndKill(t *testing.T) {
	r := newRig()
	p, err := Start(Options{
		Cmd: "/bin/sh", Env: append(os.Environ(), "PS1=ptyhost$ "),
		Cols: 80, Rows: 24,
		OnOutput: r.onOutput, OnExit: r.onExit,
	})
	if err != nil {
		t.Fatal(err)
	}

	if err := p.Write([]byte("stty size\r")); err != nil {
		t.Fatal(err)
	}
	r.waitFor(t, "24 80", 15*time.Second)

	// Resize → SIGWINCH → the tty reports the new geometry.
	if err := p.Resize(100, 40); err != nil {
		t.Fatal(err)
	}
	if err := p.Write([]byte("stty size\r")); err != nil {
		t.Fatal(err)
	}
	r.waitFor(t, "40 100", 15*time.Second)

	if err := p.Resize(0, 40); err == nil {
		t.Fatal("non-positive resize must refuse")
	}

	p.Kill()
	r.waitExit(t, 15*time.Second)
}

func TestLiveExitCodeAndOutputBeforeExit(t *testing.T) {
	r := newRig()
	var atExit string
	exitSeen := make(chan struct{})
	_, err := Start(Options{
		Cmd: "/bin/sh", Args: []string{"-c", "printf 'BYEMARK\\n'; exit 5"},
		Env:      os.Environ(),
		OnOutput: r.onOutput,
		OnExit: func(code int, msg string) {
			// OnExit fires after the final OnOutput — the output must
			// already hold the marker HERE, not merely eventually.
			r.mu.Lock()
			atExit = string(r.out)
			r.mu.Unlock()
			r.onExit(code, msg)
			close(exitSeen)
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := r.waitExit(t, 15*time.Second); code != 5 {
		t.Fatalf("exit code lost: got %d, want 5", code)
	}
	<-exitSeen
	if !strings.Contains(atExit, "BYEMARK") {
		t.Fatalf("output not fully delivered before exit: %q", atExit)
	}
	if msg := <-r.msgs; !strings.Contains(msg, "exit status 5") {
		t.Fatalf("exit error text lost: %q", msg)
	}
}

func TestMissingCwdRefusedBeforeSpawn(t *testing.T) {
	_, err := Start(Options{Cmd: "/bin/sh", Cwd: "/no/such/dir/bento-ptyhost"})
	if err == nil || !strings.Contains(err.Error(), "working directory not found") {
		t.Fatalf("want the directory named as the problem, got %v", err)
	}
}

func TestResolveCommand(t *testing.T) {
	// A path containing '/' runs as-is.
	path, args, err := resolveCommand(Options{Cmd: "/bin/echo", Args: []string{"hi"}})
	if err != nil || path != "/bin/echo" || len(args) != 1 || args[0] != "hi" {
		t.Fatalf("explicit path mangled: %q %v %v", path, args, err)
	}
	// A bare name resolves against Env's PATH.
	path, _, err = resolveCommand(Options{Cmd: "sh", Env: []string{"PATH=/usr/bin:/bin"}})
	if err != nil || !strings.HasSuffix(path, "/sh") {
		t.Fatalf("PATH lookup failed: %q %v", path, err)
	}
	if _, _, err = resolveCommand(Options{Cmd: "no-such-cmd-bento", Env: []string{"PATH=/bin"}}); err == nil {
		t.Fatal("unknown bare command must refuse")
	}
	// Empty cmd = login shell: $SHELL from Env, -l first, args appended.
	path, args, err = resolveCommand(Options{Env: []string{"SHELL=/bin/sh"}, Args: []string{"-c", "true"}})
	if err != nil || path != "/bin/sh" || len(args) != 3 || args[0] != "-l" {
		t.Fatalf("login shell resolution wrong: %q %v %v", path, args, err)
	}
	// $SHELL unset still finds a real shell.
	path, args, err = resolveCommand(Options{})
	if err != nil || path == "" || len(args) == 0 || args[0] != "-l" {
		t.Fatalf("login shell fallback wrong: %q %v %v", path, args, err)
	}
	// TERM defaulting: absent gets xterm-256color, present is respected.
	if env := withDefaultTerm([]string{"A=b"}); envValue(env, "TERM") != "xterm-256color" {
		t.Fatalf("TERM not defaulted: %v", env)
	}
	if env := withDefaultTerm([]string{"TERM=dumb"}); envValue(env, "TERM") != "dumb" {
		t.Fatalf("explicit TERM overridden: %v", env)
	}
}
