package acphost

// P1+P2 of the pty pane host (docs/hybrid-workbench-design.md §5), live
// against a real pty and /bin/sh — no tmux needed: spawn → echo arrives as
// sequenced stdio units → detach → the pane keeps printing → reattach with
// HaveSeq replays only the tail → resize → stty reports the new size →
// kill → exit control → dead-id attach refuses.
//
// Credit stall/resume is deliberately NOT duplicated here: a pty pane's
// outbound path is session.sendStdio — the same credit-window code every
// instance kind shares (ptyPane.feed and tmuxPane.feed make the identical
// call) — and that path is already pinned live by
// TestCreditWindowGovernsForwarding (ACP instances) and
// TestLiveTmuxPaneCreditStallAndResume (raw-byte panes).

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

// spawnShPane spawns an explicit /bin/sh pty pane (deterministic — no user
// shell rc involved) and returns its bound client and pane id.
func spawnShPane(t *testing.T, server *Server) (*plainClient, string) {
	t.Helper()
	c := newPlainClient(server)
	c.control(Control{Op: "spawn", Kind: "pty", Cmd: "/bin/sh",
		Env: map[string]string{"PS1": "bentosh$ "}, Cols: 80, Rows: 24})
	at := c.nextControl(t, 10*time.Second)
	if at.Op != "attached" || !at.Running || !strings.HasPrefix(at.AgentID, ptyIDPrefix) {
		t.Fatalf("pty spawn failed: %+v", at)
	}
	return c, at.AgentID
}

func TestLivePtySpawnEchoDetachAndTailCatchup(t *testing.T) {
	server, _, _ := newServer(t, false)
	viewer, id := spawnShPane(t, server)

	// The marker is split in the typed command so the shell's ECHO can never
	// satisfy the match — only printf's actual output can (the tmux tests'
	// trick).
	viewer.stdioRaw([]byte("printf 'BEN''TO_PTY_ONE\\n'\r"))
	collectStdioUntil(t, viewer, "BENTO_PTY_ONE", 15*time.Second)

	// Full catch-up: a second viewer replays the whole log from seq 1.
	v2 := newPlainClient(server)
	v2.control(Control{Op: "attach", AgentID: id, Catchup: true})
	at2 := v2.nextControl(t, 10*time.Second)
	if at2.Op != "attached" || !at2.Replay || at2.StartSeq != 1 || at2.HeadSeq == 0 {
		t.Fatalf("full catch-up not granted: %+v", at2)
	}
	collectStdioUntil(t, v2, "BENTO_PTY_ONE", 10*time.Second)
	cursor := at2.HeadSeq
	v2.control(Control{Op: "detach"})
	if d := v2.nextControl(t, 5*time.Second); d.Op != "detached" {
		t.Fatalf("v2 detach not acked: %+v", d)
	}

	// Ask the shell to print AFTER a delay, then detach everyone before it
	// fires: the process must keep running and the log keep recording with
	// nobody attached — the entire point of daemon hosting.
	viewer.stdioRaw([]byte("sleep 1; printf 'BEN''TO_PTY_TWO\\n'\r"))
	viewer.control(Control{Op: "detach"})
	if d := viewer.nextControl(t, 5*time.Second); d.Op != "detached" {
		t.Fatalf("viewer detach not acked: %+v", d)
	}
	time.Sleep(1600 * time.Millisecond) // marker two prints while NOBODY is attached

	// Tail-only reattach: HaveSeq=cursor replays marker two, never marker one.
	v3 := newPlainClient(server)
	v3.control(Control{Op: "attach", AgentID: id, Catchup: true, HaveSeq: cursor})
	at3 := v3.nextControl(t, 10*time.Second)
	if at3.Op != "attached" || !at3.Running || !at3.Replay {
		t.Fatalf("tail catch-up not granted (the process must survive detach): %+v", at3)
	}
	if at3.HeadSeq <= cursor {
		t.Fatalf("log did not grow while detached: head %d, cursor %d", at3.HeadSeq, cursor)
	}
	tail := collectStdioUntil(t, v3, "BENTO_PTY_TWO", 10*time.Second)
	if bytes.Contains(tail, []byte("BENTO_PTY_ONE")) {
		t.Fatalf("HaveSeq=%d must replay only the tail, but marker one came back: %q", cursor, tail)
	}
	t.Logf("tail-only catch-up from seq %d verified (%d bytes replayed)", cursor, len(tail))
}

func TestLivePtyResizeSIGWINCHReachesTheShell(t *testing.T) {
	server, _, _ := newServer(t, false)
	viewer, id := spawnShPane(t, server)

	// The spawn's initial size is real before any resize.
	viewer.stdioRaw([]byte("stty size\r"))
	collectStdioUntil(t, viewer, "24 80", 15*time.Second)

	// The op proper: Setsize ioctl → SIGWINCH → the tty reports 31×101.
	viewer.control(Control{Op: "resize", AgentID: id, Cols: 101, Rows: 31})
	var ack Control
	for {
		ack = viewer.nextControl(t, 10*time.Second)
		if ack.Op == "structureApplied" || ack.Op == "structureFailed" {
			break
		}
	}
	if ack.Op != "structureApplied" || ack.AgentID != id {
		t.Fatalf("resize not acked: %+v", ack)
	}
	viewer.stdioRaw([]byte("stty size\r"))
	collectStdioUntil(t, viewer, "31 101", 15*time.Second)

	// Failure shapes: non-positive geometry and an unknown pane refuse.
	for _, bad := range []Control{
		{Op: "resize", AgentID: id, Cols: 0, Rows: 24},
		{Op: "resize", AgentID: "pty:no-such-pane", Cols: 80, Rows: 24},
	} {
		viewer.control(bad)
		for {
			ctrl := viewer.nextControl(t, 10*time.Second)
			if ctrl.Op == "structureFailed" {
				break
			}
			if ctrl.Op == "structureApplied" {
				t.Fatalf("bad resize %+v must fail", bad)
			}
		}
	}
	t.Log("resize round-trip verified via stty size")
}

func TestLivePtyKillDeliversExitAndDeadIDRefuses(t *testing.T) {
	server, _, _ := newServer(t, false)
	viewer, id := spawnShPane(t, server)

	viewer.control(Control{Op: "kill", AgentID: id})
	deadline := time.Now().Add(15 * time.Second)
	for {
		ctrl := viewer.nextControl(t, time.Until(deadline))
		if ctrl.Op == "exit" {
			if ctrl.AgentID != id {
				t.Fatalf("exit names the wrong pane: %+v", ctrl)
			}
			break
		}
	}

	// The registry forgets a dead pane immediately: attach refuses cleanly…
	v2 := newPlainClient(server)
	v2.control(Control{Op: "attach", AgentID: id, Catchup: true})
	if at := v2.nextControl(t, 10*time.Second); at.Op != "attachFailed" || at.AgentID != id {
		t.Fatalf("attach to a dead pty pane must fail cleanly, got %+v", at)
	}
	// …and an id minted by a previous daemon life (fresh registry) gets the
	// same clean refusal — the daemon-restart shape.
	v3 := newPlainClient(server)
	v3.control(Control{Op: "attach", AgentID: "pty:11111111-2222-3333-4444-555555555555", Catchup: true})
	if at := v3.nextControl(t, 10*time.Second); at.Op != "attachFailed" {
		t.Fatalf("attach to an unknown pty id must fail cleanly, got %+v", at)
	}
}

// A short-lived command can exit before (or while) its spawn ack travels;
// the exit code must still reach the spawning stream — either through the
// live broadcast or through attach's exited-before-join hand-off.
func TestLivePtyCommandExitCodeReported(t *testing.T) {
	server, _, _ := newServer(t, false)
	c := newPlainClient(server)
	c.control(Control{Op: "spawn", Kind: "pty", Cmd: "/bin/sh", Args: []string{"-c", "exit 7"}})
	if at := c.nextControl(t, 10*time.Second); at.Op != "attached" {
		t.Fatalf("spawn failed: %+v", at)
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		ctrl := c.nextControl(t, time.Until(deadline))
		if ctrl.Op == "exit" {
			if ctrl.Code != 7 {
				t.Fatalf("exit code lost: %+v", ctrl)
			}
			return
		}
	}
}
