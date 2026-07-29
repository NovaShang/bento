package tmuxcm

// Ported from swift-tmux Tests/SwiftTmuxTests/CommandTests.swift and
// LaunchCommandTests.swift (every vector). Where the Swift tests pin exact
// strings, these pin the identical bytes.

import (
	"strings"
	"testing"
)

func paneP(n int) *PaneID {
	p := PaneID(n)
	return &p
}

func winP(n int) *WindowID {
	w := WindowID(n)
	return &w
}

func TestCommandStrings(t *testing.T) {
	braceLayout := "6b32,208x50,0,0{104x50,0,0,0,103x50,105,0,1}"
	bracketLayout := "ee54,208x50,0,0[208x25,0,0,0,208x24,0,26,1]"
	cases := []struct {
		name string
		cmd  Command
		want string
	}{
		{"splitWindowCommand",
			SplitWindow(paneP(0), true, "", SpawnCommand{}),
			"split-window -h -t %0 -c '#{pane_current_path}'"},
		{"splitWindowVertical",
			SplitWindow(paneP(2), false, "", SpawnCommand{}),
			"split-window -v -t %2 -c '#{pane_current_path}'"},
		{"newWindowPlainShell",
			NewWindow("", "", "/tmp", SpawnCommand{}),
			"new-window -c /tmp"},
		// "Path & Command…": a typed command line gets shell-quoted.
		{"newWindowShellCommandIsQuoted",
			NewWindow("", "", "/tmp", ShellSpawn("claude --resume")),
			"new-window -c /tmp 'claude --resume'"},
		// "Duplicate Current": #{pane_start_command} is already tmux-quoted
		// (a spaced arg comes back as `"sleep 300"`). It must be spliced
		// verbatim — re-quoting it would exec a program named `sleep 300`
		// and the window would vanish the instant it opened.
		{"newWindowDuplicateCurrentSplicesVerbatim",
			NewWindow("", "", "/tmp", TmuxSyntaxSpawn(`"sleep 300"`)),
			`new-window -c /tmp "sleep 300"`},
		// Tiled mode's "Split — Duplicate Current" shares the same path.
		{"splitWindowDuplicateCurrentSplicesVerbatim",
			SplitWindow(paneP(0), true, "", TmuxSyntaxSpawn(`nano "a b.txt"`)),
			`split-window -h -t %0 -c '#{pane_current_path}' nano "a b.txt"`},
		{"sendKeysLiteral",
			SendKeys(1, "hello", true),
			"send-keys -t %1 -l hello"},
		{"sendKeysWithSpacesEscaped",
			SendKeys(1, "hello world", true),
			"send-keys -t %1 -l 'hello world'"},
		{"refreshClient",
			RefreshClient(120, 40),
			"refresh-client -C 120,40"},
		// -X sends a copy-mode COMMAND (not a key), so it is independent of
		// the user's vi/emacs copy-mode bindings.
		{"copyModeCommandUsesXAndRepeat",
			CopyModeCommand(3, "scroll-up", 4),
			"send-keys -t %3 -X -N 4 scroll-up"},
		// A count of 1 (or none) omits -N.
		{"copyModeCommandNoRepeat",
			CopyModeCommand(3, "cancel", 0),
			"send-keys -t %3 -X cancel"},
		// Default is plain text (no -e): detection wants clean text.
		{"capturePaneHasFlags",
			CapturePane(3, 50, false),
			"capture-pane -t %3 -p -J -S -50"},
		// Display seeding passes escapes so SGR color/style codes survive.
		{"capturePaneWithEscapesKeepsColor",
			CapturePane(3, 50, true),
			"capture-pane -t %3 -p -J -e -S -50"},
		{"resizePaneByDirection",
			ResizePaneBy(0, "L", 4),
			"resize-pane -t %0 -L 4"},
		{"zoomPane",
			ZoomPane(5),
			"resize-pane -Z -t %5"},
		{"killSessionWithoutName",
			KillSession(""),
			"kill-session"},
		{"killSessionWithName",
			KillSession("main"),
			"kill-session -t main"},
		{"newSessionGrouped",
			NewSession("main-mobile", "main"),
			"new-session -d -t main -s main-mobile"},
		{"newSessionAtBare",
			NewSessionAt("second", ""),
			"new-session -d -s second"},
		{"newSessionAtWithCwd",
			NewSessionAt("second", "/tmp/my proj"),
			"new-session -d -s second -c '/tmp/my proj'"},
		{"renameSessionOfTarget",
			RenameSessionOf("work", "workbench"),
			"rename-session -t work workbench"},
		{"argEscapingForQuote",
			RenameWindow(0, "it's mine"),
			`rename-window -t @0 'it'\''s mine'`},
		{"killWindow",
			KillWindow(3),
			"kill-window -t @3"},
		{"breakPaneSameSession",
			BreakPane(4, "claude", ""),
			"break-pane -d -s %4 -n claude"},
		// Move-to-session: the trailing colon (empty window part) lands the
		// pane as a new window at the target's next free index.
		{"breakPaneToOtherSession",
			BreakPane(4, "claude", "work"),
			"break-pane -d -s %4 -n claude -t work:"},
		{"breakPaneToSessionWithSpaceQuoted",
			BreakPane(4, "", "my project"),
			"break-pane -d -s %4 -t 'my project:'"},
		// `^` = the session's lowest-index window (a fresh session's
		// placeholder); names with spaces quote as one target.
		{"killWindowByRawTarget",
			KillWindowTarget("my project:^"),
			"kill-window -t 'my project:^'"},
		// Drop-zone edge landing: re-split the target and dock the dragged
		// pane in the new half. No -b → after (right/bottom); no -d → the
		// dragged pane lands focused.
		{"movePaneDockRight",
			MovePane(4, 1, true, false),
			"move-pane -h -s %4 -t %1"},
		{"movePaneDockAbove",
			MovePane(4, 1, false, true),
			"move-pane -v -b -s %4 -t %1"},
		// Whole-window move: layout, panes, and name travel intact;
		// trailing colon = target's next free index.
		{"moveWindowToOtherSession",
			MoveWindow(7, "work"),
			"move-window -d -s @7 -t work:"},
		// Parallel landing: split the target session's active pane (an
		// emptied source session dies on its own).
		{"joinPaneIntoSessionCurrentWindow",
			JoinPaneToSession(4, "work"),
			"join-pane -d -s %4 -t work:"},
		{"selectLayoutByRawTarget",
			SelectLayoutTarget("work:", "tiled"),
			"select-layout -t work: tiled"},
		// A window-layout string with a horizontal split carries `{…}`.
		// tmux's command parser reads an unquoted `{` as a brace command
		// group and fails the whole command with a silent syntax error over
		// control mode — which is what dropped the saved layout once (never
		// applied on merge → even auto-layout). It must be single-quoted.
		{"selectLayoutQuotesBraceLayout",
			SelectLayout(0, braceLayout),
			"select-layout -t @0 '" + braceLayout + "'"},
		// Same brace hazard on the SAVE side: `set-option … …{…}` must be
		// quoted or the snapshot is never stored.
		{"setSessionOptionQuotesBraceLayout",
			SetSessionOption("", "@bento_orig_layout", braceLayout),
			"set-option @bento_orig_layout '" + braceLayout + "'"},
		// A vertical-only split serializes with `[…]` (not special to the
		// parser) — still quoted, since quoting is always safe.
		{"setSessionOptionQuotesBracketLayout",
			SetSessionOption("", "@bento_orig_layout", bracketLayout),
			"set-option @bento_orig_layout '" + bracketLayout + "'"},
		// A few builders the Swift suite exercises via the live tests.
		{"joinPane",
			JoinPane(3, 7),
			"join-pane -d -s %3 -t %7"},
		{"setWindowOption",
			SetWindowOption(nil, "window-size", "manual"),
			"set-option -w window-size manual"},
		{"setWindowOptionTargeted",
			SetWindowOption(winP(2), "window-size", "manual"),
			"set-option -w -t @2 window-size manual"},
		{"resizeWindow",
			ResizeWindow(winP(0), 120, 30),
			"resize-window -t @0 -x 120 -y 30"},
		{"showWindowOption",
			ShowWindowOption(winP(0), "window-size"),
			"show-options -wqv -t @0 window-size"},
		{"showSessionOption",
			ShowSessionOption("", "@bento_size_owner"),
			"show-options -qv @bento_size_owner"},
		{"displayMessageQuotesFormat",
			DisplayMessage("#{pane_current_path}", paneP(5)),
			"display-message -p -t %5 '#{pane_current_path}'"},
		{"listClients",
			ListClients(),
			"list-clients -F '#{client_name}:#{client_session}'"},
	}
	for _, c := range cases {
		if got := string(c.cmd); got != c.want {
			t.Errorf("%s:\n  got:  %s\n  want: %s", c.name, got, c.want)
		}
	}
}

func TestListPanesFormat(t *testing.T) {
	cmd := string(ListPanes("", false, false))
	if !strings.HasPrefix(cmd, "list-panes -F ") {
		t.Errorf("bad prefix: %s", cmd)
	}
	if !strings.Contains(cmd, "#{pane_id}") || !strings.Contains(cmd, "#{pane_active}") {
		t.Errorf("missing format fields: %s", cmd)
	}
}

func TestListWindowsFormat(t *testing.T) {
	cmd := string(ListWindows(""))
	if !strings.HasPrefix(cmd, "list-windows -F ") {
		t.Errorf("bad prefix: %s", cmd)
	}
	if !strings.Contains(cmd, "#{window_id}") {
		t.Errorf("missing window_id: %s", cmd)
	}
}

// --- Tmux ID parsing ---

func TestPaneIDParsing(t *testing.T) {
	id, ok := ParsePaneID("%5")
	if !ok || id != 5 || id.String() != "%5" {
		t.Fatalf("ParsePaneID(%%5) = %v, %v", id, ok)
	}
}

func TestWindowIDParsing(t *testing.T) {
	id, ok := ParseWindowID("@10")
	if !ok || id != 10 {
		t.Fatalf("ParseWindowID(@10) = %v, %v", id, ok)
	}
}

func TestSessionIDParsing(t *testing.T) {
	id, ok := ParseSessionID("$0")
	if !ok || id != 0 {
		t.Fatalf("ParseSessionID($0) = %v, %v", id, ok)
	}
}

func TestWrongSigilRejected(t *testing.T) {
	if _, ok := ParsePaneID("0"); ok {
		t.Error("bare number accepted as pane id")
	}
	if _, ok := ParsePaneID("@0"); ok {
		t.Error("window sigil accepted as pane id")
	}
	if _, ok := ParseWindowID("%0"); ok {
		t.Error("pane sigil accepted as window id")
	}
	if _, ok := ParseSessionID("@0"); ok {
		t.Error("window sigil accepted as session id")
	}
}

func TestNonNumericRejected(t *testing.T) {
	if _, ok := ParsePaneID("%abc"); ok {
		t.Error("non-numeric pane id accepted")
	}
}

// --- tmux -CC launch line (LaunchCommandTests.swift) ---
//
// Locks the working-directory quoting on the `tmux -CC` launch line.
//
// Regression 1 (quoting): new sessions defaulted to `~/code`, which got
// wrapped in single quotes (`-c '~/code'`). The remote shell never expanded
// the tilde, tmux couldn't find the literal `~/code`, and the session fell
// back to the server cwd `/`. A leading `~` must stay outside the quotes.
//
// Regression 2 (the race this moved here to fix): the directory used to be
// carried by a `tmux new-session -d …` script typed into the freshly
// spawned login shell a second before attaching. When that write beat the
// pty's readiness the line was mangled, `-c` went with it, and the agent
// started in the wrong folder — silently. It now rides the launch line.

func TestLaunchTildePathKeepsTildeUnquotedSoRemoteShellExpands(t *testing.T) {
	cmd := LaunchCommand("work", "", "~/code", "")
	if !strings.Contains(cmd, "-c ~/'code'") {
		t.Errorf("tilde not left outside quotes: %s", cmd)
	}
	if strings.Contains(cmd, "-c '~/code'") {
		t.Errorf("fully-quoted tilde lands the session in /: %s", cmd)
	}
}

func TestLaunchBareTildeStaysBare(t *testing.T) {
	cmd := LaunchCommand("work", "", "~", "")
	if !strings.Contains(cmd, "-c ~") || strings.Contains(cmd, "-c '~'") {
		t.Errorf("bare tilde mishandled: %s", cmd)
	}
}

func TestLaunchAbsolutePathIsFullyQuoted(t *testing.T) {
	cmd := LaunchCommand("work", "", "/Users/nova/code", "")
	if !strings.Contains(cmd, "-c '/Users/nova/code'") {
		t.Errorf("absolute path not quoted: %s", cmd)
	}
}

func TestLaunchPathWithSpacesAndQuotesSurvives(t *testing.T) {
	cmd := LaunchCommand("work", "", "/tmp/my proj's dir", "")
	if !strings.Contains(cmd, `-c '/tmp/my proj'\''s dir'`) {
		t.Errorf("quote escaping broke: %s", cmd)
	}
}

// The whole point of the change: a directory the user picked must appear on
// the one line that actually launches tmux.
func TestLaunchDirectoryAndProgramRideTheLaunchLine(t *testing.T) {
	cmd := LaunchCommand("work", "", "~/code/app", "claude")
	if !strings.HasPrefix(cmd, "tmux -CC new-session -A -s work ") {
		t.Errorf("bad prefix: %s", cmd)
	}
	if !strings.Contains(cmd, "-c ~/'code/app'") {
		t.Errorf("directory missing: %s", cmd)
	}
	if !strings.Contains(cmd, "'claude'") {
		t.Errorf("program missing: %s", cmd)
	}
	if !strings.HasSuffix(cmd, "\n") {
		t.Errorf("missing trailing newline: %q", cmd)
	}
}

func TestLaunchEmptyProgramAddsNothing(t *testing.T) {
	if cmd := LaunchCommand("work", "", "/tmp", ""); cmd != "tmux -CC new-session -A -s work -c '/tmp'\n" {
		t.Errorf("got %q", cmd)
	}
}

// A grouped session shares the source's windows, so seeding a directory or
// program there is meaningless — and tmux rejects the combination.
func TestLaunchGroupedSessionIgnoresSeed(t *testing.T) {
	if cmd := LaunchCommand("work-mobile", "work", "/tmp", "claude"); cmd != "tmux -CC new-session -A -s work-mobile -t work\n" {
		t.Errorf("got %q", cmd)
	}
}

func TestLaunchNoSeedMatchesPreviousBehavior(t *testing.T) {
	if cmd := LaunchCommand("work", "", "", ""); cmd != "tmux -CC new-session -A -s work\n" {
		t.Errorf("got %q", cmd)
	}
	if cmd := LaunchCommand("", "", "", ""); cmd != "tmux -CC new-session\n" {
		t.Errorf("got %q", cmd)
	}
}

// --- shell quoting for the launch line (ShellQuoteTests) ---

func TestShellQuoteArgQuotesAndEscapes(t *testing.T) {
	if got := ShellQuoteArg("plain"); got != "'plain'" {
		t.Errorf("got %q", got)
	}
	if got := ShellQuoteArg("it's"); got != `'it'\''s'` {
		t.Errorf("got %q", got)
	}
	if got := ShellQuoteArg("a b"); got != "'a b'" {
		t.Errorf("got %q", got)
	}
}

func TestShellQuotePathPreservesLeadingTildeOnly(t *testing.T) {
	if got := ShellQuotePath("~"); got != "~" {
		t.Errorf("got %q", got)
	}
	if got := ShellQuotePath("~/a b"); got != "~/'a b'" {
		t.Errorf("got %q", got)
	}
	// A tilde anywhere else is literal and must stay quoted.
	if got := ShellQuotePath("/tmp/~x"); got != "'/tmp/~x'" {
		t.Errorf("got %q", got)
	}
}
