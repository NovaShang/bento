// Package tmuxcm speaks tmux's control-mode (-CC) protocol: command
// builders, stateless line/output parsers, and the stateful
// reply/notification demultiplexer the daemon-side tmux host is built on.
// It is a port of the Swift layer at swift-tmux/Sources/SwiftTmux and
// depends on nothing but the standard library.
//
// Unlike the Swift original (which carried its own locks, continuations and
// input batching because it sat directly under SwiftUI), this port is a
// plain synchronous state machine: feed it lines, get callbacks, no
// goroutines. The host layer above owns all concurrency.
//
// Name mapping from the Swift original (kept recognizable on purpose):
//
//	TmuxSessionID / TmuxWindowID / TmuxPaneID   → SessionID / WindowID / PaneID
//	TmuxNotification (enum cases)               → Notification (interface); Output,
//	                                              LayoutChange, WindowAdd, WindowClose,
//	                                              WindowRenamed, SessionChanged,
//	                                              SessionRenamed, PaneModeChanged,
//	                                              ClientDetached, Exit
//	TmuxCommandResponse                         → CommandResponse
//	TmuxWindow / Pane                           → Window / Pane
//	TmuxCommand (enum + commandString)          → Command + builder funcs (command.go)
//	SpawnCommand (.shell / .tmuxSyntax)         → SpawnCommand (ShellSpawn / TmuxSyntaxSpawn)
//	TmuxShellQuote.arg / .path                  → ShellQuoteArg / ShellQuotePath
//	TmuxControlMode.launchCommand               → LaunchCommand (command.go)
//	TmuxControlMode                             → ControlMode (controlmode.go)
//	TmuxParsers.parsePaneList / parseWindowList → ParsePaneList / ParseWindowList
//	TmuxParsers.parsePaneGeometry / parseTmuxLs → ParsePaneGeometry / ParseTmuxLs
//	TmuxParsers.PaneGeometry                    → PaneGeometry
//	ANSI.strip                                  → StripANSI
//	TmuxLayoutTree.Node / parse / serialize     → LayoutNode / ParseLayout / SerializeLayout
//	TmuxLayoutTree.leafOrder                    → LeafOrder
//	TmuxStructureSnapshot                       → StructureSnapshot (snapshot.go)
//
// Optionals collapse the Go way: optional strings become "" (a real value is
// never empty on the wire), optional window indices become -1, and the two
// optional IDs on command builders become pointers (0 is a valid tmux id).
package tmuxcm

import "strconv"

// SessionID is a tmux session id, e.g. "$0".
type SessionID int

func (s SessionID) String() string { return "$" + strconv.Itoa(int(s)) }

// ParseSessionID parses "$N". The bool is false when the sigil or number is
// wrong (Swift: the failable init).
func ParseSessionID(s string) (SessionID, bool) {
	n, ok := parseSigilID(s, '$')
	return SessionID(n), ok
}

// WindowID is a tmux window id, e.g. "@5".
type WindowID int

func (w WindowID) String() string { return "@" + strconv.Itoa(int(w)) }

// ParseWindowID parses "@N".
func ParseWindowID(s string) (WindowID, bool) {
	n, ok := parseSigilID(s, '@')
	return WindowID(n), ok
}

// PaneID is a tmux pane id, e.g. "%3". Pane ids are server-global and stable
// for a pane's lifetime — they survive break-pane/join-pane, which is what
// makes them usable as anchors for structure restore.
type PaneID int

func (p PaneID) String() string { return "%" + strconv.Itoa(int(p)) }

// ParsePaneID parses "%N".
func ParsePaneID(s string) (PaneID, bool) {
	n, ok := parseSigilID(s, '%')
	return PaneID(n), ok
}

func parseSigilID(s string, sigil byte) (int, bool) {
	if len(s) == 0 || s[0] != sigil {
		return 0, false
	}
	n, err := strconv.Atoi(s[1:])
	if err != nil {
		return 0, false
	}
	return n, true
}

// Notification is a parsed tmux control-mode notification (Swift:
// TmuxNotification). The concrete types below mirror the enum cases.
type Notification interface{ notification() }

// Output carries a pane's raw output bytes (%output), octal escapes already
// decoded. Data is always a fresh slice — safe to retain.
type Output struct {
	Pane PaneID
	Data []byte
}

// LayoutChange reports a window's new layout string (%layout-change).
type LayoutChange struct {
	Window WindowID
	Layout string
}

// WindowAdd reports a new window (%window-add).
type WindowAdd struct{ Window WindowID }

// WindowClose reports a closed window (%window-close).
type WindowClose struct{ Window WindowID }

// WindowRenamed reports a window's new name (%window-renamed).
type WindowRenamed struct {
	Window WindowID
	Name   string
}

// SessionChanged reports the client switching sessions (%session-changed).
type SessionChanged struct {
	Session SessionID
	Name    string
}

// SessionRenamed reports a session's new name (%session-renamed). Modern
// tmux (3.x) sends `$id name` and fires for ANY session on the server, not
// just the client's (verified live on 3.7b); HasSession is false only for
// the legacy id-less form, where the name is all we have and it can only
// mean the client's own session.
type SessionRenamed struct {
	Session    SessionID
	HasSession bool
	Name       string
}

// SessionsChanged reports that the server's session list moved
// (%sessions-changed): a session was created or destroyed anywhere on the
// server. Parsed — rather than ignored like the Swift original — because the
// daemon's structure mirror lists EVERY session on the server, and an
// outside new-session/kill-session would silently stale it otherwise.
type SessionsChanged struct{}

// UnlinkedWindowAdd reports a window created in a session other than the
// client's (%unlinked-window-add). Same reason as SessionsChanged: the
// mirror spans all sessions, but tmux scopes the linked %window-add to the
// client's own session.
type UnlinkedWindowAdd struct{ Window WindowID }

// UnlinkedWindowClose is UnlinkedWindowAdd's closing twin
// (%unlinked-window-close).
type UnlinkedWindowClose struct{ Window WindowID }

// UnlinkedWindowRenamed reports a rename in a session other than the
// client's (%unlinked-window-renamed). tmux emits it on automatic-rename
// churn too, which makes it the notification a plain split in a NON-attached
// session reliably produces alongside %window-pane-changed (a pure
// resize-pane there produces nothing — the mirror's one honest blind spot,
// documented in docs/tmux-host-design.md).
type UnlinkedWindowRenamed struct {
	Window WindowID
	Name   string
}

// PaneModeChanged reports a pane entering/leaving a tmux mode
// (%pane-mode-changed).
type PaneModeChanged struct {
	Pane PaneID
	Mode string
}

// WindowPaneChanged reports a window's active pane changing
// (%window-pane-changed). Parsed — rather than ignored like the Swift
// original — because the daemon's structure mirror carries the active-pane
// reading (SnapshotPane.Active), and an outside `select-pane` would silently
// stale it otherwise.
type WindowPaneChanged struct {
	Window WindowID
	Pane   PaneID
}

// SessionWindowChanged reports a session's current window changing
// (%session-window-changed). Parsed for the same reason WindowPaneChanged
// is: the daemon's structure mirror carries the active-WINDOW reading
// (SnapshotWindow.Active), and an outside `select-window` — which emits
// THIS, not %layout-change (no layout moved) — would silently stale it
// otherwise.
type SessionWindowChanged struct {
	Session SessionID
	Window  WindowID
}

// ClientDetached reports a client detaching from the server (tmux ≥ 3.2).
// Client is the same identity #{client_name} and list-clients use — how a
// session learns that the device owning its size went away, with no polling
// and no state of our own to keep in sync.
type ClientDetached struct{ Client string }

// Exit reports the control-mode client exiting (%exit). Reason is "" when
// tmux gave none (Swift: reason nil).
type Exit struct{ Reason string }

func (Output) notification()                {}
func (LayoutChange) notification()          {}
func (WindowAdd) notification()             {}
func (WindowClose) notification()           {}
func (WindowRenamed) notification()         {}
func (SessionChanged) notification()        {}
func (SessionRenamed) notification()        {}
func (SessionsChanged) notification()       {}
func (UnlinkedWindowAdd) notification()     {}
func (UnlinkedWindowClose) notification()   {}
func (UnlinkedWindowRenamed) notification() {}
func (PaneModeChanged) notification()       {}
func (WindowPaneChanged) notification()     {}
func (SessionWindowChanged) notification()  {}
func (ClientDetached) notification()        {}
func (Exit) notification()                  {}

// CommandResponse is one command's reply block from tmux. Output is the
// joined text between the %begin and %end/%error markers; IsError is true
// when the block terminated with %error.
type CommandResponse struct {
	CommandNumber int
	IsError       bool
	Output        string
}

// Session is one tmux session as `list-sessions` reports it. The id ($N) is
// stable for the session's lifetime — it survives renames, which is what
// makes it the right key for tracking a session across a refresh cycle.
type Session struct {
	ID   SessionID
	Name string
}

// Window is one tmux window as a listing reports it (Swift: TmuxWindow).
type Window struct {
	ID WindowID
	// Index is #{window_index} — the number tmux itself shows in
	// list-windows, targets with `select-window -t <index>`, and restores
	// order with via `move-window -t <index>`. -1 when parsed from a
	// listing that predates the field (Swift: nil).
	Index int
	Name  string
	Panes []Pane
	// Layout is #{window_layout}; "" when the listing didn't carry one.
	Layout string
	// IsActive is #{window_active} — the session's current window.
	IsActive bool
}

// IndexedName is tmux's own "index:name" label. Falls back to the bare name
// when the index is unknown so callers never render a stray separator.
func (w Window) IndexedName() string {
	if w.Index < 0 {
		return w.Name
	}
	return strconv.Itoa(w.Index) + ":" + w.Name
}

// Pane is one tmux pane as list-panes reports it.
type Pane struct {
	ID       PaneID
	Width    int
	Height   int
	X        int
	Y        int
	IsActive bool
	// IsZoomed is tmux's window_zoomed_flag. The flag is per-window, so
	// every pane in a zoomed window reports it; the zoomed pane itself is
	// the active one.
	IsZoomed bool
	// CurrentCommand is #{pane_current_command}; "" when unknown.
	CurrentCommand string
	// Title is #{pane_title}; "" when the listing didn't carry one.
	Title string
	// MouseAny: the program in this pane has mouse reporting on
	// (mouse_any_flag). In -CC control mode tmux does NOT pass the
	// program's mouse-enable sequence through to the client, so this flag
	// is how we learn to forward mouse events to the pane instead of
	// treating clicks as selection.
	MouseAny bool
	// MouseSGR: the pane requested SGR-encoded mouse reports
	// (mouse_sgr_flag); otherwise use the legacy X10/normal byte encoding.
	MouseSGR bool
	// AlternateOn: the program is drawing on the alternate screen
	// (alternate_on) — a fullscreen TUI. Like the mouse flags, control mode
	// swallows the program's ?1049h, so tmux's flag is the only way to know.
	AlternateOn bool
	// WindowID is the window this pane belongs to (window_id), populated by
	// session-wide `list-panes -s`. HasWindowID is false when the listing
	// was scoped to a single window (Swift: nil).
	WindowID    WindowID
	HasWindowID bool
	// InActiveWindow: this pane's window is the session's current window
	// (window_active). Lets a session-wide listing carve out the current
	// window's panes without relying on separately-refreshed window state.
	InActiveWindow bool
	// InMode: tmux has this pane in a mode — copy-mode being the one that
	// matters (pane_in_mode). A client can't tell from the output stream:
	// tmux draws the mode's UI as ordinary pane content. While it's set,
	// keys sent with send-keys are consumed by tmux's mode handler instead
	// of reaching the program, and the pane will not scroll on its own.
	InMode bool
}

// LayoutKind discriminates LayoutNode (Swift: the TmuxLayoutTree.Node enum
// cases leaf / hsplit / vsplit).
type LayoutKind int

const (
	// LayoutLeaf is a pane cell: WxH,X,Y,paneNumber.
	LayoutLeaf LayoutKind = iota
	// LayoutHSplit holds children side by side: WxH,X,Y{…}.
	LayoutHSplit
	// LayoutVSplit holds children stacked: WxH,X,Y[…].
	LayoutVSplit
)

// LayoutNode is one node of a tmux window-layout string (tmux
// layout-custom.c):
//
//	layout := checksum "," node
//	node   := leaf | hsplit | vsplit
//	leaf   := WxH,X,Y,paneNumber
//	hsplit := WxH,X,Y "{" node ("," node)+ "}"
//	vsplit := WxH,X,Y "[" node ("," node)+ "]"
//
// Siblings are separated by a one-cell divider, so a container's extent on
// its axis = sum(children) + (n-1).
//
// IMPORTANT: `select-layout` assigns the window's panes to leaves in tree
// (depth-first) order — the pane ids embedded in the string are ignored.
// Callers must order the window's panes to match LeafOrder before applying
// a layout.
type LayoutNode struct {
	Kind LayoutKind
	// ID is the pane number; meaningful for LayoutLeaf only.
	ID int
	W  int
	H  int
	X  int
	Y  int
	// Children is non-empty for splits, nil for leaves.
	Children []LayoutNode
}
