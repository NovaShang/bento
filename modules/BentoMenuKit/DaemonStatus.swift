import Foundation

/// DaemonStatus mirrors rpc.StatusResp returned by `bento status`.
/// Keep field names in sync with daemon/internal/rpc/types.go.
///
/// This is HOST-scoped, not product-scoped: there is one `bento-daemon` per
/// machine and both Mac apps read the same reply. It lives here (rather than
/// once per app) so a field the daemon grows can only be added in one place —
/// see docs/menubar-unification.md §3.
public struct DaemonStatus: Codable, Equatable, Sendable {
    public let version: String
    public let pid: Int
    public let uptimeSec: Int64
    public let relayURL: String?
    public let relayConnected: Bool
    public let daemonID: String?
    public let pairedDevices: Int

    /// Fingerprint of the binary the daemon process is actually running, and
    /// the hosted-agent counts a restart would kill. All optional on purpose:
    /// a daemon older than this feature omits them, and a failed decode would
    /// read as "daemon down" and trip the watchdog. A nil `exeHash` means
    /// "too old to say" — which the update check treats as stale, since a
    /// daemon that can't report its hash predates the app asking for one.
    public let exePath: String?
    public let exeHash: String?
    public let liveAgents: Int?
    public let busyAgents: Int?

    public init(
        version: String,
        pid: Int,
        uptimeSec: Int64,
        relayURL: String?,
        relayConnected: Bool,
        daemonID: String?,
        pairedDevices: Int,
        exePath: String? = nil,
        exeHash: String? = nil,
        liveAgents: Int? = nil,
        busyAgents: Int? = nil
    ) {
        self.version = version
        self.pid = pid
        self.uptimeSec = uptimeSec
        self.relayURL = relayURL
        self.relayConnected = relayConnected
        self.daemonID = daemonID
        self.pairedDevices = pairedDevices
        self.exePath = exePath
        self.exeHash = exeHash
        self.liveAgents = liveAgents
        self.busyAgents = busyAgents
    }

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

public struct PairedDevice: Codable, Identifiable, Equatable, Sendable {
    public let deviceID: String
    public let label: String?
    public let pairedAt: Int64
    public let keyFingerprint: String

    public init(deviceID: String, label: String?, pairedAt: Int64, keyFingerprint: String) {
        self.deviceID = deviceID
        self.label = label
        self.pairedAt = pairedAt
        self.keyFingerprint = keyFingerprint
    }

    public var id: String { deviceID }
    public var pairedDate: Date { Date(timeIntervalSince1970: TimeInterval(pairedAt)) }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case label
        case pairedAt = "paired_at"
        case keyFingerprint = "key_fingerprint"
    }
}
