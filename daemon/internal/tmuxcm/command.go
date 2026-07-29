package tmuxcm

import (
	"strconv"
	"strings"
)

// Command is one tmux command in wire form, without the trailing newline
// (Swift: TmuxCommand.commandString). Build one with the constructor
// functions below — they carry the quoting rules — and hand it to
// ControlMode.Send, which appends the newline.
type Command string

func (c Command) String() string { return string(c) }

// SpawnCommand is how a new window/pane's program reaches tmux. Two creation
// seeds need two different escapings, and conflating them silently kills the
// pane:
//
//   - ShellSpawn — a user-typed command line ("Path & Command…").
//     Shell-quoted so tmux runs it via /bin/sh -c, i.e. pipes, &&, and globs
//     behave as the user typed them.
//   - TmuxSyntaxSpawn — a value ALREADY in tmux's own command syntax, the
//     canonical source being #{pane_start_command} ("Duplicate Current").
//     tmux stringifies a pane's argv with its own quoting — `sleep 300`
//     comes back as `"sleep 300"` — so it must be spliced back VERBATIM.
//     Wrapping that in our single quotes (as generic arg-escaping would)
//     makes the double-quotes literal; tmux then tries to exec a program
//     named `sleep 300`, exec fails, and the freshly-opened window vanishes
//     the instant it appears.
//
// The zero value means "no program" (plain shell), as does an empty string.
type SpawnCommand struct {
	text       string
	tmuxSyntax bool
}

// ShellSpawn wraps a user-typed command line (Swift: .shell).
func ShellSpawn(command string) SpawnCommand { return SpawnCommand{text: command} }

// TmuxSyntaxSpawn wraps a value already in tmux command syntax, e.g.
// #{pane_start_command} (Swift: .tmuxSyntax).
func TmuxSyntaxSpawn(command string) SpawnCommand {
	return SpawnCommand{text: command, tmuxSyntax: true}
}

// fragment is the wire form of the spawned program; "" when there is none.
func (c SpawnCommand) fragment() string {
	if c.text == "" {
		return ""
	}
	if c.tmuxSyntax {
		return c.text
	}
	return escapeArg(c.text)
}

// escapeArg quotes one argument for tmux's own command parser. tmux parses
// the control-mode command STRING itself (no shell tokenizes it for us), so
// its command-syntax metacharacters MUST force quoting:
//
//   - `#` begins a COMMENT — an unquoted `#{…}` format (e.g.
//     display-message -p #{pane_current_path}) is silently dropped and the
//     command returns its default. That fed garbage (tmux's default status
//     line) into "Duplicate Current" as the new pane's path+command, so it
//     exited on spawn and the window vanished.
//   - `{`/`}` open a brace command GROUP and `;` separates commands. A tmux
//     window-layout string carries braces (a horizontal split serializes as
//     `…{…}`), so an unquoted `set-option @bento_orig_layout …{…}` or
//     `select-layout -t @0 …{…}` parses the braces as a command group and
//     the WHOLE command fails with a syntax error — silently, over control
//     mode. (`[`/`]` from a vertical split aren't special to the parser,
//     but we quote them too — quoting a value is always safe.)
//
// CLI args escape all this only because the shell tokenizes them first;
// control mode does not. Quoting still lets display-message expand the
// format (see the -F '#{…}' lists).
func escapeArg(arg string) string {
	if strings.ContainsAny(arg, " '\"\\#{}[];") {
		return "'" + strings.ReplaceAll(arg, "'", `'\''`) + "'"
	}
	return arg
}

// --- Session ---

// NewSession builds `new-session -d`, optionally grouped with another
// session and/or named. Empty strings mean "not given".
func NewSession(name, groupWith string) Command {
	cmd := "new-session -d"
	if groupWith != "" {
		cmd += " -t " + groupWith
	}
	if name != "" {
		cmd += " -s " + escapeArg(name)
	}
	return Command(cmd)
}

// AttachSession builds `attach-session -t <name>`.
func AttachSession(name string) Command {
	return Command("attach-session -t " + escapeArg(name))
}

// ListSessions lists sessions as `$id:name` lines.
func ListSessions() Command {
	return Command("list-sessions -F '#{session_id}:#{session_name}'")
}

// RenameSession renames the client's currently-attached session (no -t →
// current).
func RenameSession(name string) Command {
	return Command("rename-session " + escapeArg(name))
}

// KillSession kills the named session, or the current one when name is "".
func KillSession(name string) Command {
	if name != "" {
		return Command("kill-session -t " + escapeArg(name))
	}
	return Command("kill-session")
}

// SwitchClient switches the attached control client to another session on
// the same server (tmux emits %session-changed, which re-syncs
// windows/panes).
func SwitchClient(session string) Command {
	return Command("switch-client -t " + escapeArg(session))
}

// --- Window ---

// NewWindow builds `new-window`. path/command seed the new window's working
// directory and program; empty strings mean "not given".
func NewWindow(target, name, path string, command SpawnCommand) Command {
	cmd := "new-window"
	if target != "" {
		cmd += " -t " + escapeArg(target)
	}
	if name != "" {
		cmd += " -n " + escapeArg(name)
	}
	if path != "" {
		cmd += " -c " + escapeArg(path)
	}
	if frag := command.fragment(); frag != "" {
		cmd += " " + frag
	}
	return Command(cmd)
}

// ListWindows lists windows. window_name is free text (titles like
// "host:~/dir" carry colons), so it MUST be the last field — otherwise a
// colon in the name shifts every later field and corrupts window_layout
// (which Bento saves for structure restore). The fixed fields
// (id/index/active/layout) have no colons and come first; ParseWindowList
// splits positionally.
func ListWindows(target string) Command {
	cmd := "list-windows -F '#{window_id}:#{window_index}:#{window_active}:#{window_layout}:#{window_name}'"
	if target != "" {
		cmd += " -t " + escapeArg(target)
	}
	return Command(cmd)
}

// SelectWindow builds `select-window -t @N`.
func SelectWindow(id WindowID) Command {
	return Command("select-window -t " + id.String())
}

// RenameWindow builds `rename-window -t @N <name>`.
func RenameWindow(id WindowID, name string) Command {
	return Command("rename-window -t " + id.String() + " " + escapeArg(name))
}

// KillWindow builds `kill-window -t @N`.
func KillWindow(id WindowID) Command {
	return Command("kill-window -t " + id.String())
}

// KillWindowTarget kills a window addressed by a raw tmux target (e.g.
// `sess:^` — the session's lowest-index window, the placeholder a fresh
// new-session spawns before a moved pane lands next to it).
func KillWindowTarget(target string) Command {
	return Command("kill-window -t " + escapeArg(target))
}

// MoveWindow moves a whole window into ANOTHER session (`move-window -d -t
// 'name:'` — the empty window part means "next free index"). Layout, panes,
// and window name travel intact; -d leaves it unselected at the destination.
func MoveWindow(id WindowID, targetSession string) Command {
	return Command("move-window -d -s " + id.String() + " -t " + escapeArg(targetSession+":"))
}

// --- Pane ---

// SplitWindow builds `split-window`. A nil target means the current pane;
// path overrides the inherited working directory ("" → tmux expands
// #{pane_current_path} against the target pane server-side, so we don't have
// to query the cwd ourselves); command runs a program instead of a shell.
func SplitWindow(target *PaneID, horizontal bool, path string, command SpawnCommand) Command {
	cmd := "split-window"
	if horizontal {
		cmd += " -h"
	} else {
		cmd += " -v"
	}
	if target != nil {
		cmd += " -t " + target.String()
	}
	if path != "" {
		cmd += " -c " + escapeArg(path)
	} else {
		cmd += " -c '#{pane_current_path}'"
	}
	if frag := command.fragment(); frag != "" {
		cmd += " " + frag
	}
	return Command(cmd)
}

// SelectPane builds `select-pane -t %N`.
func SelectPane(id PaneID) Command {
	return Command("select-pane -t " + id.String())
}

// SetPaneTitle sets a pane's title (pane_title), what the UI shows in the
// pane title bar and List rows. Note: a foreground TUI can overwrite this
// via OSC.
func SetPaneTitle(id PaneID, title string) Command {
	return Command("select-pane -t " + id.String() + " -T " + escapeArg(title))
}

// ListPanes lists panes. sessionWide lists every pane in the session (-s),
// not just the current window's — the cross-window model's primary listing;
// allWindows (-a) lists the whole server. window_id sits just before
// pane_title: the title (last field) may itself contain colons, so every
// fixed field must precede it.
func ListPanes(target string, allWindows, sessionWide bool) Command {
	cmd := "list-panes -F '#{pane_id}:#{pane_width}:#{pane_height}:#{pane_left}:#{pane_top}:#{pane_active}:#{window_zoomed_flag}:#{pane_current_command}:#{mouse_any_flag}:#{mouse_sgr_flag}:#{alternate_on}:#{window_active}:#{window_id}:#{pane_in_mode}:#{pane_title}'"
	switch {
	case allWindows:
		cmd += " -a"
	case sessionWide:
		cmd += " -s"
		if target != "" {
			cmd += " -t " + escapeArg(target)
		}
	case target != "":
		cmd += " -t " + escapeArg(target)
	}
	return Command(cmd)
}

// BreakPane breaks a pane out into its own window (`break-pane -d`): the
// pane and its process move unchanged; -d keeps the client's current window.
// An empty name deliberately adds no -n — naming a window is what makes tmux
// turn automatic-rename off for it, permanently. targetSession lands the
// window in ANOTHER session (`-t 'name:'` — the empty window part means
// "next free index"); pane ids are server-global, so the pane keeps its
// identity across the move.
func BreakPane(source PaneID, name, targetSession string) Command {
	cmd := "break-pane -d -s " + source.String()
	if name != "" {
		cmd += " -n " + escapeArg(name)
	}
	if targetSession != "" {
		cmd += " -t " + escapeArg(targetSession+":")
	}
	return Command(cmd)
}

// JoinPane moves a whole (single-pane) window's pane into the target pane's
// window (`join-pane -d`), splitting after the target. The list→tiled
// structure op: chain with each pane targeting the previous to rebuild exact
// order.
func JoinPane(source, target PaneID) Command {
	return Command("join-pane -d -s " + source.String() + " -t " + target.String())
}

// MovePane re-splits target and moves source into the new half
// (`move-pane`): the drop-zone drag's edge landing. Same operation as
// join-pane but legal WITHIN one window (join-pane refuses "can't join a
// pane to its own window" — move-pane exists for this, tmux ≥3.1).
// horizontal picks the split axis like split-window (-h = side by side, -v =
// stacked); before (-b) docks the moved pane on the left/top instead of the
// right/bottom. No -d: the pane the user dragged lands focused.
func MovePane(source, target PaneID, horizontal, before bool) Command {
	cmd := "move-pane"
	if horizontal {
		cmd += " -h"
	} else {
		cmd += " -v"
	}
	if before {
		cmd += " -b"
	}
	return Command(cmd + " -s " + source.String() + " -t " + target.String())
}

// JoinPaneToSession joins a pane into ANOTHER session's current window,
// splitting its active pane (`join-pane -d -s %5 -t 'name:'`). A source
// session left empty dies (verified live).
func JoinPaneToSession(source PaneID, session string) Command {
	return Command("join-pane -d -s " + source.String() + " -t " + escapeArg(session+":"))
}

// KillPane builds `kill-pane -t %N`.
func KillPane(id PaneID) Command {
	return Command("kill-pane -t " + id.String())
}

// SwapPaneUp swaps a pane with the previous pane in the window.
func SwapPaneUp(id PaneID) Command {
	return Command("swap-pane -U -t " + id.String())
}

// SwapPaneDown swaps a pane with the next pane in the window.
func SwapPaneDown(id PaneID) Command {
	return Command("swap-pane -D -t " + id.String())
}

// SwapPanes swaps two specific panes; used by drag-to-swap.
func SwapPanes(source, destination PaneID) Command {
	return Command("swap-pane -s " + source.String() + " -t " + destination.String())
}

// CapturePane captures a pane's text. lines <= 0 captures only the live
// visible screen (no scrollback) — what status detection wants, since stale
// prompt text in scrollback must not trigger a false "blocked". A positive
// lines captures that many lines up from the bottom (incl. scrollback).
// escapes keeps SGR color codes (off → clean text for matching).
func CapturePane(id PaneID, lines int, escapes bool) Command {
	// -p: print to stdout, -J: join wrapped lines, -e: SGR colors,
	// -S: start line (negative = from bottom). No -S → visible screen only.
	cmd := "capture-pane -t " + id.String() + " -p -J"
	if escapes {
		cmd += " -e"
	}
	if lines > 0 {
		cmd += " -S -" + strconv.Itoa(lines)
	}
	return Command(cmd)
}

// ResizePane builds `resize-pane -t %N -x W -y H`.
func ResizePane(id PaneID, width, height int) Command {
	return Command("resize-pane -t " + id.String() + " -x " + strconv.Itoa(width) + " -y " + strconv.Itoa(height))
}

// ZoomPane toggles a pane's zoom (`resize-pane -Z`).
func ZoomPane(id PaneID) Command {
	return Command("resize-pane -Z -t " + id.String())
}

// ResizePaneBy resizes a pane by amount cells. direction is one of "L",
// "R", "U", "D".
func ResizePaneBy(id PaneID, direction string, amount int) Command {
	return Command("resize-pane -t " + id.String() + " -" + direction + " " + strconv.Itoa(amount))
}

// --- Options ---

// SetSessionOption sets a session-scoped (user) option, e.g.
// @bento_orig_layout. Server-side storage that survives client disconnects
// and app restarts. Empty target means the current session.
func SetSessionOption(target, name, value string) Command {
	cmd := "set-option"
	if target != "" {
		cmd += " -t " + escapeArg(target)
	}
	return Command(cmd + " " + name + " " + escapeArg(value))
}

// SetWindowOption sets a WINDOW option (`set-option -w`), e.g. window-size.
// Window options are a separate namespace from session options — setting
// window-size without -w lands on the wrong table. A nil window means the
// current one.
func SetWindowOption(window *WindowID, name, value string) Command {
	cmd := "set-option -w"
	if window != nil {
		cmd += " -t " + window.String()
	}
	return Command(cmd + " " + name + " " + escapeArg(value))
}

// ResizeWindow builds `resize-window -x/-y`. Only takes effect under
// `window-size manual`; under the default `latest` the size is recomputed
// from whichever client was used most recently and this is immediately
// undone.
func ResizeWindow(window *WindowID, width, height int) Command {
	cmd := "resize-window"
	if window != nil {
		cmd += " -t " + window.String()
	}
	return Command(cmd + " -x " + strconv.Itoa(width) + " -y " + strconv.Itoa(height))
}

// ShowSessionOption reads a session-scoped option's value (-qv: value only,
// silent when unset).
func ShowSessionOption(target, name string) Command {
	cmd := "show-options -qv"
	if target != "" {
		cmd += " -t " + escapeArg(target)
	}
	return Command(cmd + " " + name)
}

// ShowWindowOption reads a WINDOW option's value (`show-options -wqv`), e.g.
// window-size. The sizing policy lives on the server, so this is how a
// client that just attached learns what another device already decided —
// reading it beats re-asserting a local preference, which is what let each
// attach clobber the other device's choice.
func ShowWindowOption(window *WindowID, name string) Command {
	cmd := "show-options -wqv"
	if window != nil {
		cmd += " -t " + window.String()
	}
	return Command(cmd + " " + name)
}

// --- Input ---

// SendKeys builds `send-keys -t %N [-l] <keys>`. literal (-l) sends the
// string as-is instead of interpreting key names.
func SendKeys(pane PaneID, keys string, literal bool) Command {
	cmd := "send-keys -t " + pane.String()
	if literal {
		cmd += " -l"
	}
	return Command(cmd + " " + escapeArg(keys))
}

// CopyModeCommand drives a pane that tmux has put in a mode (copy-mode).
// `send-keys -X` speaks copy-mode COMMANDS rather than keys, so it works
// whatever key table (vi / emacs) the user configured — sending a literal
// `q` or `Up` would depend on their bindings. count maps to -N, tmux's
// repeat (a count of 1 or less omits it).
//
// Bento does not implement copy-mode; this exists so a pane that entered it
// from OUTSIDE (another client, a script, the user's own binding) is not a
// frozen rectangle — it can still be scrolled and dismissed.
func CopyModeCommand(pane PaneID, command string, count int) Command {
	cmd := "send-keys -t " + pane.String() + " -X"
	if count > 1 {
		cmd += " -N " + strconv.Itoa(count)
	}
	return Command(cmd + " " + escapeArg(command))
}

// --- Info ---

// DisplayMessage expands a format server-side and prints it
// (`display-message -p`). A nil target means the current pane.
func DisplayMessage(format string, target *PaneID) Command {
	cmd := "display-message -p"
	if target != nil {
		cmd += " -t " + target.String()
	}
	return Command(cmd + " " + escapeArg(format))
}

// ListClients lists attached clients as `name:session` lines. The name is a
// tty path (it may contain colons), so split at the LAST colon.
func ListClients() Command {
	return Command("list-clients -F '#{client_name}:#{client_session}'")
}

// --- Layout ---

// SelectLayout applies a layout string to a window. The layout MUST go
// through escapeArg: a horizontal split serializes with `{…}`, and tmux's
// command parser reads an unquoted `{` as a brace command group — the whole
// command then fails with a silent syntax error over control mode.
func SelectLayout(window WindowID, layout string) Command {
	return Command("select-layout -t " + window.String() + " " + escapeArg(layout))
}

// SelectLayoutTarget is select-layout by raw target (e.g. `sess:` = that
// session's current window) — reclaims space before retrying a refused
// cross-session join.
func SelectLayoutTarget(target, layout string) Command {
	return Command("select-layout -t " + escapeArg(target) + " " + escapeArg(layout))
}

// --- Client ---

// RefreshClient declares the control client's size (`refresh-client -C`).
func RefreshClient(width, height int) Command {
	return Command("refresh-client -C " + strconv.Itoa(width) + "," + strconv.Itoa(height))
}

// --- Shell quoting & the launch line ---

// ShellQuoteArg single-quotes an argument for /bin/sh, escaping embedded
// quotes (Swift: TmuxShellQuote.arg). This is for the few strings typed into
// a real login shell (the `tmux -CC …` launch line), NOT for control-mode
// arguments — those go through escapeArg, which quotes for tmux's parser.
// The two are not interchangeable.
func ShellQuoteArg(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// ShellQuotePath quotes a directory path while leaving a leading `~` / `~/`
// OUTSIDE the quotes so the remote login shell expands it (Swift:
// TmuxShellQuote.path).
//
// When the home directory lives on a remote host, `~` cannot be resolved
// locally. Quoting the whole path (tilde included) makes the receiver see a
// literal `~/…`, which does not exist — tmux then falls back to its server
// cwd (/) and the agent silently starts in the wrong place. Everything after
// the tilde stays quoted, so spaces and shell metacharacters are still safe.
func ShellQuotePath(s string) string {
	if s == "~" {
		return "~"
	}
	if strings.HasPrefix(s, "~/") {
		return "~/" + ShellQuoteArg(s[2:])
	}
	return ShellQuoteArg(s)
}

// LaunchCommand builds the shell command that launches tmux in control mode
// (Swift: TmuxControlMode.launchCommand). Send the returned string (trailing
// newline included) to a shell to put it into -CC mode.
//
// path/command seed the session when -A has to CREATE it (they are ignored
// by tmux when it attaches to an existing one, which is the behavior you
// want — re-attaching must not relaunch the agent). Seeding here rather than
// by typing a `tmux new-session -d …` script into the shell beforehand is
// deliberate: that script raced the freshly spawned login shell's pty, and
// when it lost, -c was dropped silently and the agent came up in the wrong
// directory. This line is the same write the caller already has to make, so
// there is no second chance to lose.
func LaunchCommand(sessionName, groupWith, path, command string) string {
	// The shell — not tmux — expands `~`, and this string is read by the
	// shell, so quote it for the shell (see ShellQuotePath).
	dir := ""
	if path != "" {
		dir = " -c " + ShellQuotePath(path)
	}
	prog := ""
	if command != "" {
		prog = " " + ShellQuoteArg(command)
	}
	if groupWith != "" {
		name := sessionName
		if name == "" {
			name = groupWith + "-mobile"
		}
		// A grouped session shares the source's windows; seeding a directory
		// or program would be meaningless (and tmux rejects the combination),
		// so those are deliberately not applied here.
		return "tmux -CC new-session -A -s " + name + " -t " + groupWith + "\n"
	}
	if sessionName != "" {
		return "tmux -CC new-session -A -s " + sessionName + dir + prog + "\n"
	}
	return "tmux -CC new-session" + dir + prog + "\n"
}
