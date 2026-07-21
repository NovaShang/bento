import SwiftUI

/// The four states the sidebar/status chrome cares about. Same semantics as
/// the terminal version's PaneState, but derived from the ACP turn lifecycle
/// instead of screen scraping: working = prompt in flight, awaiting = an
/// unanswered permission request, doneUnseen = turn finished while unfocused.
public enum SessionActivityState: String, Sendable {
    case idle
    case working
    case awaiting
    case doneUnseen

    public var color: Color {
        switch self {
        case .working: return Color(red: 0x5E / 255, green: 0xA7 / 255, blue: 0xF7 / 255)  // blue
        case .awaiting: return Color(red: 0xE8 / 255, green: 0xB4 / 255, blue: 0x5E / 255)  // amber
        case .doneUnseen: return Color(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255)  // bento green
        case .idle: return Color(white: 0.55)
        }
    }

    public var symbolName: String {
        switch self {
        case .working: return "play.circle.fill"
        case .awaiting: return "questionmark.circle.fill"
        case .doneUnseen: return "checkmark.circle.fill"
        case .idle: return "circle"
        }
    }
}
