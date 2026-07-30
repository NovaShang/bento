import Foundation

/// The URL scheme each Mac product registers, and the launch ABI between a
/// resident menu process and the products it starts
/// (docs/menubar-unification.md §4.1).
///
/// A scheme is the right ABI here because it survives the app not running, the
/// app being anywhere in /Applications, and the app not being installed at all
/// — `NSWorkspace.open` launches it or fails harmlessly, with no stale
/// absolute path to go bad.
public enum BentoURLScheme: String, CaseIterable, Sendable {
    /// Bento ACP (apps/BentoMac).
    case acp = "bento-acp"
    /// Bento Term (apps/BentoTermMac).
    case term = "bento-term"

    /// The noun this product's own docs use for a named thing to open.
    /// Both nouns are accepted for both schemes (below) — a caller that says
    /// "session" to Bento ACP means the same thing a user does.
    public var sessionNoun: String {
        switch self {
        case .acp: return "workspace"
        case .term: return "session"
        }
    }
}

/// What an incoming URL asks the app to do. Deliberately tiny: everything a
/// URL can trigger is something the user could do by clicking the app, so an
/// untrusted string from `open(1)` or another process can't reach anything
/// destructive.
public enum BentoURLRoute: Equatable, Sendable {
    /// `bento-acp://` or `bento-acp://open` — launch/activate, show the window.
    case open
    /// `bento-acp://workspace/<name>` / `bento-term://session/<name>` —
    /// focus that named thing, opening the window if there isn't one.
    case openSession(name: String)
}

public enum BentoURLRouter {
    /// Parse an incoming URL into a route, or nil if it isn't ours or isn't
    /// one of the two things we handle.
    ///
    /// Nil is the whole safety story: callers do nothing with nil, so an
    /// unknown host, an empty name, a foreign scheme or a malformed URL is a
    /// no-op rather than a crash or a guess.
    public static func route(_ url: URL, scheme: BentoURLScheme) -> BentoURLRoute? {
        // Schemes are case-insensitive per RFC 3986; Launch Services will hand
        // us whatever the caller typed.
        guard let incoming = url.scheme?.lowercased(), incoming == scheme.rawValue else {
            return nil
        }

        // `bento-acp://workspace/foo` puts "workspace" in host; the opaque
        // `bento-acp:workspace/foo` puts it in path. Accept both rather than
        // making the user care which they typed.
        var segments: [String] = []
        if let host = url.host, !host.isEmpty { segments.append(host) }
        segments += url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard let verb = segments.first?.lowercased() else { return .open }

        switch verb {
        case "open":
            return .open
        // Both nouns for both schemes: a link that says "session" to the ACP
        // app names the same thing its own menu calls a workspace.
        case "workspace", "workspaces", "session", "sessions":
            guard let raw = segments.dropFirst().first else { return nil }
            let name = (raw.removingPercentEncoding ?? raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return .openSession(name: name)
        default:
            return nil
        }
    }

    /// Build the URL that asks `scheme`'s app to focus a named session.
    /// The inverse of `route`, so a later stage's menu can construct links
    /// without re-deriving the format.
    public static func url(for name: String, scheme: BentoURLScheme) -> URL? {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = scheme.sessionNoun
        // `path` must start with "/" when a host is present; URLComponents
        // percent-encodes the name for us.
        components.path = "/" + name
        return components.url
    }
}
