package tmuxcm

// Ported from swift-tmux Tests/SwiftTmuxTests/ControlModeTests.swift. The
// Swift suite drove an async actor-ish object (continuations, sleeps,
// timeout tasks); this port drives the synchronous state machine directly,
// so every "await + sleep" pair becomes a plain feed-then-assert. The two
// Swift tests that existed only to pin timer behavior (send timeout firing,
// awaitControlMode timing out) have no synchronous analogue — the host
// layer owns timeouts now — and are noted rather than ported.

import (
	"bytes"
	"slices"
	"strings"
	"testing"
)

// collector gathers parsed notifications (Swift: NotificationCollector,
// minus the lock — everything here is synchronous).
type collector struct {
	notifications []Notification
}

func (c *collector) collect(n Notification) { c.notifications = append(c.notifications, n) }

func (c *collector) lastOutput() ([]byte, bool) {
	for i := len(c.notifications) - 1; i >= 0; i-- {
		if o, ok := c.notifications[i].(Output); ok {
			return o.Data, true
		}
	}
	return nil, false
}

func (c *collector) outputPaneIDs() []PaneID {
	var out []PaneID
	for _, n := range c.notifications {
		if o, ok := n.(Output); ok {
			out = append(out, o.Pane)
		}
	}
	return out
}

func (c *collector) outputTexts() []string {
	var out []string
	for _, n := range c.notifications {
		if o, ok := n.(Output); ok {
			out = append(out, string(o.Data))
		}
	}
	return out
}

func (c *collector) last() Notification {
	if len(c.notifications) == 0 {
		return nil
	}
	return c.notifications[len(c.notifications)-1]
}

func makeCM() (*ControlMode, *collector) {
	c := &collector{}
	return &ControlMode{OnNotification: c.collect}, c
}

// makeAttachedCM is a ControlMode whose connection greeting (the unsolicited
// first %begin/%end block of a -CC attach) has already been consumed — i.e.
// a live session.
func makeAttachedCM() (*ControlMode, *collector) {
	cm, c := makeCM()
	cm.Feed([]byte("%begin 0 0 0\n%end 0 0 0\n"))
	return cm, c
}

func feedString(cm *ControlMode, s string) { cm.Feed([]byte(s)) }

func expectLastOutput(t *testing.T, c *collector, want string) {
	t.Helper()
	got, ok := c.lastOutput()
	if !ok {
		t.Fatalf("no output notification; want %q", want)
	}
	if !bytes.Equal(got, []byte(want)) {
		t.Fatalf("output = %q, want %q", got, want)
	}
}

// --- %output unescaping ---

func TestOutputUnescapeVectors(t *testing.T) {
	cases := []struct {
		name string
		feed string
		want string
	}{
		{"plainASCII", "%output %0 hello world\n", "hello world"},
		{"octalNewline", `%output %0 line1\012line2` + "\n", "line1\nline2"},
		{"octalTab", `%output %0 col1\011col2` + "\n", "col1\tcol2"},
		{"octalCarriageReturn", `%output %0 text\015` + "\n", "text\r"},
		{"octalBackslash", `%output %0 path\134file` + "\n", `path\file`},
		{"octalEscape", `%output %0 \033[31mred\033[0m` + "\n", "\x1b[31mred\x1b[0m"},
		{"multipleOctalsInRow", `%output %0 \033[2J\033[H` + "\n", "\x1b[2J\x1b[H"},
		{"emptyOutput", "%output %0 \n", ""},
	}
	for _, c := range cases {
		cm, col := makeCM()
		feedString(cm, c.feed)
		got, ok := col.lastOutput()
		if !ok {
			t.Errorf("%s: no output notification", c.name)
			continue
		}
		if string(got) != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

func TestOutputUTF8BoxDrawingPreserved(t *testing.T) {
	cm, c := makeCM()
	raw := []byte("%output %0 ")
	raw = append(raw, 0xE2, 0x95, 0xAD) // ╭
	raw = append(raw, 0xE2, 0x94, 0x80) // ─
	raw = append(raw, 0xE2, 0x95, 0xAE) // ╮
	raw = append(raw, '\n')
	cm.Feed(raw)
	got, ok := c.lastOutput()
	if !ok || !bytes.Equal(got, []byte{0xE2, 0x95, 0xAD, 0xE2, 0x94, 0x80, 0xE2, 0x95, 0xAE}) {
		t.Fatalf("box drawing mangled: %v (ok=%v)", got, ok)
	}
}

func TestOutputUTF8ChinesePreserved(t *testing.T) {
	cm, c := makeCM()
	raw := []byte("%output %0 ")
	raw = append(raw, 0xE4, 0xBD, 0xA0, 0xE5, 0xA5, 0xBD) // 你好
	raw = append(raw, '\n')
	cm.Feed(raw)
	expectLastOutput(t, c, "你好")
}

func TestOutputPaneIDRouting(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%output %0 a\n%output %5 b\n%output %12 c\n")
	if got := c.outputPaneIDs(); !slices.Equal(got, []PaneID{0, 5, 12}) {
		t.Fatalf("pane routing = %v", got)
	}
}

// --- Notification parsing ---

func TestSessionChangedNotification(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%session-changed $0 mysession\n")
	n, ok := c.last().(SessionChanged)
	if !ok || n.Session != 0 || n.Name != "mysession" {
		t.Fatalf("got %#v", c.last())
	}
}

func TestLayoutChangeNotification(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%layout-change @0 b25d,80x24,0,0,0\n")
	n, ok := c.last().(LayoutChange)
	if !ok || n.Window != 0 || n.Layout != "b25d,80x24,0,0,0" {
		t.Fatalf("got %#v", c.last())
	}
}

func TestLayoutChangeExtraFields(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%layout-change @0 b99d,54x54,0,0,0 b99d,54x54,0,0,0 *\n")
	n, ok := c.last().(LayoutChange)
	if !ok || n.Window != 0 || n.Layout != "b99d,54x54,0,0,0" {
		t.Fatalf("got %#v", c.last())
	}
}

func TestWindowAddNotification(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%window-add @5\n")
	n, ok := c.last().(WindowAdd)
	if !ok || n.Window != 5 {
		t.Fatalf("got %#v", c.last())
	}
}

func TestWindowCloseNotification(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%window-close @3\n")
	n, ok := c.last().(WindowClose)
	if !ok || n.Window != 3 {
		t.Fatalf("got %#v", c.last())
	}
}

func TestExitNoReason(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%exit\n")
	n, ok := c.last().(Exit)
	if !ok || n.Reason != "" {
		t.Fatalf("got %#v", c.last())
	}
}

func TestExitWithReason(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%exit client detached\n")
	n, ok := c.last().(Exit)
	if !ok || n.Reason != "client detached" {
		t.Fatalf("got %#v", c.last())
	}
}

func TestIgnoredNotificationsNoCrash(t *testing.T) {
	cm, _ := makeCM()
	feedString(cm, "%sessions-changed\n")
	feedString(cm, "%unlinked-window-add @1\n")
	feedString(cm, "%unlinked-window-close @1\n")
	feedString(cm, "%window-pane-changed @0 %1\n")
	feedString(cm, "%client-session-changed $1 main\n")
	// Reached here = no crash.
}

func TestClientDetachedNotification(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%client-detached /dev/ttys012\n")
	n, ok := c.last().(ClientDetached)
	if !ok || n.Client != "/dev/ttys012" {
		t.Fatalf("got %#v", c.last())
	}
}

func TestDCSStrippedBeforeNotification(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "\x1bP1000p%session-changed $0 test\n")
	n, ok := c.last().(SessionChanged)
	if !ok || n.Name != "test" {
		t.Fatalf("got %#v", c.last())
	}
}

// --- Response queue ---

func TestFireAndForgetDoesNotStealReply(t *testing.T) {
	cm, _ := makeAttachedCM()
	var sent []string
	cm.Write = func(line string) { sent = append(sent, line) }

	cm.SendFireAndForget(SelectPane(0))

	var got *CommandResponse
	cm.Send(ListPanes("", false, false), func(r CommandResponse) { got = &r })

	// Two responses arrive. First is consumed by the fire-and-forget
	// counter; second matches the awaited reply.
	feedString(cm, "%begin 1 100 1\n%end 1 100 1\n")
	feedString(cm, "%begin 1 101 1\npane data\n%end 1 101 1\n")

	if got == nil || got.IsError || got.Output != "pane data" {
		t.Fatalf("reply = %+v", got)
	}
	if len(sent) != 2 {
		t.Fatalf("expected both commands written, got %v", sent)
	}
}

func TestErrorResponseDetected(t *testing.T) {
	cm, _ := makeAttachedCM()
	var got *CommandResponse
	cm.Send(ListPanes("", false, false), func(r CommandResponse) { got = &r })
	feedString(cm, "%begin 1 100 1\nbad command\n%error 1 100 1\n")
	if got == nil || !got.IsError || got.Output != "bad command" {
		t.Fatalf("reply = %+v", got)
	}
}

func TestMultiLineResponse(t *testing.T) {
	cm, _ := makeAttachedCM()
	var got *CommandResponse
	cm.Send(ListPanes("", false, false), func(r CommandResponse) { got = &r })
	feedString(cm, "%begin 1 100 1\nline1\nline2\nline3\n%end 1 100 1\n")
	if got == nil || got.Output != "line1\nline2\nline3" {
		t.Fatalf("reply = %+v", got)
	}
}

// The window-switch corruption: tmux interleaves an out-of-band notification
// (e.g. the %layout-change from select-window's repaint) BETWEEN a command's
// %begin and %end. It must be dispatched, not folded into the command output
// — otherwise capture-pane seeds the pane's surface with raw protocol text
// and list-panes/list-windows drop rows.
func TestInterleavedNotificationDoesNotCorruptBlock(t *testing.T) {
	cm, c := makeAttachedCM()
	var got *CommandResponse
	cm.Send(ListPanes("", false, false), func(r CommandResponse) { got = &r })
	feedString(cm, "%begin 1 100 1\nline1\n%layout-change @0 b25d,80x24,0,0,0\nline2\n%end 1 100 1\n")
	if got == nil || got.Output != "line1\nline2" {
		t.Fatalf("notification folded into output: %+v", got)
	}
	found := false
	for _, n := range c.notifications {
		if _, ok := n.(LayoutChange); ok {
			found = true
		}
	}
	if !found {
		t.Fatal("layout-change notification swallowed")
	}
}

// A captured line that merely CONTAINS a control marker as a substring
// (e.g. a shell printing "50%end of run") must stay verbatim in the
// response — only a line that STARTS with `%end `/`%error ` closes the
// block. Guards against the old leading-junk realignment (which used a
// substring search) truncating captured content.
func TestSubstringMarkerInBlockStaysContent(t *testing.T) {
	cm, _ := makeAttachedCM()
	var got *CommandResponse
	cm.Send(ListPanes("", false, false), func(r CommandResponse) { got = &r })
	feedString(cm, "%begin 1 100 1\ndone 50%end of run\n%end 1 100 1\n")
	if got == nil || got.Output != "done 50%end of run" {
		t.Fatalf("content truncated: %+v", got)
	}
}

// BUG-007: a notification interleaved in a block can arrive behind a stray
// escape/DCS junk prefix (transport framing), so the strict prefix checks
// miss it and it would be folded into the response as raw protocol text.
// Anchored realignment (non-printable prefix only) must still route it out.
func TestJunkPrefixedNotificationInBlockRoutedOut(t *testing.T) {
	cm, c := makeAttachedCM()
	var got *CommandResponse
	cm.Send(ListPanes("", false, false), func(r CommandResponse) { got = &r })
	feedString(cm, "%begin 1 100 1\nline1\n\x1bPjunk%layout-change @0 b25d,80x24,0,0,0\nline2\n%end 1 100 1\n")
	if got == nil || got.Output != "line1\nline2" {
		t.Fatalf("chatter folded in: %+v", got)
	}
	found := false
	for _, n := range c.notifications {
		if _, ok := n.(LayoutChange); ok {
			found = true
		}
	}
	if !found {
		t.Fatal("junk-prefixed layout-change dropped")
	}
}

// BUG-007: a %output interleaved in a block behind an escape junk prefix
// must not paint raw protocol into the captured response.
func TestJunkPrefixedOutputInBlockNotFolded(t *testing.T) {
	cm, _ := makeAttachedCM()
	var got *CommandResponse
	cm.Send(ListPanes("", false, false), func(r CommandResponse) { got = &r })
	feedString(cm, "%begin 1 100 1\nrow1\n\x1b[K%output %0 hello\nrow2\n%end 1 100 1\n")
	if got == nil || got.Output != "row1\nrow2" {
		t.Fatalf("output chatter folded in: %+v", got)
	}
}

// BUG-007 guard: a captured line that STARTS with an escape colour code but
// carries no protocol marker must stay verbatim — the non-printable-prefix
// anchor must route out chatter without eating real escaped content.
func TestEscapePrefixedContentWithoutMarkerStaysContent(t *testing.T) {
	cm, _ := makeAttachedCM()
	var got *CommandResponse
	cm.Send(ListPanes("", false, false), func(r CommandResponse) { got = &r })
	feedString(cm, "%begin 1 100 1\n\x1b[32mgreen text\x1b[0m\n%end 1 100 1\n")
	if got == nil || got.Output != "\x1b[32mgreen text\x1b[0m" {
		t.Fatalf("escaped content eaten: %+v", got)
	}
}

// --- Input hex encoding ---

// SendKeysHex must hex-encode every byte for `send-keys -H`: lowercase, two
// digits, single-space separated — including 0x00 and 0xff.
func TestSendKeysHexEncodesBytes(t *testing.T) {
	cm := &ControlMode{}
	var sent []string
	cm.Write = func(line string) { sent = append(sent, line) }
	cm.SendKeysHex(0, []byte{0x00, 0x1b, 0xff})
	if !slices.Equal(sent, []string{"send-keys -t %0 -H 00 1b ff\n"}) {
		t.Fatalf("sent = %v", sent)
	}
}

// --- Chunked input ---

func TestSplitAcrossChunks(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%output %0 hel")
	if _, ok := c.lastOutput(); ok {
		t.Fatal("no newline yet — nothing should be emitted")
	}
	feedString(cm, "lo\n")
	expectLastOutput(t, c, "hello")
}

func TestMultipleLinesInOneChunk(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%output %0 first\n%output %0 second\n%output %1 third\n")
	if got := c.outputTexts(); !slices.Equal(got, []string{"first", "second", "third"}) {
		t.Fatalf("got %v", got)
	}
}

func TestCRLFHandled(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%output %0 test\r\n")
	expectLastOutput(t, c, "test")
}

// --- Logging hook ---

func TestLogfReceivesCommands(t *testing.T) {
	cm := &ControlMode{}
	var captured []string
	cm.Logf = func(format string, args ...any) {
		captured = append(captured, format+" "+strings.TrimSpace(strings.Join(anyToStrings(args), " ")))
	}
	cm.SendFireAndForget(SelectPane(2))
	found := false
	for _, line := range captured {
		if strings.Contains(line, "select-pane -t %2") {
			found = true
		}
	}
	if !found {
		t.Fatalf("log hook missed the send: %v", captured)
	}
}

func anyToStrings(args []any) []string {
	out := make([]string, len(args))
	for i, a := range args {
		if s, ok := a.(string); ok {
			out[i] = s
		}
	}
	return out
}

// --- Reconnect state reset ---

// %output takes the raw fast path in handleLine and is immune to a stuck
// block — pin that down so the zombie analysis below stays honest.
func TestOutputBypassesStuckBlock(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%begin 100 5 1\n") // truncated block
	feedString(cm, "%output %0 still-flows\n")
	if got := c.outputTexts(); !slices.Equal(got, []string{"still-flows"}) {
		t.Fatalf("got %v", got)
	}
}

// The "zombie pane" bug, mechanism 1 — hardened at the parser: a response
// block truncated by a connection drop (%begin seen, %end lost) leaves the
// parser in block-collection mode. Out-of-band notifications are routed
// PAST the stuck block instead of being swallowed as block content. Reset
// is still required to clear the stuck block itself and realign the FIFO
// (mechanism 2, below).
func TestNotificationsSurviveTruncatedBlock(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%begin 100 5 1\n") // response starts…
	// …connection dies; %end never arrives. A notification still gets out:
	feedString(cm, "%layout-change @1 dead,80x24,0,0,1\n")
	if len(c.notifications) != 1 {
		t.Fatalf("notification swallowed by stuck block: %v", c.notifications)
	}
}

// The "zombie pane" bug, mechanism 2: replies queued by the dead connection
// consume the new connection's response blocks FIFO, starving the
// post-reconnect commands. (greetingConsumed is still true from the old
// connection, so the new greeting is treated as an ordinary response — part
// of the bug.) In the synchronous port "starved" means the fresh caller's
// reply simply never fires.
func TestOrphanedRepliesStarveNewSendsWithoutReset(t *testing.T) {
	cm, _ := makeAttachedCM()
	var o1, o2, fresh *CommandResponse
	cm.Send(ListPanes("", false, false), func(r CommandResponse) { o1 = &r })
	cm.Send(ListWindows(""), func(r CommandResponse) { o2 = &r })
	// Reconnect WITHOUT Reset. The reattach flow sends list-panes; the new
	// connection delivers its greeting + that one real response.
	cm.Send(ListPanes("", false, false), func(r CommandResponse) { fresh = &r })
	feedString(cm, "%begin 1 0 0\n%end 1 0 0\n")               // new greeting
	feedString(cm, "%begin 2 1 1\n%0 pane data\n%end 2 1 1\n") // real response
	if o1 == nil || o1.Output != "" {
		t.Fatalf("orphan1 should have stolen the (empty) greeting: %+v", o1)
	}
	if o2 == nil || o2.Output != "%0 pane data" {
		t.Fatalf("orphan2 should have stolen the real response: %+v", o2)
	}
	if fresh != nil {
		t.Fatalf("the live caller should have starved, got %+v", fresh)
	}
}

func TestResetFailsPendingReplies(t *testing.T) {
	cm, _ := makeCM()
	var got *CommandResponse
	cm.Send(ListPanes("", false, false), func(r CommandResponse) { got = &r })
	cm.Reset()
	if got == nil || !got.IsError || got.Output != "connection reset" {
		t.Fatalf("reply = %+v", got)
	}
}

// A partial line left in the byte buffer by the dead connection must not
// corrupt the first line of the new connection's stream.
func TestResetDropsPartialLineBuffer(t *testing.T) {
	cm, c := makeCM()
	feedString(cm, "%output %0 trunca") // no newline — stuck partial
	cm.Reset()
	feedString(cm, "%output %1 fresh\n")
	if got := c.outputTexts(); !slices.Equal(got, []string{"fresh"}) {
		t.Fatalf("got %v", got)
	}
}

func TestResponseAfterResetMatchesNewSend(t *testing.T) {
	cm, _ := makeAttachedCM()
	var orphan, fresh *CommandResponse
	cm.Send(ListPanes("", false, false), func(r CommandResponse) { orphan = &r }) // never answered
	cm.Reset()
	if orphan == nil || !orphan.IsError {
		t.Fatalf("orphan not released by reset: %+v", orphan)
	}
	cm.Send(ListWindows(""), func(r CommandResponse) { fresh = &r })
	feedString(cm, "%begin 100 8 0\n%end 100 8 0\n")        // new connection's greeting
	feedString(cm, "%begin 200 9 1\nwin-1\n%end 200 9 1\n") // real response
	if fresh == nil || fresh.IsError || fresh.Output != "win-1" {
		t.Fatalf("fresh reply = %+v", fresh)
	}
}

// THE churn regression from the Swift lineage: a send queued while the
// greeting block is still in flight must not have its reply stolen by the
// greeting's %end. (Resolving "ready" on %begin instead of block completion
// caused every response to shift by one: all commands timed out, the
// watchdog forced a reconnect, and the cycle repeated forever.)
func TestGreetingBlockDoesNotStealSendQueuedMidBlock(t *testing.T) {
	cm, _ := makeCM()
	feedString(cm, "%begin 100 1 0\n") // greeting starts
	var got *CommandResponse
	cm.Send(ListPanes("", false, false), func(r CommandResponse) { got = &r })
	feedString(cm, "%end 100 1 0\n") // greeting completes
	feedString(cm, "%begin 101 2 1\npane\n%end 101 2 1\n")
	if got == nil || got.IsError || got.Output != "pane" {
		t.Fatalf("reply = %+v", got)
	}
}

// --- Control-mode greeting (Swift: awaitControlMode; here Ready/OnReady) ---

func TestReadyFiresWhenGreetingArrives(t *testing.T) {
	cm, _ := makeCM()
	fired := false
	cm.OnReady = func() { fired = true }
	if cm.Ready() {
		t.Fatal("ready before any greeting")
	}
	feedString(cm, "%begin 400 1 0\n")
	if fired || cm.Ready() {
		t.Fatal("ready on the block's opening marker — must wait for block completion")
	}
	feedString(cm, "%end 400 1 0\n")
	if !fired || !cm.Ready() {
		t.Fatal("greeting completion not signalled")
	}
}

func TestReadyLevelAfterGreeting(t *testing.T) {
	cm, _ := makeCM()
	feedString(cm, "%begin 400 1 0\n%end 400 1 0\n")
	if !cm.Ready() {
		t.Fatal("Ready() false after greeting consumed")
	}
}

func TestResetRearmsGreetingDetection(t *testing.T) {
	cm, _ := makeCM()
	feedString(cm, "%begin 400 1 0\n%end 400 1 0\n")
	cm.Reset()
	// After reset the OLD greeting must not satisfy a new connection.
	if cm.Ready() {
		t.Fatal("stale greeting survived reset")
	}
}

// --- Live-transcript replay (path-preview cwd query) ---

// Replays the EXACT byte shapes a real `tmux -C attach` produced for
// `display-message -p -t %5 "#{pane_current_path}"` (captured 2026-07-10 in
// the Swift lineage: CRLF line endings, greeting block + session-changed
// first) and asserts Send hands the path back.
func TestDisplayMessageRoundTripFromRealTranscript(t *testing.T) {
	cm, _ := makeCM()
	feedString(cm, "%begin 1783748239 283462 0\r\n%end 1783748239 283462 0\r\n%session-changed $1 Nova\r\n")
	if !cm.Ready() {
		t.Fatal("greeting not consumed")
	}
	var got *CommandResponse
	cm.Send(DisplayMessage("#{pane_current_path}", paneP(5)), func(r CommandResponse) { got = &r })
	feedString(cm, "%begin 1783748239 283466 1\r\n/Users/nova/code/speakterm\r\n%end 1783748239 283466 1\r\n")
	if got == nil || got.IsError {
		t.Fatalf("reply = %+v", got)
	}
	if strings.TrimSpace(got.Output) != "/Users/nova/code/speakterm" {
		t.Fatalf("output = %q", got.Output)
	}
}

// Same but with %output notifications interleaved inside the response
// block, as the live stream showed panes repainting mid-query.
func TestDisplayMessageWithInterleavedOutput(t *testing.T) {
	cm, _ := makeCM()
	feedString(cm, "%begin 1 100 0\r\n%end 1 100 0\r\n%session-changed $1 Nova\r\n")
	var got *CommandResponse
	cm.Send(DisplayMessage("#{pane_current_path}", paneP(5)), func(r CommandResponse) { got = &r })
	feedString(cm, "%output %4 \\033[?2026h\\033[?25l\r\n%begin 1 101 1\r\n/Users/nova/code/speakterm\r\n%output %5 xyz\r\n%end 1 101 1\r\n")
	if got == nil || got.IsError {
		t.Fatalf("reply = %+v", got)
	}
	if strings.TrimSpace(got.Output) != "/Users/nova/code/speakterm" {
		t.Fatalf("output = %q", got.Output)
	}
}

// Regression: SendKeysHex (keystroke / focus-report input via send-keys -H)
// produces an empty %begin/%end response like any command. Before it was
// registered in the fire-and-forget count, that empty block was matched
// FIFO to whatever Send was pending — the cwd query mostly got "" back.
func TestInterleavedInputDoesNotStealSendResponse(t *testing.T) {
	cm, _ := makeCM()
	feedString(cm, "%begin 1 100 0\r\n%end 1 100 0\r\n%session-changed $1 Nova\r\n")

	// Focus-report bytes hit the pane right before the query (CSI I).
	cm.SendKeysHex(5, []byte{0x1b, 0x5b, 0x49})

	var got *CommandResponse
	cm.Send(DisplayMessage("#{pane_current_path}", paneP(5)), func(r CommandResponse) { got = &r })

	// tmux answers in wire order: send-keys' EMPTY block first, then the
	// display-message block.
	feedString(cm, "%begin 1 101 1\r\n%end 1 101 1\r\n")
	feedString(cm, "%begin 1 102 1\r\n/Users/nova/code/speakterm\r\n%end 1 102 1\r\n")

	if got == nil || got.IsError {
		t.Fatalf("reply = %+v", got)
	}
	if strings.TrimSpace(got.Output) != "/Users/nova/code/speakterm" {
		t.Fatalf("output = %q", got.Output)
	}
}
