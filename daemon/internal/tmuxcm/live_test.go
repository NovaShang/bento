package tmuxcm

// End-to-end round trip against a REAL tmux server, ported from swift-tmux
// Tests/SwiftTmuxTests/LiveTmuxRoundTripTests.swift.
//
// This is the judgement the structure work was written to pass: take an
// ordinary `N windows × M panes` session, spread every pane into its own
// window, put it back, and require the result to be byte-identical in
// #{window_layout} to what we started with.
//
// Commands are fed through `tmux source-file`, which runs them through
// tmux's own command parser — the same parser control mode uses. That makes
// this a test of the exact strings the Command builders emit, quoting
// included, not just of the planning logic. (A layout string carries braces,
// and an unquoted brace is parsed as a command group and fails silently —
// the bug the Swift lineage already shipped once.)
//
// Isolation: every run gets its own -L socket, so it can never see, resize,
// or kill anything in the user's real tmux server. The server is killed in
// a t.Cleanup.

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

type liveTmux struct {
	t      *testing.T
	bin    string
	socket string
}

// newLiveTmux skips the calling test when tmux is not installed; where it
// IS installed the live suite must actually run.
func newLiveTmux(t *testing.T) *liveTmux {
	t.Helper()
	bin, err := exec.LookPath("tmux")
	if err != nil {
		t.Skip("tmux not installed — live round-trip skipped")
	}
	lt := &liveTmux{
		t:   t,
		bin: bin,
		// A dedicated socket: this server shares nothing with the user's.
		socket: fmt.Sprintf("bento-go-test-%d-%d", os.Getpid(), time.Now().UnixNano()),
	}
	t.Cleanup(func() { lt.capture("kill-server") })
	return lt
}

// capture runs one tmux command and returns its combined output. `-L` gives
// this server its own socket; `-f /dev/null` keeps it from loading the
// user's ~/.tmux.conf. Both matter: the first means the test can never touch
// a real session, the second means the result does not depend on whatever
// the developer happens to have configured (a stray warning from that file
// was the first thing the Swift harness tripped on).
func (lt *liveTmux) capture(args ...string) string {
	cmd := exec.Command(lt.bin, append([]string{"-L", lt.socket, "-f", "/dev/null"}, args...)...)
	out, _ := cmd.CombinedOutput() // exit status intentionally ignored, like the Swift harness
	return string(out)
}

func (lt *liveTmux) run(args ...string) {
	lt.t.Helper()
	lt.capture(args...)
}

// runScript feeds command STRINGS through tmux's own parser, the way
// control mode does — this is what makes the test cover quoting.
func (lt *liveTmux) runScript(commands []Command) {
	lt.t.Helper()
	if len(commands) == 0 {
		return
	}
	lines := make([]string, len(commands))
	for i, c := range commands {
		lines[i] = string(c)
	}
	script := strings.Join(lines, "\n") + "\n"
	file := filepath.Join(lt.t.TempDir(), "bento-tmux-script.conf")
	if err := os.WriteFile(file, []byte(script), 0o644); err != nil {
		lt.t.Fatalf("write script: %v", err)
	}
	if out := lt.capture("source-file", file); strings.TrimSpace(out) != "" {
		lt.t.Fatalf("tmux rejected a command: %s\nscript:\n%s", out, script)
	}
}

// windows reuses the app's own format string and parser so the test can't
// drift from what the app actually asks tmux for.
func (lt *liveTmux) windows() []Window {
	return ParseWindowList(lt.capture(splitTmuxArgs(string(ListWindows("work")))...))
}

func (lt *liveTmux) panes() []PaneID {
	var out []PaneID
	for _, line := range strings.Split(lt.capture("list-panes", "-s", "-t", "work", "-F", "#{pane_id}"), "\n") {
		if id, ok := ParsePaneID(strings.TrimSpace(line)); ok {
			out = append(out, id)
		}
	}
	return out
}

func (lt *liveTmux) livePaneSet() map[PaneID]bool {
	m := map[PaneID]bool{}
	for _, p := range lt.panes() {
		m[p] = true
	}
	return m
}

// snapshot builds the same snapshot the app builds from a live session.
func (lt *liveTmux) snapshot() StructureSnapshot {
	var snap StructureSnapshot
	for _, w := range lt.windows() {
		var ids []PaneID
		for _, line := range strings.Split(lt.capture("list-panes", "-t", w.ID.String(), "-F", "#{pane_id}"), "\n") {
			if id, ok := ParsePaneID(strings.TrimSpace(line)); ok {
				ids = append(ids, id)
			}
		}
		snap.Windows = append(snap.Windows, SnapshotWindow{
			Index: w.Index, Name: w.Name, Layout: w.Layout, Panes: ids,
		})
	}
	return snap
}

func (lt *liveTmux) size(window WindowID) string {
	return strings.TrimSpace(lt.capture(
		"display-message", "-p", "-t", window.String(), "#{window_width}x#{window_height}"))
}

// waitForSize polls until the window reaches expected — tmux applies a
// policy change on its own event loop, so an immediate read races it.
func (lt *liveTmux) waitForSize(window WindowID, expected string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if lt.size(window) == expected {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
	return false
}

// holdsSize is the inverse assertion: the size must STAY put for a while.
// Used where the claim is that something can no longer move the window.
func (lt *liveTmux) holdsSize(window WindowID, expected string, dur time.Duration) bool {
	deadline := time.Now().Add(dur)
	for time.Now().Before(deadline) {
		if lt.size(window) != expected {
			return false
		}
		time.Sleep(50 * time.Millisecond)
	}
	return true
}

// --- Real control-mode clients ---
//
// Sizing is the one behaviour that cannot be tested without clients: every
// policy is a rule about how tmux combines them. These attach the same way
// the app does (-CC over pipes, then refresh-client -C to declare a size),
// so the test exercises tmux's real arbitration rather than a model of it.

// `tmux -CC` still calls tcgetattr, so a client needs a REAL pty — over
// plain pipes it exits with "Inappropriate ioctl for device" and never
// attaches. `script` is the portable way to hand it one.
func canAttachRealClients(t *testing.T) {
	t.Helper()
	info, err := os.Stat("/usr/bin/script")
	if err != nil || info.Mode()&0o111 == 0 {
		t.Skip("/usr/bin/script unavailable — cannot give tmux -CC a pty")
	}
}

type liveClient struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
}

func (lt *liveTmux) attachControlClient(cols, rows int) *liveClient {
	lt.t.Helper()
	cmd := exec.Command("/usr/bin/script", "-q", "/dev/null", lt.bin,
		"-L", lt.socket, "-f", "/dev/null", "-CC", "attach", "-t", "work")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		lt.t.Fatalf("stdin pipe: %v", err)
	}
	// Drain stdout or the client blocks once the pipe buffer fills
	// (os/exec copies to a non-file writer in its own goroutine).
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		lt.t.Fatalf("start control client: %v", err)
	}
	client := &liveClient{cmd: cmd, stdin: stdin}
	client.send(RefreshClient(cols, rows))
	return client
}

// send writes a command line to a control-mode client's stdin — exactly how
// the app talks to tmux.
func (c *liveClient) send(cmd Command) {
	io.WriteString(c.stdin, string(cmd)+"\n")
}

func (c *liveClient) terminate() {
	c.stdin.Close()
	if c.cmd.Process != nil {
		c.cmd.Process.Kill()
	}
	c.cmd.Wait()
}

func (lt *liveTmux) clientNames() []string {
	out := lt.capture(splitTmuxArgs(string(ListClients()))...)
	var names []string
	for _, line := range strings.Split(out, "\n") {
		// Same split the app uses: the name is a tty path, so cut at the
		// LAST colon to leave the session field behind.
		cut := strings.LastIndexByte(line, ':')
		if cut <= 0 {
			continue
		}
		names = append(names, line[:cut])
	}
	return names
}

func (lt *liveTmux) waitForClients(count int, timeout time.Duration) {
	lt.t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if len(lt.clientNames()) >= count {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	lt.t.Fatalf("only %d of %d clients attached in time", len(lt.clientNames()), count)
}

// splitTmuxArgs splits a tmux command string into argv, honoring the single
// quotes escapeArg emits (the CLI takes argv; only source-file takes a
// string).
func splitTmuxArgs(s string) []string {
	var args []string
	var current strings.Builder
	inQuote, any := false, false
	for _, ch := range s {
		if ch == '\'' {
			inQuote = !inQuote
			any = true
			continue
		}
		if ch == ' ' && !inQuote {
			if any || current.Len() > 0 {
				args = append(args, current.String())
			}
			current.Reset()
			any = false
			continue
		}
		current.WriteRune(ch)
	}
	if any || current.Len() > 0 {
		args = append(args, current.String())
	}
	return args
}

// --- The tests ---

func TestLiveMixedStructureSurvivesSpreadAndRestore(t *testing.T) {
	tmux := newLiveTmux(t)

	// 3 windows; the middle one split twice so it holds three panes.
	tmux.run("new-session", "-d", "-s", "work", "-n", "editor")
	tmux.run("new-window", "-t", "work:", "-n", "server")
	tmux.run("split-window", "-h", "-t", "work:server")
	tmux.run("split-window", "-v", "-t", "work:server")
	tmux.run("new-window", "-t", "work:", "-n", "logs")

	before := tmux.windows()
	if len(before) != 3 {
		t.Fatalf("fixture should have 3 windows, got %d", len(before))
	}
	hasSplit := false
	for _, w := range before {
		if strings.ContainsAny(w.Layout, "{[") {
			hasSplit = true
		}
	}
	if !hasSplit {
		t.Fatal("fixture should contain a real split (braces/brackets in the layout)")
	}

	// What the app records before rearranging.
	snapshot := tmux.snapshot()
	if len(snapshot.Windows) != 3 || len(snapshot.AllPanes()) != 5 {
		t.Fatalf("snapshot shape wrong: %s", snapshot.DebugJSON())
	}

	// --- spread: every pane but the first of each window breaks out ---
	var spread []Command
	for _, window := range snapshot.Windows {
		for _, pane := range window.Panes[1:] {
			spread = append(spread, BreakPane(pane, "pane", ""))
		}
	}
	tmux.runScript(spread)

	if n := len(tmux.windows()); n != 5 {
		t.Fatalf("every pane should now own a window, got %d", n)
	}

	// --- restore ---
	plan := snapshot.RestorePlan(tmux.livePaneSet())
	if len(plan) != 3 {
		t.Fatalf("want 3 restore steps, got %d", len(plan))
	}

	for _, step := range plan {
		var script []Command
		prev := step.Base
		for _, pane := range step.Join {
			script = append(script, JoinPane(pane, prev))
			prev = pane
		}
		if step.Layout != "" {
			script = append(script, SelectLayoutTarget(step.Base.String(), step.Layout))
		}
		tmux.runScript(script)
	}

	after := tmux.windows()
	if len(after) != 3 {
		t.Fatalf("expected the original 3 windows, got %d", len(after))
	}

	// The layout string is the whole claim: same geometry, same pane ids,
	// same cells. Compare as a set because window indices shift.
	var beforeLayouts, afterLayouts []string
	for _, w := range before {
		beforeLayouts = append(beforeLayouts, w.Layout)
	}
	for _, w := range after {
		afterLayouts = append(afterLayouts, w.Layout)
	}
	slices.Sort(beforeLayouts)
	slices.Sort(afterLayouts)
	t.Logf("live round trip: before layouts=%v", beforeLayouts)
	t.Logf("live round trip: after  layouts=%v", afterLayouts)
	if !slices.Equal(beforeLayouts, afterLayouts) {
		t.Fatalf("layout must round-trip exactly.\n  before: %v\n  after:  %v", beforeLayouts, afterLayouts)
	}
}

// A pane that dies while spread must not take its window's siblings with
// it, and must not make the restore apply a layout that no longer fits.
func TestLiveRestoreToleratesAPaneClosedWhileSpread(t *testing.T) {
	tmux := newLiveTmux(t)

	tmux.run("new-session", "-d", "-s", "work", "-n", "main")
	tmux.run("split-window", "-h", "-t", "work:main")
	tmux.run("split-window", "-v", "-t", "work:main")

	snapshot := tmux.snapshot()
	if got := len(snapshot.AllPanes()); got != 3 {
		t.Fatalf("want 3 panes, got %d", got)
	}

	var spread []Command
	for _, window := range snapshot.Windows {
		for _, pane := range window.Panes[1:] {
			spread = append(spread, BreakPane(pane, "pane", ""))
		}
	}
	tmux.runScript(spread)

	// Kill one of the broken-out panes.
	victim := snapshot.Windows[0].Panes[1]
	tmux.run("kill-pane", "-t", victim.String())

	live := tmux.livePaneSet()
	if live[victim] {
		t.Fatal("victim still alive")
	}

	plan := snapshot.RestorePlan(live)
	if len(plan) != 1 {
		t.Fatalf("want 1 step, got %d", len(plan))
	}
	if plan[0].Layout != "" {
		t.Fatalf("a dead pane invalidates the saved geometry, got %q", plan[0].Layout)
	}
	if len(plan[0].Join) != 1 {
		t.Fatalf("want 1 join, got %v", plan[0].Join)
	}

	for _, step := range plan {
		var script []Command
		prev := step.Base
		for _, pane := range step.Join {
			script = append(script, JoinPane(pane, prev))
			prev = pane
		}
		layout := step.Layout
		if layout == "" {
			layout = "tiled"
		}
		script = append(script, SelectLayoutTarget(step.Base.String(), layout))
		tmux.runScript(script)
	}

	if after := tmux.windows(); len(after) != 1 {
		t.Fatalf("survivors should be back in one window, got %d", len(after))
	}
	if got := len(tmux.panes()); got != 2 {
		t.Fatalf("want 2 surviving panes, got %d", got)
	}
	t.Log("live restore with a dead pane: survivors merged, saved layout correctly dropped")
}

// Breaking a pane out must NOT name the new window.
//
// Naming a window explicitly is what makes tmux turn automatic-rename off
// for it — permanently. The spread used to pass the pane's title as -n, so
// every broken-out window froze at whatever the agent's OSC title said at
// that instant, and the frozen name survived the merge back onto whichever
// window became the base. The toolbar then showed a title that matched no
// pane in that window.
func TestLiveBreakingPanesOutLeavesAutomaticRenameAlone(t *testing.T) {
	tmux := newLiveTmux(t)

	// Deliberately NOT -n: naming at creation freezes automatic-rename just
	// like renaming later does, so a named fixture would poison the very
	// thing under test. (That rule is easy to miss — the Swift test caught
	// it on its first run.)
	tmux.run("new-session", "-d", "-s", "work")
	tmux.run("split-window", "-t", "work:")
	tmux.run("split-window", "-t", "work:")
	if got := strings.TrimSpace(tmux.capture("show-options", "-gv", "automatic-rename")); got != "on" {
		t.Fatalf("automatic-rename default = %q, want on", got)
	}

	snapshot := tmux.snapshot()
	var spread []Command
	for _, window := range snapshot.Windows {
		for _, pane := range window.Panes[1:] {
			cmd := BreakPane(pane, "", "")
			if strings.Contains(string(cmd), " -n ") {
				t.Fatalf("break-pane must not name the window: %s", cmd)
			}
			spread = append(spread, cmd)
		}
	}
	tmux.runScript(spread)

	flagsOut := strings.TrimSpace(tmux.capture(
		"list-windows", "-t", "work", "-F", "#{window_index}:#{?automatic-rename,on,OFF}"))
	flags := strings.Split(flagsOut, "\n")
	if len(flags) != 3 {
		t.Fatalf("want 3 windows, got %v", flags)
	}
	for _, f := range flags {
		if !strings.HasSuffix(f, ":on") {
			t.Fatalf("every window must still auto-rename; got %v", flags)
		}
	}
}

// Pinning a session's size has to survive other clients.
//
// The old "Fit Session to This Window" pushed one refresh-client -C and
// looked like it did nothing: tmux derives a window's size from its
// clients, and under the default `window-size latest` the most recently
// used client wins, so the push was undone immediately. A pin therefore has
// to switch window-size to manual — only then does resize-window stick.
func TestLivePinningSizeHoldsOnlyUnderManualWindowSize(t *testing.T) {
	tmux := newLiveTmux(t)

	tmux.run("new-session", "-d", "-s", "work", "-x", "200", "-y", "50")
	windows := tmux.windows()
	if len(windows) == 0 {
		t.Fatal("no window")
	}
	window := windows[0]

	// Default policy: the size is derived, so a manual resize does not hold.
	if got := strings.TrimSpace(tmux.capture("show-options", "-gv", "window-size")); got != "latest" {
		t.Fatalf("window-size default = %q, want latest", got)
	}

	tmux.runScript([]Command{
		SetWindowOption(nil, "window-size", "manual"),
		ResizeWindow(&window.ID, 120, 30),
	})
	if got := tmux.size(window.ID); got != "120x30" {
		t.Fatalf("pinned size = %q, want 120x30", got)
	}

	// A different requested size must still move it while pinned —
	// resize-window is the ONE thing allowed to move a pinned window.
	tmux.runScript([]Command{ResizeWindow(&window.ID, 90, 20)})
	if got := tmux.size(window.ID); got != "90x20" {
		t.Fatalf("resize-window under manual = %q, want 90x20", got)
	}

	// Back to tracking: the option returns and clients govern again.
	tmux.runScript([]Command{SetWindowOption(nil, "window-size", "latest")})
	got := strings.TrimSpace(tmux.capture("show-options", "-wv", "-t", window.ID.String(), "window-size"))
	if got != "latest" {
		t.Fatalf("window-size after release = %q, want latest", got)
	}
}

// Two devices on one session, which is where every sizing decision actually
// gets tested. Both clients here are real control-mode clients (the same
// -CC attach the app makes) at DIFFERENT sizes, because the whole question
// is what tmux does when they disagree.
//
// The three claims the Session Size menu makes, in order:
//   - smallest → the window is the minimum over attached clients, so
//     neither device is clipped and no keystroke can flip it;
//   - manual → one recorded owner governs and the OTHER client's
//     refresh-client can no longer move the window (this is the only policy
//     where "exactly one device decides" is literally true);
//   - leaving manual hands the session back to the clients.
func TestLiveSizingPolicyDecidesWhichClientGoverns(t *testing.T) {
	canAttachRealClients(t)
	tmux := newLiveTmux(t)

	tmux.run("new-session", "-d", "-s", "work", "-x", "200", "-y", "50")
	windows := tmux.windows()
	if len(windows) == 0 {
		t.Fatal("no window")
	}
	window := windows[0]

	big := tmux.attachControlClient(140, 40)
	defer big.terminate()
	small := tmux.attachControlClient(100, 30)
	defer small.terminate()
	tmux.waitForClients(2, 5*time.Second)

	// --- smallest: the minimum, regardless of who was used last ---
	tmux.runScript([]Command{SetWindowOption(nil, "window-size", "smallest")})
	if !tmux.waitForSize(window.ID, "100x30", 5*time.Second) {
		t.Fatalf("smallest must clamp to the smaller client; got %s", tmux.size(window.ID))
	}

	// --- manual + resize-window: one owner, and only that owner ---
	tmux.runScript([]Command{
		SetWindowOption(nil, "window-size", "manual"),
		ResizeWindow(&window.ID, 140, 40),
	})
	if got := tmux.size(window.ID); got != "140x40" {
		t.Fatalf("manual resize = %q, want 140x40", got)
	}

	// The other client re-announcing itself must NOT move the window — this
	// is what makes a second device's attach stop reflowing the first.
	small.send(RefreshClient(100, 30))
	if !tmux.holdsSize(window.ID, "140x40", 600*time.Millisecond) {
		t.Fatalf("under manual no client may resize the window; got %s", tmux.size(window.ID))
	}

	// The policy is server state, so the OTHER device can read back both
	// the policy and who owns it — that read is what replaced each device
	// re-asserting its own local preference on every attach.
	tmux.runScript([]Command{
		SetSessionOption("", "@bento_size_owner", "/dev/ttys012|Shang iPad Air"),
	})
	if got := strings.TrimSpace(tmux.capture(splitTmuxArgs(string(ShowWindowOption(&window.ID, "window-size")))...)); got != "manual" {
		t.Fatalf("policy read-back = %q, want manual", got)
	}
	if got := strings.TrimSpace(tmux.capture(splitTmuxArgs(string(ShowSessionOption("", "@bento_size_owner")))...)); got != "/dev/ttys012|Shang iPad Air" {
		t.Fatalf("owner read-back = %q", got)
	}

	// --- release: the clients govern again ---
	tmux.runScript([]Command{SetWindowOption(nil, "window-size", "smallest")})
	if !tmux.waitForSize(window.ID, "100x30", 5*time.Second) {
		t.Fatalf("leaving manual must hand the size back to the clients; got %s", tmux.size(window.ID))
	}
	t.Log("live sizing arbitration: smallest → manual pin → release all verified against real -CC clients")
}

// Ownership is keyed on the tmux client name, and released when that name
// stops appearing in list-clients. Both halves have to line up or an owner
// that walked away would clamp the session forever: the name a client
// reports for itself (#{client_name}) must be the same string list-clients
// prints, and it must disappear when the client does.
func TestLiveClientNameIsTheOwnershipKeyAndDisappearsOnDetach(t *testing.T) {
	canAttachRealClients(t)
	tmux := newLiveTmux(t)

	tmux.run("new-session", "-d", "-s", "work", "-x", "200", "-y", "50")
	client := tmux.attachControlClient(120, 40)
	defer client.terminate()
	tmux.waitForClients(1, 5*time.Second)

	names := tmux.clientNames()
	if len(names) != 1 {
		t.Fatalf("want 1 client, got %v", names)
	}
	name := names[0]
	// #{client_name} — what the owning device records — is that same name.
	reported := strings.TrimSpace(tmux.capture("display-message", "-p", "-t", name, "#{client_name}"))
	if reported != name {
		t.Fatalf("ownership key must round-trip: %q vs %q", reported, name)
	}

	client.terminate()
	gone := false
	for i := 0; i < 30 && !gone; i++ {
		gone = !slices.Contains(tmux.clientNames(), name)
		if !gone {
			time.Sleep(100 * time.Millisecond)
		}
	}
	if !gone {
		t.Fatal("a detached client must leave list-clients, or its claim never releases")
	}
	t.Logf("live client identity: %s round-tripped and vanished on detach", name)
}

// The snapshot is stored in a tmux session option and read back through
// tmux's parser. This is where the brace hazard bit before.
func TestLiveSnapshotSurvivesStorageInATmuxOption(t *testing.T) {
	tmux := newLiveTmux(t)

	tmux.run("new-session", "-d", "-s", "work", "-n", "main")
	tmux.run("split-window", "-h", "-t", "work:main")

	snapshot := tmux.snapshot()
	encoded, err := snapshot.Encoded()
	if err != nil {
		t.Fatalf("Encoded: %v", err)
	}
	tmux.runScript([]Command{
		SetSessionOption("work", "@bento_structure", encoded),
	})
	read := strings.TrimSpace(tmux.capture("show-options", "-v", "-t", "work", "@bento_structure"))
	decoded, ok := DecodeStructureSnapshot(read)
	if !ok {
		t.Fatalf("stored option did not decode: %q", read)
	}
	if decoded.DebugJSON() != snapshot.DebugJSON() {
		t.Fatalf("snapshot must survive a tmux option round trip:\n  in:  %s\n  out: %s",
			snapshot.DebugJSON(), decoded.DebugJSON())
	}
	t.Logf("live option round trip: %s", snapshot.DebugJSON())
}
