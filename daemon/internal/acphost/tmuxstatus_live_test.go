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
	"bytes"
	"encoding/base64"
	"fmt"
	"os"
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

// TestLiveTmuxCaptureRestoresTheAlternateScreen is the regression this file
// exists for. `capture-pane -S -` is not a scrollback reading on a pane
// running a fullscreen TUI: tmux parks the NORMAL screen in saved_grid and
// keeps its history behind the alt screen, so `-S -` hands back the shell's
// history glued to the TUI's screen. Seeding a renderer with that flat text
// puts it on the normal screen holding history the pane does not have, and
// the wheel scrolls THAT instead of reaching the program.
//
// So the alt reply must be the program's own sequence — history, `?1049h`,
// the TUI's screen — and nothing after the switch may carry normal-screen
// history. A pane NOT on the alternate screen must be untouched: one flat
// `-S -` capture, no mode escapes at all.
func TestLiveTmuxCaptureRestoresTheAlternateScreen(t *testing.T) {
	server := newTmuxLiveServer(t)
	c := ensureTmuxWork(t, server)

	doc := fetchStructure(t, c)
	panes := doc.Structure.AllPanes()
	if len(panes) != 1 {
		t.Fatalf("fresh session shape wrong: %s", doc.Structure.DebugJSON())
	}
	pane := panes[0].String()
	agentID := fmt.Sprintf("tmux:local:%s", pane)

	capture := func() []byte {
		t.Helper()
		c.control(Control{Op: "tmuxcapture", AgentID: agentID, Scrollback: true})
		var b64 strings.Builder
		for {
			ctrl := c.nextControl(t, 10*time.Second)
			if ctrl.Op != "tmuxcapturedata" {
				continue // statechanged fan-out can interleave
			}
			if ctrl.Error != "" {
				t.Fatalf("tmuxcapture failed: %s", ctrl.Error)
			}
			b64.WriteString(ctrl.Data)
			if !ctrl.More {
				break
			}
		}
		raw, err := base64.StdEncoding.DecodeString(b64.String())
		if err != nil {
			t.Fatalf("capture data not base64: %v", err)
		}
		return raw
	}
	waitAlternate := func(want string) {
		t.Helper()
		deadline := time.Now().Add(20 * time.Second)
		for {
			got := strings.TrimSpace(tmuxCLIOut(t, server, "display-message", "-p",
				"-t", pane, "-F", "#{alternate_on}"))
			if got == want {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("pane never reached alternate_on=%s (last %q)", want, got)
			}
			time.Sleep(150 * time.Millisecond)
		}
	}

	// A screenful and more of shell history, so there IS something behind
	// the alternate screen to wrongly inject.
	viewer := newPlainClient(server)
	viewer.control(Control{Op: "attach", AgentID: agentID, Catchup: true})
	if at := viewer.nextControl(t, 10*time.Second); at.Op != "attached" {
		t.Fatalf("pane attach failed: %+v", at)
	}
	viewer.stdioRaw([]byte("i=0; while [ $i -lt 400 ]; do echo \"BEN\"\"TO_SHELL_HISTORY $i\"; i=$((i+1)); done\r"))
	collectStdioUntil(t, viewer, "BENTO_SHELL_HISTORY 399", 30*time.Second)

	// --- normal screen: unchanged, one flat capture ---
	normal := capture()
	if !bytes.Contains(normal, []byte("BENTO_SHELL_HISTORY 0")) {
		t.Fatalf("normal-screen capture lost what scrolled off (%d B)", len(normal))
	}
	if bytes.Contains(normal, []byte("\x1b[?1049")) {
		t.Error("a normal-screen pane must not be wrapped in alternate-screen escapes")
	}
	t.Logf("normal-screen capture: %d B, %d rows",
		len(normal), bytes.Count(normal, []byte("\r\n"))+1)

	// --- alternate screen ---
	long := filepath.Join(t.TempDir(), "long.txt")
	var rows strings.Builder
	for i := range 500 {
		fmt.Fprintf(&rows, "BENTO_TUI_SCREEN %d\n", i)
	}
	if err := os.WriteFile(long, []byte(rows.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	viewer.stdioRaw([]byte("less " + long + "\r"))
	waitAlternate("1")

	alt := capture()
	switchAt := bytes.Index(alt, []byte("\x1b[?1049h"))
	if switchAt < 0 {
		t.Fatalf("an alt-screen pane's seed must enter the alternate screen (%d B):\n%q",
			len(alt), alt)
	}
	before, after := alt[:switchAt], alt[switchAt:]
	// THE regression: nothing after the switch may be normal-screen
	// history. That is what the renderer would otherwise have to scroll.
	if bytes.Contains(after, []byte("BENTO_SHELL_HISTORY")) {
		t.Errorf("normal-screen history injected into the alternate screen:\n%q", after)
	}
	if !bytes.Contains(after, []byte("BENTO_TUI_SCREEN")) {
		t.Errorf("the alternate screen's own content is missing:\n%q", after)
	}
	// The faithful half: the history is still there, parked BEFORE the
	// switch, so leaving the TUI reveals it like a real terminal does.
	if !bytes.Contains(before, []byte("BENTO_SHELL_HISTORY")) {
		t.Errorf("the shell's history must survive behind the alternate screen (%d B)", len(before))
	}
	// The alt screen is exactly one screenful painted from home, so the
	// cursor restore that ends the seed names the same cell tmux does.
	if !bytes.HasSuffix(after, []byte("H")) || !bytes.Contains(after, []byte("\x1b[?1049h\x1b[H")) {
		t.Errorf("alt seed must home before painting and restore the cursor after:\n%q",
			after[max(0, len(after)-40):])
	}
	t.Logf("alt capture: %d B total, %d B of history before the switch, %d B of alt screen after",
		len(alt), len(before), len(after))

	// --- back to the normal screen ---
	viewer.stdioRaw([]byte("q"))
	waitAlternate("0")
	back := capture()
	if bytes.Contains(back, []byte("\x1b[?1049")) {
		t.Error("a pane that left the alternate screen must capture flat again")
	}
	if !bytes.Contains(back, []byte("BENTO_SHELL_HISTORY 0")) {
		t.Error("history must still be reachable after the TUI exits")
	}
}

// The `tmuxpanes` op must carry the pane's interaction mode: a client that
// binds mid-program never saw the `?1049h` or the mouse-enable, so these
// readings are the only way it learns a fullscreen TUI owns the pane.
func TestLiveTmuxPanesOpCarriesTheInteractionMode(t *testing.T) {
	server := newTmuxLiveServer(t)
	c := ensureTmuxWork(t, server)

	doc := fetchStructure(t, c)
	panes := doc.Structure.AllPanes()
	if len(panes) != 1 {
		t.Fatalf("fresh session shape wrong: %s", doc.Structure.DebugJSON())
	}
	pane := panes[0].String()

	rowFor := func() TmuxPaneStatus {
		t.Helper()
		c.control(Control{Op: "tmuxpanes", Target: "local"})
		for {
			ctrl := c.nextControl(t, 10*time.Second)
			if ctrl.Op != "tmuxpanesdata" {
				continue
			}
			if ctrl.Error != "" {
				t.Fatalf("tmuxpanes failed: %s", ctrl.Error)
			}
			for _, row := range ctrl.Panes {
				if row.Pane == pane {
					return row
				}
			}
			t.Fatalf("pane %s missing from the reply: %+v", pane, ctrl.Panes)
		}
	}

	if row := rowFor(); row.AlternateOn {
		t.Errorf("a shell pane is not on the alternate screen: %+v", row)
	}

	viewer := newPlainClient(server)
	viewer.control(Control{Op: "attach", AgentID: "tmux:local:" + pane, Catchup: true})
	if at := viewer.nextControl(t, 10*time.Second); at.Op != "attached" {
		t.Fatalf("pane attach failed: %+v", at)
	}
	long := filepath.Join(t.TempDir(), "long.txt")
	var rows strings.Builder
	for i := range 500 {
		fmt.Fprintf(&rows, "row %d\n", i)
	}
	if err := os.WriteFile(long, []byte(rows.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	viewer.stdioRaw([]byte("less " + long + "\r"))

	deadline := time.Now().Add(20 * time.Second)
	for {
		row := rowFor()
		if row.AlternateOn {
			t.Logf("alt-screen row: %+v", row)
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("tmuxpanes never reported alternate_on for a fullscreen TUI: %+v", row)
		}
		time.Sleep(200 * time.Millisecond)
	}
	viewer.stdioRaw([]byte("q"))
}
