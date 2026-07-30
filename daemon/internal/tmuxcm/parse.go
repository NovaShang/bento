package tmuxcm

import (
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode"
)

// Stateless parsers for tmux's textual output (Swift: TmuxParsers + ANSI +
// TmuxLayoutTree's parse/serialize half). Use these on the response body a
// ControlMode hands back for list-panes / list-windows / list-sessions, or
// on raw bytes captured from a shell where tmux ran directly.

// ParsePaneList parses the output of `list-panes` with the format
// `#{pane_id}:…:#{window_active}:#{window_id}:#{pane_in_mode}:#{pane_title}`
// (the exact field list ListPanes builds). The zoom flag is per-window
// (every pane in a zoomed window reports 1). Every fixed field precedes
// pane_title (last) so the title may contain colons; window_active/window_id
// make session-wide listings (-s) attributable to windows without separate
// window state.
//
// Unlike the Swift original (whose split drops empty fields, shifting
// everything after an empty #{pane_current_command}), the split here is
// positional: an empty field stays an empty field.
func ParsePaneList(output string) []Pane {
	var panes []Pane
	for _, line := range strings.Split(output, "\n") {
		if line == "" {
			continue
		}
		// 15 fields; the title (last) may itself contain colons, so every
		// fixed field is placed before it.
		parts := strings.SplitN(line, ":", 15)
		if len(parts) < 6 {
			continue
		}
		id, ok := ParsePaneID(parts[0])
		if !ok {
			continue
		}
		width, err1 := strconv.Atoi(parts[1])
		height, err2 := strconv.Atoi(parts[2])
		x, err3 := strconv.Atoi(parts[3])
		y, err4 := strconv.Atoi(parts[4])
		if err1 != nil || err2 != nil || err3 != nil || err4 != nil {
			continue
		}

		p := Pane{
			ID:             id,
			Width:          width,
			Height:         height,
			X:              x,
			Y:              y,
			IsActive:       parts[5] == "1",
			InActiveWindow: true,
		}
		if len(parts) > 6 {
			p.IsZoomed = parts[6] == "1"
		}
		if len(parts) > 7 {
			p.CurrentCommand = parts[7]
		}
		if len(parts) > 8 {
			p.MouseAny = parts[8] == "1"
		}
		if len(parts) > 9 {
			p.MouseSGR = parts[9] == "1"
		}
		if len(parts) > 10 {
			p.AlternateOn = parts[10] == "1"
		}
		if len(parts) > 11 {
			p.InActiveWindow = parts[11] == "1"
		}
		if len(parts) > 12 {
			p.WindowID, p.HasWindowID = ParseWindowID(parts[12])
		}
		if len(parts) > 13 {
			p.InMode = parts[13] == "1"
		}
		if len(parts) > 14 {
			p.Title = parts[14]
		}
		panes = append(panes, p)
	}
	return panes
}

// ParsePanePathList parses the output of ListPanePaths
// (`#{pane_id}:#{pane_current_path}`) into a per-pane cwd map. The path
// (last field) may itself contain colons, so SplitN stops at the first.
// Panes reporting no path or a relative one are omitted — only absolute
// paths mean anything to the callers (file preview, directory pickers),
// matching the frozen client's hasPrefix("/") acceptance.
func ParsePanePathList(output string) map[PaneID]string {
	out := map[PaneID]string{}
	for _, line := range strings.Split(output, "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, ":", 2)
		if len(parts) < 2 {
			continue
		}
		id, ok := ParsePaneID(parts[0])
		if !ok || !strings.HasPrefix(parts[1], "/") {
			continue
		}
		out[id] = parts[1]
	}
	return out
}

// PaneGeometry is one pane's geometry extracted from a tmux window-layout
// string.
type PaneGeometry struct {
	ID     PaneID
	Width  int
	Height int
	X      int
	Y      int
}

// Matches leaf-pane geometry; hoisted because ParsePaneGeometry runs on
// every %layout-change and regexp compilation isn't free.
var paneGeometryRE = regexp.MustCompile(`(\d+)x(\d+),(\d+),(\d+),(\d+)`)

// ParsePaneGeometry parses a tmux window-layout string (as carried by
// %layout-change or list-windows' #{window_layout}) into each leaf pane's
// geometry.
//
// The format is a recursive description:
//
//	<checksum>,<WxH>,<X>,<Y>{<child>,<child>,…}  (horizontal split)
//	<WxH>,<X>,<Y>[<child>,<child>,…]             (vertical split)
//	<WxH>,<X>,<Y>,<paneId>                       (leaf pane)
//
// e.g. `5504,181x45,0,0{56x45,0,0,38,124x45,57,0[71x30,…,39,52x30,…,70]}`.
// Only leaves carry a trailing `,<paneId>` (split nodes are followed by
// `{`/`[`), so matching `WxH,X,Y,id` extracts exactly the leaf panes.
// For the full tree (splits included), see ParseLayout.
func ParsePaneGeometry(layout string) []PaneGeometry {
	var out []PaneGeometry
	for _, m := range paneGeometryRE.FindAllStringSubmatch(layout, -1) {
		w, err1 := strconv.Atoi(m[1])
		h, err2 := strconv.Atoi(m[2])
		x, err3 := strconv.Atoi(m[3])
		y, err4 := strconv.Atoi(m[4])
		id, err5 := strconv.Atoi(m[5])
		if err1 != nil || err2 != nil || err3 != nil || err4 != nil || err5 != nil {
			continue
		}
		out = append(out, PaneGeometry{ID: PaneID(id), Width: w, Height: h, X: x, Y: y})
	}
	return out
}

// ParseSessionList parses the output of `list-sessions` with the format
// `#{session_id}:#{session_name}` (the exact format ListSessions builds).
// Session names cannot contain ':' or '.' (tmux refuses them), so the name
// needs no last-field treatment — but SplitN keeps the parse safe anyway.
func ParseSessionList(output string) []Session {
	var sessions []Session
	for _, line := range strings.Split(output, "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, ":", 2)
		if len(parts) < 2 {
			continue
		}
		id, ok := ParseSessionID(parts[0])
		if !ok {
			continue
		}
		sessions = append(sessions, Session{ID: id, Name: parts[1]})
	}
	return sessions
}

// ParseWindowList parses the output of `list-windows` with the format
// `#{window_id}:#{window_index}:#{window_active}:#{window_layout}:#{window_name}`.
// window_name is free text (a title may contain colons), so it is the LAST
// field — every fixed field precedes it, mirroring ParsePaneList's
// pane_title. A colon in the name therefore cannot corrupt window_layout
// (which Bento persists for structure restore).
func ParseWindowList(output string) []Window {
	var windows []Window
	for _, line := range strings.Split(output, "\n") {
		if line == "" {
			continue
		}
		// 5 fields; the name (last) may itself contain colons.
		parts := strings.SplitN(line, ":", 5)
		id, ok := ParseWindowID(parts[0])
		if !ok {
			continue
		}
		w := Window{ID: id, Index: -1}
		if len(parts) > 1 {
			if idx, err := strconv.Atoi(parts[1]); err == nil {
				w.Index = idx
			}
		}
		if len(parts) > 2 {
			w.IsActive = parts[2] == "1"
		}
		if len(parts) > 3 {
			w.Layout = parts[3]
		}
		if len(parts) > 4 {
			w.Name = parts[4]
		}
		windows = append(windows, w)
	}
	return windows
}

// ParseTmuxLs extracts session names from `tmux ls` output read over an
// interactive PTY (with shell echo, OSC title escapes, CRLF endings,
// syntax-highlight noise). The caller wraps the command in two markers; this
// function slices strictly between them.
//
// Caller contract: build markers as two concatenated halves (e.g. "__S_xxx_"
// + "_GO__"). The runtime `printf '%s%s' ...` will emit the contiguous
// marker, but the PTY echo of the command line renders the halves as
// separate single-quoted shell tokens, never adjacent — so a substring check
// can't mismatch on the echo.
//
// Why the markers matter: without them, parsers either lose the first
// session (eaten by an OSC sequence the shell injected) or stop after the
// first line (the CRLF trap the Swift original hit as a single grapheme
// cluster).
func ParseTmuxLs(output, startMarker, endMarker string) []string {
	body := output
	s := strings.Index(output, startMarker)
	e := strings.Index(output, endMarker)
	switch {
	case s >= 0 && e >= 0 && s+len(startMarker) < e:
		body = output[s+len(startMarker) : e]
	case e >= 0:
		// Start marker missing (printf-start failed silently): still slice
		// up to the end marker — better a partial result than nothing.
		body = output[:e]
	}
	cleaned := StripANSI(body)
	var names []string
	// Splitting on both \r and \n (dropping empties) is what handles CRLF
	// per line — the same job Swift's isNewline-based split did.
	for _, raw := range strings.FieldsFunc(cleaned, func(r rune) bool { return r == '\n' || r == '\r' }) {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		// Each tmux ls line has a colon between name and stats.
		colon := strings.IndexByte(line, ':')
		if colon < 0 {
			continue
		}
		name := strings.TrimSpace(line[:colon])
		rest := line[colon+1:]
		// Tail must look like `: N windows`; otherwise a banner / MOTD line
		// that happens to contain a colon would masquerade as a session.
		if !strings.Contains(rest, "windows") {
			continue
		}
		if name == "" || !isValidSessionName(name) {
			continue
		}
		if !slices.Contains(names, name) {
			names = append(names, name)
		}
	}
	return names
}

func isValidSessionName(name string) bool {
	for _, r := range name {
		if !unicode.IsLetter(r) && !unicode.IsNumber(r) && r != '-' && r != '_' && r != '.' {
			return false
		}
	}
	return true
}

// ANSI escape-sequence stripping. Handles CSI (ESC [ … letter), OSC
// (ESC ] … BEL or ESC ] … ESC \), and bare-ESC 2-byte sequences.
//
// A regex rather than a hand-rolled state machine on purpose: unterminated
// OSCs (which real shells emit) tripped the Swift layer's earlier state
// machine into eating ESC bytes belonging to the NEXT sequence — that bug
// silently swallowed the bulk of `tmux ls` output. The regex matches
// optional terminators and never consumes more than one sequence at a time.
var ansiRE = regexp.MustCompile(
	// CSI:       ESC [ <params 0-9;?> <intermediates SP-/> <final @-~>
	"\x1b\\[[0-9;?]*[ -/]*[@-~]" +
		// OSC:       ESC ] <data not BEL/ESC> (BEL | ESC \)? — terminator optional
		"|\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)?" +
		// Charset:   ESC <intermediate SP-/> <final SP-~> — e.g. `ESC ( 0`
		"|\x1b[ -/][ -~]" +
		// Short ESC: ESC + any one byte — fallback for 2-byte sequences
		"|\x1b.")

// StripANSI strips every CSI / OSC / bare-ESC sequence from s and returns
// the remainder. Idempotent and safe to call on arbitrary text.
func StripANSI(s string) string {
	return ansiRE.ReplaceAllString(s, "")
}

// UnescapeOutput decodes the escaping tmux applies to %output payloads:
// bytes < 32 and backslash arrive as `\XXX` (three octal digits). Working on
// raw bytes (never a string round-trip) is what preserves multi-byte UTF-8
// sequences — box-drawing characters and CJK output must come through
// intact. The result is always a fresh slice, never an alias of the input.
func UnescapeOutput(in []byte) []byte {
	out := make([]byte, 0, len(in))
	for i := 0; i < len(in); {
		b := in[i]
		if b == '\\' && i+3 < len(in) {
			d0, d1, d2 := in[i+1], in[i+2], in[i+3]
			if d0 >= '0' && d0 <= '7' && d1 >= '0' && d1 <= '7' && d2 >= '0' && d2 <= '7' {
				out = append(out, (d0-'0')<<6|(d1-'0')<<3|(d2-'0'))
				i += 4
				continue
			}
		}
		out = append(out, b)
		i++
	}
	return out
}

// --- Layout tree (Swift: TmuxLayoutTree's parse/serialize half) ---

// ParseLayout parses a full window-layout string (with or without its
// leading 4-hex-digit checksum prefix) into the layout tree. Trailing
// garbage after a complete node is tolerated, like the Swift original.
func ParseLayout(layout string) (LayoutNode, bool) {
	body := layout
	// Strip the "abcd," checksum prefix when present (4 hex digits).
	if len(body) > 4 && body[4] == ',' && isHex4(body[:4]) {
		body = body[5:]
	}
	node, _, ok := parseLayoutNode(body)
	return node, ok
}

func isHex4(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}

func parseLayoutNode(s string) (LayoutNode, string, bool) {
	var n LayoutNode
	w, rest, ok := parseLayoutInt(s)
	if !ok || rest == "" || rest[0] != 'x' {
		return n, s, false
	}
	h, rest, ok := parseLayoutInt(rest[1:])
	if !ok || rest == "" || rest[0] != ',' {
		return n, s, false
	}
	x, rest, ok := parseLayoutInt(rest[1:])
	if !ok || rest == "" || rest[0] != ',' {
		return n, s, false
	}
	y, rest, ok := parseLayoutInt(rest[1:])
	if !ok || rest == "" {
		return n, s, false
	}
	n.W, n.H, n.X, n.Y = w, h, x, y

	switch rest[0] {
	case '{', '[':
		isH := rest[0] == '{'
		closer := byte('}')
		if !isH {
			closer = ']'
		}
		rest = rest[1:]
		var children []LayoutNode
		for {
			child, r, ok := parseLayoutNode(rest)
			if !ok {
				return n, s, false
			}
			children = append(children, child)
			rest = r
			if rest != "" && rest[0] == ',' {
				rest = rest[1:]
				continue
			}
			if rest != "" && rest[0] == closer {
				rest = rest[1:]
				break
			}
			return n, s, false
		}
		if isH {
			n.Kind = LayoutHSplit
		} else {
			n.Kind = LayoutVSplit
		}
		n.Children = children
		return n, rest, true
	case ',':
		id, r, ok := parseLayoutInt(rest[1:])
		if !ok {
			return n, s, false
		}
		n.Kind = LayoutLeaf
		n.ID = id
		return n, r, true
	default:
		return n, s, false
	}
}

func parseLayoutInt(s string) (int, string, bool) {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	if i == 0 {
		return 0, s, false
	}
	v, err := strconv.Atoi(s[:i])
	if err != nil {
		return 0, s, false
	}
	return v, s[i:], true
}

// SerializeLayout renders a node back to a full layout string, checksum
// included — the form select-layout accepts.
func SerializeLayout(n LayoutNode) string {
	body := serializeLayoutNode(n)
	return fmt.Sprintf("%04x,%s", layoutChecksum(body), body)
}

func serializeLayoutNode(n LayoutNode) string {
	head := fmt.Sprintf("%dx%d,%d,%d", n.W, n.H, n.X, n.Y)
	switch n.Kind {
	case LayoutHSplit, LayoutVSplit:
		open, closer := "{", "}"
		if n.Kind == LayoutVSplit {
			open, closer = "[", "]"
		}
		parts := make([]string, len(n.Children))
		for i, c := range n.Children {
			parts[i] = serializeLayoutNode(c)
		}
		return head + open + strings.Join(parts, ",") + closer
	default:
		return head + "," + strconv.Itoa(n.ID)
	}
}

// layoutChecksum is tmux's layout checksum (layout-custom.c): rotate right
// by 1 then add each byte, over the body AFTER the "xxxx," prefix.
func layoutChecksum(body string) uint16 {
	var csum uint16
	for i := 0; i < len(body); i++ {
		csum = (csum >> 1) + ((csum & 1) << 15)
		csum += uint16(body[i])
	}
	return csum
}

// LeafOrder returns the pane ids of the leaves in depth-first order — the
// order select-layout will assign the window's panes in.
func LeafOrder(n LayoutNode) []int {
	if n.Kind == LayoutLeaf {
		return []int{n.ID}
	}
	var out []int
	for _, c := range n.Children {
		out = append(out, LeafOrder(c)...)
	}
	return out
}
