import Foundation

/// The service endpoints every client speaks to, in ONE place.
///
/// They used to be seven string literals across six files (pairing, tunnel,
/// telemetry, the two ASR paths, both Mac apps' CLI defaults). That is how a
/// relay move becomes a scavenger hunt — and how the repo ended up deploying
/// one worker while every client talked to another. Add an endpoint here, not
/// at the call site.
public enum BentoEndpoints {
    /// Relay base URL. `relay.bentoai.dev` is a custom domain on the SAME
    /// worker the old `bento-relay-acp.styleshang.workers.dev` hostname
    /// serves, which stays live on purpose: already-paired daemons and
    /// installed apps keep their endpoint working through the transition
    /// (pairing identity is the daemon id + keys, not the URL).
    public static let relayBaseURL = "https://relay.bentoai.dev"

    /// Same origin over WSS — the tunnel and the realtime-ASR socket.
    public static var relayWebSocketBase: String {
        relayBaseURL.replacingOccurrences(of: "https://", with: "wss://")
                    .replacingOccurrences(of: "http://", with: "ws://")
    }
}
