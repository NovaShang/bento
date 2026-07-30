package tmuxhost

import (
	"strings"
	"testing"
)

// The socket-policy guard (no tmux is ever launched here): production —
// no override — MUST speak to the DEFAULT tmux server socket, the one the
// user's own terminal uses. A daemon pinned to a private -L socket once hid
// the user's entire tmux world behind an empty daemon-created twin; this
// test is the tripwire against that mistake coming back.
func TestSocketPolicyDefaultsToDefaultServer(t *testing.T) {
	t.Setenv(socketEnv, "")
	if got := resolveSocket(); got != "" {
		t.Fatalf("no override set: resolveSocket must choose the default server, got %q", got)
	}
	line := launchShellLine("/opt/homebrew/bin/tmux", resolveSocket(), "", "bento")
	if strings.Contains(line, " -L ") {
		t.Fatalf("production launch line must NOT name a -L socket: %q", line)
	}
	want := "exec '/opt/homebrew/bin/tmux' -u -CC new-session -A -s bento"
	if line != want {
		t.Fatalf("launch line drifted:\n got  %q\n want %q", line, want)
	}
}

// The override is for tests/dev only, and it is the ONLY way to move the
// daemon off the default server.
func TestSocketPolicyEnvOverride(t *testing.T) {
	t.Setenv(socketEnv, "bento-test-sock")
	if got := resolveSocket(); got != "bento-test-sock" {
		t.Fatalf("override not honored: %q", got)
	}
	line := launchShellLine("/usr/bin/tmux", resolveSocket(), "/tmp/conf with space", "work")
	if !strings.Contains(line, " -L 'bento-test-sock' ") {
		t.Fatalf("override launch line must carry the -L socket: %q", line)
	}
	if !strings.Contains(line, " -f '/tmp/conf with space' ") {
		t.Fatalf("config override must be quoted into the launch line: %q", line)
	}
	if !strings.HasSuffix(line, " -CC new-session -A -s work") {
		t.Fatalf("ensure line must keep new-session -A semantics: %q", line)
	}
}
