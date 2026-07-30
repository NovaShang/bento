package tmuxcm

// Ported from swift-tmux Tests/SwiftTmuxTests/ParsersTests.swift (every
// vector), plus the ANSI.strip vectors (ANSITests.swift) that ParseTmuxLs
// depends on and the layout round-trip vectors (LayoutTreeTests.swift).

import (
	"slices"
	"testing"
)

func TestParsePaneGeometryNested(t *testing.T) {
	// checksum, total 181x45, then a horizontal split containing a vertical
	// split with a nested horizontal split — exercises {}, [] and leaves.
	layout := "5504,181x45,0,0{56x45,0,0,38,124x45,57,0[124x30,57,0{71x30,57,0,39,52x30,129,0,70},124x14,57,31,58]}"
	g := ParsePaneGeometry(layout)
	if len(g) != 4 {
		t.Fatalf("want 4 leaves, got %d: %v", len(g), g)
	}
	for _, want := range []PaneGeometry{
		{ID: 38, Width: 56, Height: 45, X: 0, Y: 0},
		{ID: 39, Width: 71, Height: 30, X: 57, Y: 0},
		{ID: 70, Width: 52, Height: 30, X: 129, Y: 0},
		{ID: 58, Width: 124, Height: 14, X: 57, Y: 31},
	} {
		if !slices.Contains(g, want) {
			t.Errorf("missing %+v in %v", want, g)
		}
	}
	// Split nodes (181x45, 124x45, 124x30) must NOT appear as panes.
	for _, pg := range g {
		if pg.Width == 181 {
			t.Errorf("split node leaked into pane list: %+v", pg)
		}
	}
}

func TestParsePaneGeometrySingle(t *testing.T) {
	g := ParsePaneGeometry("c1f3,80x24,0,0,0")
	want := []PaneGeometry{{ID: 0, Width: 80, Height: 24, X: 0, Y: 0}}
	if !slices.Equal(g, want) {
		t.Fatalf("got %v, want %v", g, want)
	}
}

func TestParsePaneListSingle(t *testing.T) {
	panes := ParsePaneList("%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:0:localhost")
	if len(panes) != 1 {
		t.Fatalf("want 1 pane, got %d", len(panes))
	}
	p := panes[0]
	if p.ID != 0 || p.Width != 80 || p.Height != 24 {
		t.Errorf("bad geometry: %+v", p)
	}
	if !p.IsActive || p.IsZoomed {
		t.Errorf("bad flags: %+v", p)
	}
	if p.CurrentCommand != "zsh" || p.Title != "localhost" || p.InMode {
		t.Errorf("bad command/title/mode: %+v", p)
	}
}

func TestParsePaneListMultiple(t *testing.T) {
	panes := ParsePaneList("%0:40:24:0:0:1:0:zsh:0:0:0:1:@1:0:host\n%1:40:24:40:0:0:0:vim:0:0:0:1:@1:0:host")
	if len(panes) != 2 {
		t.Fatalf("want 2 panes, got %d", len(panes))
	}
	if panes[1].X != 40 || panes[1].IsActive || panes[1].CurrentCommand != "vim" {
		t.Errorf("bad second pane: %+v", panes[1])
	}
}

func TestParsePaneListZoomed(t *testing.T) {
	// window_zoomed_flag = 1 on the active pane.
	panes := ParsePaneList("%0:120:40:0:0:1:1:vim:0:0:0:1:@1:0:host")
	if len(panes) != 1 || !panes[0].IsZoomed {
		t.Fatalf("zoom flag lost: %+v", panes)
	}
}

func TestParsePaneListAlternateScreen(t *testing.T) {
	// alternate_on = 1: a fullscreen TUI owns the screen.
	panes := ParsePaneList("%0:80:24:0:0:1:0:nvim:1:1:1:1:@1:0:host")
	if len(panes) != 1 || !panes[0].AlternateOn || panes[0].Title != "host" {
		t.Fatalf("alternate flag lost: %+v", panes)
	}
	// …and the primary screen keeps it off.
	plain := ParsePaneList("%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:0:host")
	if plain[0].AlternateOn {
		t.Fatalf("alternate flag misread as on: %+v", plain[0])
	}
}

func TestParsePaneListInMode(t *testing.T) {
	// pane_in_mode = 1: tmux has the pane in copy-mode. A client can't see
	// this from the output stream (tmux draws the mode as ordinary pane
	// content), and while it's set our own scroll gestures fight tmux's.
	panes := ParsePaneList("%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:1:host")
	if len(panes) != 1 || !panes[0].InMode || panes[0].Title != "host" {
		t.Fatalf("in-mode flag lost: %+v", panes)
	}
}

func TestParsePaneListTitleWithColons(t *testing.T) {
	// pane_title is the last field and may contain colons (e.g. a path).
	panes := ParsePaneList("%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:0:user@host: ~/code")
	if len(panes) != 1 {
		t.Fatalf("want 1 pane, got %d", len(panes))
	}
	if panes[0].CurrentCommand != "zsh" || panes[0].Title != "user@host: ~/code" {
		t.Fatalf("colons in title corrupted fields: %+v", panes[0])
	}
}

func TestParsePaneListSkipsGarbage(t *testing.T) {
	panes := ParsePaneList("not-a-pane-line\n%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:0:host")
	if len(panes) != 1 || panes[0].ID != 0 {
		t.Fatalf("garbage line not skipped: %+v", panes)
	}
}

func TestParsePanePathList(t *testing.T) {
	// Format: pane_id:pane_current_path. The path (last field) may contain
	// colons; empty or relative paths (tmux answers "" for a dead pane) and
	// garbage lines are omitted.
	paths := ParsePanePathList(
		"%0:/Users/me/code\n" +
			"%1:/tmp/odd:dir:name\n" +
			"%2:\n" +
			"%3:relative/path\n" +
			"garbage\n")
	if len(paths) != 2 {
		t.Fatalf("want 2 paths, got %d: %v", len(paths), paths)
	}
	if paths[0] != "/Users/me/code" {
		t.Errorf("plain path lost: %q", paths[0])
	}
	if paths[1] != "/tmp/odd:dir:name" {
		t.Errorf("colons in path corrupted it: %q", paths[1])
	}
}

func TestParseSessionList(t *testing.T) {
	// Format: session_id:session_name (ids survive renames; names may
	// contain spaces but never ':' — tmux refuses those).
	sessions := ParseSessionList("$0:bento\n$4:my work\n\ngarbage line\n")
	if len(sessions) != 2 {
		t.Fatalf("want 2 sessions, got %d: %+v", len(sessions), sessions)
	}
	if sessions[0].ID != 0 || sessions[0].Name != "bento" {
		t.Fatalf("bad first session: %+v", sessions[0])
	}
	if sessions[1].ID != 4 || sessions[1].Name != "my work" {
		t.Fatalf("bad second session: %+v", sessions[1])
	}
}

func TestParseWindowListSingle(t *testing.T) {
	// Format: window_id:window_index:window_active:window_layout:window_name
	// (name last).
	windows := ParseWindowList("@0:3:1:b25d,80x24,0,0,0:zsh")
	if len(windows) != 1 {
		t.Fatalf("want 1 window, got %d", len(windows))
	}
	w := windows[0]
	if w.ID != 0 || w.Index != 3 || w.Name != "zsh" || w.Layout != "b25d,80x24,0,0,0" || !w.IsActive {
		t.Fatalf("bad window: %+v", w)
	}
}

// `index:name` is what tmux itself prints in list-windows and what
// `select-window -t` targets — the UI shows the same string so a user can
// carry the label straight over to a tmux command line.
func TestIndexedNameMatchesTmuxLabel(t *testing.T) {
	windows := ParseWindowList("@0:2:1:b25d,80x24,0,0,0:claude")
	if got := windows[0].IndexedName(); got != "2:claude" {
		t.Errorf("IndexedName = %q, want %q", got, "2:claude")
	}
	// Unknown index (listing without the field) must not render a stray ":".
	legacy := Window{ID: 1, Index: -1, Name: "zsh"}
	if got := legacy.IndexedName(); got != "zsh" {
		t.Errorf("IndexedName = %q, want %q", got, "zsh")
	}
}

// A colon in the window name (e.g. a title like "host:~/dir") must NOT
// corrupt the layout field — regression for the structure restore, which
// persists window_layout. Name is last so its colons stay in the name.
func TestParseWindowListNameWithColons(t *testing.T) {
	windows := ParseWindowList("@3:7:0:6b1f,120x40,0,0{60x40,0,0,1,59x40,61,0,2}:host:~/src/app")
	if len(windows) != 1 {
		t.Fatalf("want 1 window, got %d", len(windows))
	}
	w := windows[0]
	if w.ID != 3 || w.Index != 7 || w.IsActive {
		t.Errorf("bad fixed fields: %+v", w)
	}
	if w.Layout != "6b1f,120x40,0,0{60x40,0,0,1,59x40,61,0,2}" {
		t.Errorf("layout corrupted: %q", w.Layout)
	}
	if w.Name != "host:~/src/app" {
		t.Errorf("name corrupted: %q", w.Name)
	}
}

// --- tmux ls parser (PTY noise resilience) ---

// Captured from a real iOS device run: zsh with syntax highlighting, 9
// sessions, CRLF endings, OSC title escapes around the start marker,
// zsh's "missing-newline" prompt indicator after the end marker.
func TestParseTmuxLsNineSessionsThroughOSCAndCRLF(t *testing.T) {
	startMarker := "__SPK_S_1A547748__GO__"
	endMarker := "__SPK_E_1A547748__DONE__"

	// CRLF is critical here — the Swift original treated it as a single
	// grapheme cluster, so a splitter that compares to "\n" alone would
	// yield ONE giant line. We pin that we actually split per session.
	body := "\r\n3: 1 windows (created Mon May  4 12:35:19 2026)" +
		"\r\n7: 1 windows (created Tue May 12 17:24:10 2026)" +
		"\r\nbim-claw: 1 windows (created Sun May 17 09:23:33 2026) (attached)" +
		"\r\nhelpxs: 1 windows (created Sat May  2 22:28:41 2026)" +
		"\r\nload-survey: 1 windows (created Tue Apr 28 22:40:54 2026)" +
		"\r\nnovashang_com: 1 windows (created Fri May  8 15:23:12 2026)" +
		"\r\noneline: 1 windows (created Wed May  6 22:58:05 2026)" +
		"\r\nspeakterm: 1 windows (created Thu May  7 21:48:26 2026) (attached)" +
		"\r\nvoltreality: 1 windows (created Tue Apr 28 16:52:08 2026) (attached)\r\n"

	osc := "\x1b]2;tmux ls 2> /dev/null\x07\x1b]1;printf\x07"
	promptTail := "\x1b[1m\x1b[7m%\x1b[27m\x1b[1m\x1b[0m"
	raw := osc + startMarker + body + endMarker + "\r\n" + promptTail

	got := ParseTmuxLs(raw, startMarker, endMarker)
	want := []string{
		"3", "7", "bim-claw", "helpxs", "load-survey",
		"novashang_com", "oneline", "speakterm", "voltreality",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// When the start marker is missing (e.g. printf-start failed silently) we
// still slice up to the end marker — better partial result than nothing.
func TestParseTmuxLsFallbackWhenStartMissing(t *testing.T) {
	endMarker := "__SPK_E_X__DONE__"
	raw := "prompt junk\r\nfoo: 1 windows (created x)\r\n" + endMarker + "\r\n"
	got := ParseTmuxLs(raw, "missing", endMarker)
	if !slices.Equal(got, []string{"foo"}) {
		t.Fatalf("got %v, want [foo]", got)
	}
}

// MOTD / banner lines that contain a colon but no `windows` keyword must
// NOT be reported as sessions.
func TestParseTmuxLsIgnoresMOTDLines(t *testing.T) {
	raw := "__START__\r\nWelcome: please log in\r\nfoo: 2 windows (created y)\r\n__END__\r\n"
	got := ParseTmuxLs(raw, "__START__", "__END__")
	if !slices.Equal(got, []string{"foo"}) {
		t.Fatalf("got %v, want [foo]", got)
	}
}

// The (attached) suffix must not be folded into the session name.
func TestParseTmuxLsKeepsAttachedSuffixOutOfName(t *testing.T) {
	raw := "__S__\r\nmain: 3 windows (created z) (attached)\r\n__E__\r\n"
	got := ParseTmuxLs(raw, "__S__", "__E__")
	if !slices.Equal(got, []string{"main"}) {
		t.Fatalf("got %v, want [main]", got)
	}
}

// Session names with allowed punctuation pass; weird chars get filtered out.
func TestParseTmuxLsAcceptsAllowedNameChars(t *testing.T) {
	raw := "__S__\r\n" +
		"alpha-1: 1 windows (created)\r\n" +
		"beta_2: 1 windows (created)\r\n" +
		"v1.2.3: 1 windows (created)\r\n" +
		"weird/bad: 1 windows (created)\r\n" +
		"__E__\r\n"
	got := ParseTmuxLs(raw, "__S__", "__E__")
	if !slices.Equal(got, []string{"alpha-1", "beta_2", "v1.2.3"}) {
		t.Fatalf("got %v", got)
	}
}

// Empty body returns nothing (server not running).
func TestParseTmuxLsNoSessionsYieldsEmpty(t *testing.T) {
	if got := ParseTmuxLs("__S__\r\n\r\n__E__\r\n", "__S__", "__E__"); len(got) != 0 {
		t.Fatalf("got %v, want empty", got)
	}
}

// Pre-marker shell echo with the SPLIT halves of the marker must not be
// confused for the runtime concatenated marker.
func TestParseTmuxLsShellEchoOfSplitHalvesDoesNotMatch(t *testing.T) {
	// Mirror exactly what zsh would echo for:
	//   printf '%s%s\n' '__SPK_S_T_' '_GO__'; tmux ls
	raw := "printf '%s%s\\n' '__SPK_S_T_' '_GO__'; tmux ls\r\n" +
		"__SPK_S_T__GO__\r\n" +
		"alpha: 1 windows (x)\r\n" +
		"__SPK_E_T__DONE__\r\n"
	got := ParseTmuxLs(raw, "__SPK_S_T__GO__", "__SPK_E_T__DONE__")
	// If the split-halves heuristic broke, the parser would have sliced
	// from the FIRST start match (inside the echo) and would miss "alpha"
	// or pick up garbage. We want exactly ["alpha"].
	if !slices.Equal(got, []string{"alpha"}) {
		t.Fatalf("got %v, want [alpha]", got)
	}
}

// --- ANSI stripping (ANSITests.swift) ---

func TestStripANSI(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"stripsCSI", "\x1b[31mred\x1b[0m", "red"},
		{"stripsCSIWithParameters", "\x1b[1;7;38;5;202mhi\x1b[0m", "hi"},
		{"stripsOSCTerminatedByBEL", "before\x1b]2;title here\x07after", "beforeafter"},
		{"stripsOSCTerminatedByST", "before\x1b]1;icon\x1b\\after", "beforeafter"},
		// Real shells regularly emit `ESC]2;...ESC]1;...BEL` — OSC 2 has no
		// BEL of its own, just the next ESC starting OSC 1. The first
		// stripper must NOT eat the second sequence's start byte.
		{"stripsAdjacentOSCs", "x\x1b]2;running\x1b]1;icon\x07y", "xy"},
		// Charset selection sequences are 2-byte: ESC + final.
		{"stripsBareEsc", "x\x1bBcurrent\x1b(0", "xcurrent"},
		{"idempotent", "no escapes here", "no escapes here"},
		{"handlesEmptyOSC", "a\x1b]\x07b", "ab"},
		{"preservesNewlines", "\x1b[31mline1\x1b[0m\nline2", "line1\nline2"},
	}
	for _, c := range cases {
		if got := StripANSI(c.in); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

// --- Layout tree round-trip (LayoutTreeTests.swift) ---

func TestLayoutSerializeRoundTripsIdentically(t *testing.T) {
	// Real layouts captured from tmux at various sizes.
	layouts := []string{
		// 4-pane tiled @44x90 (iPhone-ish portrait)
		"4648,44x90,0,0[44x44,0,0{21x44,0,0,0,22x44,22,0,1},44x45,0,45{21x45,0,45,2,22x45,22,45,3}]",
		// 3-pane @50x20 (small)
		"fe33,50x20,0,0{25x20,0,0,0,24x20,26,0[24x10,26,0,1,24x9,26,11,2]}",
		// 2-pane horizontal @200x50 (desktop) — real capture
		"cf3a,200x50,0,0{100x50,0,0,0,99x50,101,0,1}",
	}
	for _, original := range layouts {
		tree, ok := ParseLayout(original)
		if !ok {
			t.Errorf("ParseLayout failed for %q", original)
			continue
		}
		if round := SerializeLayout(tree); round != original {
			t.Errorf("round-trip mismatch:\n  in:  %s\n  out: %s", original, round)
		}
	}
}

// LeafOrder must walk depth-first — the order select-layout assigns panes.
func TestLayoutLeafOrderDepthFirst(t *testing.T) {
	tree, ok := ParseLayout("fe33,50x20,0,0{25x20,0,0,0,24x20,26,0[24x10,26,0,1,24x9,26,11,2]}")
	if !ok {
		t.Fatal("parse failed")
	}
	if got := LeafOrder(tree); !slices.Equal(got, []int{0, 1, 2}) {
		t.Fatalf("leaf order = %v, want [0 1 2]", got)
	}
}
