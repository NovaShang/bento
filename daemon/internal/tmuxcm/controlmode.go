package tmuxcm

import (
	"bytes"
	"strconv"
	"strings"
	"unicode/utf8"
)

// ControlMode parses and manages the tmux control-mode (-CC) protocol
// (Swift: TmuxControlMode).
//
// Commands are sent as plain text lines. Responses come back wrapped in
// %begin/%end (or %error) blocks with tmux-assigned command numbers. A FIFO
// queue matches responses to callers, because tmux's command numbers are
// globally incremented (not per-client) and so cannot key a lookup.
//
// I/O is transport-agnostic: feed bytes in via Feed, hook Write to forward
// outgoing commands, observe parsed events via OnNotification.
//
// This is a deliberately SYNCHRONOUS port. The Swift original carried locks,
// checked continuations, per-send timeout tasks and a 16ms input coalescer
// because it sat directly under the UI; here all of that is the host
// layer's job. ControlMode is not safe for concurrent use, and callbacks
// must not re-enter Feed or Reset — they may call Send (registering another
// pending reply is well-defined mid-stream).
type ControlMode struct {
	// OnNotification is called for each parsed notification (output, layout
	// changes, etc.), in stream order. Output notifications carry fresh
	// slices — safe to retain.
	OnNotification func(Notification)
	// Write forwards an outgoing command line (trailing newline included)
	// to the transport carrying the tmux client. nil drops writes, which is
	// convenient in tests.
	Write func(line string)
	// OnReady fires once per connection, when the greeting block completes
	// — the earliest safe point to start sending commands (see Ready).
	OnReady func()
	// Logf is an optional log hook for sends/receives and warnings. nil
	// disables logging (the Swift fallback os.Logger has no Go analogue
	// worth keeping).
	Logf func(format string, args ...any)

	// Line buffer for incoming bytes (partial trailing line).
	buf []byte
	// FIFO of reply callbacks for EVERY in-flight command, in send order. A
	// nil entry is a discard slot (SendFireAndForget, SendKeysHex): tmux
	// answers every command, strictly in command order, so a discard must
	// hold its position in the SAME queue. The earlier design — a side
	// counter of responses-to-drop — was order-blind: a send-keys issued
	// while two Sends were in flight consumed the FIRST pending response
	// and shifted every later one (live-debugged 2026-07-29 in the Go host
	// layer, where it fed an empty list-panes to the structure refresh).
	// Response blocks are matched to entries strictly in order, so
	// registration order and wire order must never diverge — every sender
	// appends and writes in one step for exactly that reason.
	pending []func(CommandResponse)
	// The response block currently being collected, nil outside a block.
	current *commandBlock
	// True once the current connection's greeting block has been consumed.
	// `tmux -CC new-session/attach` emits one UNSOLICITED %begin/%end block
	// (for the implicit command) before anything else. It must never be
	// matched against pending — if a caller's Send lands in the queue while
	// the greeting is still in flight, the greeting's %end would steal that
	// reply and every later response would shift by one. Cleared by Reset
	// so each new connection discards exactly one block.
	greetingConsumed bool
}

type commandBlock struct {
	commandNumber int
	lines         []string
}

// Ready reports whether the current connection's greeting block has been
// consumed — the earliest safe point to send commands. Earlier, they'd
// either be typed into the plain shell (tmux not attached yet) or their
// reply would be stolen by the greeting's %end. (Swift: awaitControlMode;
// the synchronous port exposes the edge via OnReady and the level here, and
// leaves waiting/timeouts to the host layer.)
func (cm *ControlMode) Ready() bool { return cm.greetingConsumed }

// Send writes a tmux command and registers reply to receive its response
// block. reply == nil behaves like SendFireAndForget. There is no timeout
// here: a reply for a response that never arrives is released by Reset when
// the host layer decides the connection is dead.
func (cm *ControlMode) Send(cmd Command, reply func(CommandResponse)) {
	if reply == nil {
		cm.SendFireAndForget(cmd)
		return
	}
	line := string(cmd) + "\n"
	cm.logf("tmux send: %s", string(cmd))
	cm.pending = append(cm.pending, reply)
	if cm.Write != nil {
		cm.Write(line)
	}
}

// SendFireAndForget writes a tmux command without waiting for its response.
// The response still arrives; a discard slot queued in send order ensures
// it is dropped instead of being delivered to another Send caller.
func (cm *ControlMode) SendFireAndForget(cmd Command) {
	line := string(cmd) + "\n"
	cm.logf("tmux send (fire): %s", string(cmd))
	cm.pending = append(cm.pending, nil)
	if cm.Write != nil {
		cm.Write(line)
	}
}

// SendKeysHex sends raw bytes to a pane as terminal input, via
// `send-keys -H` (hex mode) so any byte — including \r, \n, \x1b — survives
// without breaking the tmux protocol. (Swift: sendData, minus the 16ms
// input coalescing — batching is concurrency machinery and belongs to the
// host layer above.)
//
// send-keys gets an (empty) %begin/%end response like any command; it is
// registered as a discard slot so it cannot steal a pending Send's response
// (that desync fed empty output to display-message callers once,
// live-debugged 2026-07-10 in the Swift layer).
func (cm *ControlMode) SendKeysHex(pane PaneID, data []byte) {
	if len(data) == 0 {
		return
	}
	// Byte-table hex encoding (lowercase, 2 digits, space-separated).
	const hexDigits = "0123456789abcdef"
	hex := make([]byte, 0, len(data)*3)
	for _, b := range data {
		if len(hex) > 0 {
			hex = append(hex, ' ')
		}
		hex = append(hex, hexDigits[b>>4], hexDigits[b&0x0f])
	}
	line := "send-keys -t " + pane.String() + " -H " + string(hex) + "\n"
	cm.pending = append(cm.pending, nil)
	if cm.Write != nil {
		cm.Write(line)
	}
}

// Reset discards all connection-scoped parser state. Call whenever the byte
// stream restarts (transport reconnect). Two failure modes otherwise survive
// into the new connection:
//
//  1. A response block truncated by the drop (%begin seen, %end lost)
//     leaves current set, so every non-%output notification of the new
//     stream is swallowed as block content. (%output itself takes the raw
//     fast path and keeps flowing.)
//  2. Replies queued by the dead connection consume the new connection's
//     response blocks FIFO — post-reconnect commands starve or receive the
//     wrong block, so callers rebuild state from garbage.
//
// Orphaned replies are released with an IsError "connection reset" response.
func (cm *ControlMode) Reset() {
	cm.buf = cm.buf[:0]
	orphans := cm.pending
	cm.pending = nil
	cm.current = nil
	cm.greetingConsumed = false
	if len(orphans) > 0 {
		cm.logf("tmux parser reset: dropping %d pending command(s)", len(orphans))
	}
	for _, reply := range orphans {
		if reply == nil {
			continue // discard slot: nobody is waiting
		}
		reply(CommandResponse{CommandNumber: -1, IsError: true, Output: "connection reset"})
	}
}

// Feed appends raw bytes from the transport and processes every complete
// line. A partial trailing line is buffered until its newline arrives.
func (cm *ControlMode) Feed(data []byte) {
	cm.buf = append(cm.buf, data...)
	last := bytes.LastIndexByte(cm.buf, '\n')
	if last < 0 {
		return
	}
	block := cm.buf[:last+1]
	for len(block) > 0 {
		nl := bytes.IndexByte(block, '\n')
		line := block[:nl]
		if n := len(line); n > 0 && line[n-1] == '\r' {
			line = line[:n-1]
		}
		cm.handleLine(line)
		block = block[nl+1:]
	}
	// Compact the remainder to the front. handleLine never retains slices
	// of buf (strings and UnescapeOutput both copy), so this is safe.
	rest := cm.buf[last+1:]
	cm.buf = append(cm.buf[:0], rest...)
}

const outputPrefix = "%output "

// Control-mode notifications that are valid at ANY point in the stream —
// including interleaved inside another command's %begin…%end block. tmux
// emits these out-of-band (most visibly the repaint / %layout-change burst
// that follows select-window), so they must be dispatched rather than folded
// into the command's output. Excludes %begin/%end/%error (block framing) and
// %output (raw fast path in handleLine); the string "%output " is kept so a
// fallback string-path output still routes out.
var notificationPrefixes = []string{
	"%output ", "%layout-change ", "%window-add ", "%window-close ",
	"%window-renamed ", "%window-pane-changed", "%unlinked-window-add",
	"%unlinked-window-close", "%session-changed ", "%session-renamed ",
	"%session-window-changed ", "%sessions-changed", "%pane-mode-changed ",
	"%client-session-changed", "%client-detached ", "%config-error", "%exit",
}

// Recognised % markers used to realign a line that arrives with leading junk
// (stray DCS / shell echo) outside a block.
var realignPrefixes = []string{
	"%begin ", "%output ", "%end ", "%error ",
	"%session", "%layout-change ", "%window-", "%pane-",
	"%exit", "%unlinked-", "%client-", "%config-",
}

func isOutOfBandNotification(line string) bool {
	for _, prefix := range notificationPrefixes {
		if strings.HasPrefix(line, prefix) {
			return true
		}
	}
	return false
}

// Markers used to realign a notification that arrived INSIDE a block behind
// a leading escape/control junk prefix. Deliberately TIGHTER than
// realignPrefixes — each carries its structural sigil (`%output %`, window
// `@` / session `$` ids, or a trailing space) so a captured screen line that
// merely contains e.g. the text "%output" is not mistaken for protocol.
var inBlockRealignMarkers = []string{
	"%output %", "%begin ", "%end ", "%error ", "%layout-change ",
	"%window-add @", "%window-close @", "%window-renamed @",
	"%window-pane-changed @", "%unlinked-window-add @", "%unlinked-window-close @",
	"%session-changed $", "%session-renamed $", "%session-window-changed $",
	"%sessions-changed", "%pane-mode-changed %", "%client-session-changed ",
	"%client-detached ", "%config-error ", "%exit",
}

// realignJunkPrefixed: if line begins with a NON-PRINTABLE escape/control
// byte — stray DCS/CSI residue that transport framing can splice onto a
// control-mode notification (the "tmux -CC chatter in the pane" on a session
// switch, BUG-007 in the Swift layer) — and a recognised protocol marker
// follows that junk, return the line realigned to the marker. The
// non-printable-first-byte anchor is the whole point: genuine captured
// content starts with a printable glyph, so a captured line that merely
// CONTAINS "%end " as a substring is never realigned (and so never truncates
// the response — the trap the outside-block realign avoids by staying
// outside blocks).
func realignJunkPrefixed(line string) (string, bool) {
	r, _ := utf8.DecodeRuneInString(line)
	if line == "" || (r >= 0x20 && r != 0x7f) {
		return "", false
	}
	for _, m := range inBlockRealignMarkers {
		idx := strings.Index(line, m)
		if idx < 0 {
			continue
		}
		if idx == 0 {
			return "", false
		}
		return line[idx:], true
	}
	return "", false
}

func (cm *ControlMode) handleLine(lineData []byte) {
	// Fast path: %output uses raw-byte parsing to preserve multi-byte UTF-8
	// sequences, and — checked BEFORE the in-block branch — keeps pane
	// output flowing even when a truncated block has the parser stuck in
	// collection mode.
	if len(lineData) > len(outputPrefix) && bytes.HasPrefix(lineData, []byte(outputPrefix)) {
		cm.parseOutputRaw(lineData)
		return
	}

	line := string(lineData)

	// Inside a command's %begin…%end block, tmux can still interleave
	// out-of-band notifications — most visibly the repaint / %layout-change
	// burst that follows select-window. They are NOT part of the command's
	// output: folding them into the block corrupts the response (capture-pane
	// would seed a surface with raw protocol text, list-panes/list-windows
	// silently drop lines). Route those out-of-band; keep only genuine
	// output in the block. Match on the RAW line — the leading-junk
	// realignment below must not run inside a block, or a captured line that
	// merely CONTAINS "%end " as a substring would truncate the response.
	if cm.current != nil {
		switch {
		case strings.HasPrefix(line, "%end "):
			cm.finishBlock(false)
		case strings.HasPrefix(line, "%error "):
			cm.finishBlock(true)
		case isOutOfBandNotification(line):
			cm.parseLine(line)
		default:
			if realigned, ok := realignJunkPrefixed(line); ok {
				// A notification arrived inside the block behind an
				// escape/control junk prefix, so the strict checks above
				// missed it. Route its clean form the same way. A stray
				// framing marker we can't re-inject (e.g. a bare %begin from
				// a lost %end) is dropped rather than painted; the eventual
				// %end still closes this block.
				switch {
				case strings.HasPrefix(realigned, "%end "):
					cm.finishBlock(false)
				case strings.HasPrefix(realigned, "%error "):
					cm.finishBlock(true)
				case isOutOfBandNotification(realigned):
					cm.parseLine(realigned)
				}
			} else {
				cm.current.lines = append(cm.current.lines, line)
			}
		}
		return
	}

	// Outside a block: a stray DCS / shell echo can prefix a real
	// notification; realign to the first recognised % marker before
	// dispatch.
	cleaned := line
	for _, p := range realignPrefixes {
		if idx := strings.Index(cleaned, p); idx >= 0 {
			if idx > 0 {
				cleaned = cleaned[idx:]
			}
			break
		}
	}
	cm.parseLine(cleaned)
}

// parseOutputRaw parses %output directly from raw bytes, preserving UTF-8
// integrity. Format: `%output %<id> <escaped_data>`.
func (cm *ControlMode) parseOutputRaw(lineData []byte) {
	rest := lineData[len(outputPrefix):]
	sp := bytes.IndexByte(rest, ' ')
	if sp < 0 {
		return
	}
	pane, ok := ParsePaneID(string(rest[:sp]))
	if !ok {
		return
	}
	cm.notify(Output{Pane: pane, Data: UnescapeOutput(rest[sp+1:])})
}

// parseLine dispatches a single control-mode line as a notification / block
// frame. Block accumulation (and routing out-of-band notifications past an
// in-flight block) is handled upstream in handleLine.
func (cm *ControlMode) parseLine(line string) {
	// %output first and unlogged (it never was); everything else logs
	// before dispatch.
	if strings.HasPrefix(line, outputPrefix) {
		cm.parseOutputRaw([]byte(line))
		return
	}

	cm.logf("tmux recv: %s", line)

	switch {
	case strings.HasPrefix(line, "%begin "):
		parts := splitSpaces(line)
		if len(parts) < 3 {
			cm.logf("invalid %%begin: %s", line)
			return
		}
		num, err := strconv.Atoi(parts[2])
		if err != nil {
			cm.logf("invalid %%begin: %s", line)
			return
		}
		cm.current = &commandBlock{commandNumber: num}

	case strings.HasPrefix(line, "%layout-change "):
		parts := splitSpaces(line)
		if len(parts) < 3 {
			return
		}
		win, ok := ParseWindowID(parts[1])
		if !ok {
			return
		}
		// Extra fields (visible layout, flags) are deliberately ignored.
		cm.notify(LayoutChange{Window: win, Layout: parts[2]})

	case strings.HasPrefix(line, "%window-add "):
		parts := splitSpaces(line)
		if len(parts) < 2 {
			return
		}
		if win, ok := ParseWindowID(parts[1]); ok {
			cm.notify(WindowAdd{Window: win})
		}

	case strings.HasPrefix(line, "%window-close "):
		parts := splitSpaces(line)
		if len(parts) < 2 {
			return
		}
		if win, ok := ParseWindowID(parts[1]); ok {
			cm.notify(WindowClose{Window: win})
		}

	case strings.HasPrefix(line, "%window-renamed "):
		parts := strings.SplitN(line, " ", 3)
		if len(parts) < 3 {
			return
		}
		if win, ok := ParseWindowID(parts[1]); ok {
			cm.notify(WindowRenamed{Window: win, Name: parts[2]})
		}

	case strings.HasPrefix(line, "%session-changed "):
		parts := strings.SplitN(line, " ", 3)
		if len(parts) < 3 {
			return
		}
		if ses, ok := ParseSessionID(parts[1]); ok {
			cm.notify(SessionChanged{Session: ses, Name: parts[2]})
		}

	case strings.HasPrefix(line, "%session-window-changed "):
		// `%session-window-changed $S @W`: the session's current window moved.
		parts := splitSpaces(line)
		if len(parts) < 3 {
			return
		}
		ses, okS := ParseSessionID(parts[1])
		win, okW := ParseWindowID(parts[2])
		if okS && okW {
			cm.notify(SessionWindowChanged{Session: ses, Window: win})
		}

	case strings.HasPrefix(line, "%session-renamed "):
		cm.notify(SessionRenamed{Name: strings.TrimPrefix(line, "%session-renamed ")})

	case strings.HasPrefix(line, "%pane-mode-changed "):
		parts := splitSpaces(line)
		if len(parts) < 2 {
			return
		}
		pane, ok := ParsePaneID(parts[1])
		if !ok {
			return
		}
		mode := ""
		if len(parts) >= 3 {
			mode = parts[2]
		}
		cm.notify(PaneModeChanged{Pane: pane, Mode: mode})

	case strings.HasPrefix(line, "%window-pane-changed "):
		parts := splitSpaces(line)
		if len(parts) < 3 {
			return
		}
		win, okW := ParseWindowID(parts[1])
		pane, okP := ParsePaneID(parts[2])
		if okW && okP {
			cm.notify(WindowPaneChanged{Window: win, Pane: pane})
		}

	case strings.HasPrefix(line, "%client-detached "):
		client := strings.TrimSpace(strings.TrimPrefix(line, "%client-detached "))
		if client != "" {
			cm.notify(ClientDetached{Client: client})
		}

	case strings.HasPrefix(line, "%exit"):
		reason := ""
		if len(line) > len("%exit") {
			reason = line[len("%exit "):]
		}
		cm.notify(Exit{Reason: reason})

	case strings.HasPrefix(line, "%sessions-changed"),
		strings.HasPrefix(line, "%unlinked-window-add"),
		strings.HasPrefix(line, "%unlinked-window-close"),
		strings.HasPrefix(line, "%client-session-changed"),
		strings.HasPrefix(line, "%config-error"):
		cm.logf("tmux ignored notification: %.60s", line)

	default:
		// Ignore unrecognized lines (e.g. DCS sequences, echo).
	}
}

func (cm *ControlMode) finishBlock(isError bool) {
	block := cm.current
	if block == nil {
		return
	}
	cm.current = nil

	// The first block of a connection is the -CC greeting (tmux's response
	// to the implicit new-session/attach command, which no Send issued).
	// Consume it without touching the pending queue — matching it FIFO
	// would hand its (empty) output to the first real caller and shift
	// every later response by one. Its completion is also the "control mode
	// is ready" signal.
	if !cm.greetingConsumed {
		cm.greetingConsumed = true
		if cm.OnReady != nil {
			cm.OnReady()
		}
		return
	}

	response := CommandResponse{
		CommandNumber: block.commandNumber,
		IsError:       isError,
		Output:        strings.Join(block.lines, "\n"),
	}
	cm.logf("tmux response #%d (error=%v): %.200s", response.CommandNumber, isError, response.Output)

	if len(cm.pending) == 0 {
		return
	}
	reply := cm.pending[0]
	cm.pending = cm.pending[1:]
	if reply == nil {
		return // discard slot (fire-and-forget / send-keys)
	}
	reply(response)
}

func (cm *ControlMode) notify(n Notification) {
	if cm.OnNotification != nil {
		cm.OnNotification(n)
	}
}

func (cm *ControlMode) logf(format string, args ...any) {
	if cm.Logf != nil {
		cm.Logf(format, args...)
	}
}

// splitSpaces splits on single spaces and drops empty fields — the exact
// behavior of Swift's split(separator:" ") with empty subsequences omitted,
// which the original notification parsers relied on.
func splitSpaces(s string) []string {
	var out []string
	for _, f := range strings.Split(s, " ") {
		if f != "" {
			out = append(out, f)
		}
	}
	return out
}
