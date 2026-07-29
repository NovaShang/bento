import Foundation

/// DaemonStatus mirrors rpc.StatusResp returned by `bento status`.
/// Keep field names in sync with desktop/internal/rpc/types.go.
struct DaemonStatus: Codable, Equatable {
    let version: String
    let pid: Int
    let uptimeSec: Int64
    let relayURL: String?
    let relayConnected: Bool
    let daemonID: String?
    let pairedDevices: Int

    /// Fingerprint of the binary the daemon process is actually running, and
    /// the hosted-agent counts a restart would kill. All optional on purpose:
    /// a daemon older than this feature omits them, and a failed decode would
    /// read as "daemon down" and trip the watchdog. A nil `exeHash` means
    /// "too old to say" — which the update check treats as stale, since a
    /// daemon that can't report its hash predates the app asking for one.
    let exePath: String?
    let exeHash: String?
    let liveAgents: Int?
    let busyAgents: Int?

    enum CodingKeys: String, CodingKey {
        case version
        case pid
        case uptimeSec = "uptime_sec"
        case relayURL = "relay_url"
        case relayConnected = "relay_connected"
        case daemonID = "daemon_id"
        case pairedDevices = "paired_devices"
        case exePath = "exe_path"
        case exeHash = "exe_hash"
        case liveAgents = "live_agents"
        case busyAgents = "busy_agents"
    }
}

struct PairedDevice: Codable, Identifiable, Equatable {
    let deviceID: String
    let label: String?
    let pairedAt: Int64
    let keyFingerprint: String

    var id: String { deviceID }
    var pairedDate: Date { Date(timeIntervalSince1970: TimeInterval(pairedAt)) }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case label
        case pairedAt = "paired_at"
        case keyFingerprint = "key_fingerprint"
    }
}

