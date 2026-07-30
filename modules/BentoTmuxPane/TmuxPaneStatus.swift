import Foundation
import SwiftTmux

/// One pane's polled reading: what the state-detection tick keys off, plus
/// the interaction mode a freshly-bound surface has no other way to learn.
///
/// The field-for-field twin of `BentoLink.AcpTmuxPaneStatus` — the daemon's
/// version of the same reading, for the day Bento Agents grows a terminal
/// pane. Two structs rather than one shared type because the two arrive by
/// completely different routes (a JSON op vs a local `list-panes`), and
/// making Bento Term link the ACP wire types to name its own pane status
/// would be the tail wagging the dog.
public struct TmuxPaneStatus: Sendable, Hashable {
    public var pane: TmuxPaneID
    public var command: String?
    public var title: String?
    /// `pane_current_path`, absolute. Flaps with every `cd`, so it is only
    /// ever meaningful fresh — never cached into structure.
    public var path: String?

    /// The pane is on the alternate screen: a fullscreen TUI owns it.
    ///
    /// A surface only ever sees output that arrives AFTER it binds, and
    /// control mode swallows the program's own `?1049h` — so one opened while
    /// a TUI was already running would otherwise look like a plain shell.
    public var alternateOn: Bool?
    /// `mouse_any_flag`: the program wants the mouse, so the wheel and clicks
    /// are ITS events, not the surface's scrollback and selection.
    public var mouseAny: Bool?
    /// `mouse_sgr_flag`: report in SGR encoding rather than legacy X10.
    public var mouseSGR: Bool?
    /// `pane_in_mode`: tmux has the pane in copy-mode and owns the viewport.
    public var inMode: Bool?

    public init(pane: TmuxPaneID, command: String? = nil, title: String? = nil,
                path: String? = nil, alternateOn: Bool? = nil,
                mouseAny: Bool? = nil, mouseSGR: Bool? = nil, inMode: Bool? = nil) {
        self.pane = pane
        self.command = command
        self.title = title
        self.path = path
        self.alternateOn = alternateOn
        self.mouseAny = mouseAny
        self.mouseSGR = mouseSGR
        self.inMode = inMode
    }
}
