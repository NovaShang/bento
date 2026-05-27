import Foundation

enum AuthMethod: Codable, Hashable {
    case password
    case privateKey(keyLabel: String)
}

/// Where the SSH bytes go on the wire. The transport is a property of the
/// Host so all downstream code (TerminalViewModel, TmuxLister, SessionManager)
/// stays transport-agnostic; only SSHService.connect branches on this.
enum HostTransport: Codable, Hashable {
    /// Plain TCP/SSH to host.hostname:port — what users add via the +
    /// menu's "Add SSH host…" entry.
    case directTCP

    /// Relay-routed to a Bento daemon paired earlier via 6-digit code. The
    /// carried fields are everything SSHService needs to instantiate
    /// BentoRelayClient without re-querying RelayDaemonStore.
    case relay(daemonID: String, hostFingerprint: String)
}

struct Host: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var hostname: String
    var port: UInt16
    var username: String
    var authMethod: AuthMethod
    var transport: HostTransport
    var lastConnected: Date?
    var lastInputMode: String?
    var unlockMacKeychain: Bool = false

    init(
        id: UUID = UUID(),
        name: String = "",
        hostname: String = "",
        port: UInt16 = 22,
        username: String = "root",
        authMethod: AuthMethod = .password,
        transport: HostTransport = .directTCP,
        lastConnected: Date? = nil,
        lastInputMode: String? = nil,
        unlockMacKeychain: Bool = false
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.transport = transport
        self.lastConnected = lastConnected
        self.lastInputMode = lastInputMode
        self.unlockMacKeychain = unlockMacKeychain
    }

    var displayName: String {
        name.isEmpty ? "\(username)@\(hostname)" : name
    }

    /// True if this Host is reached via the Bento relay rather than direct TCP.
    var isRelay: Bool {
        if case .relay = transport { return true }
        return false
    }

    /// Build a transient Host that represents a paired RelayDaemon. We never
    /// persist these — they're synthesized at navigation time so all the
    /// existing host-list / session / terminal UI works unchanged.
    static func fromRelayDaemon(_ d: RelayDaemon) -> Host {
        Host(
            id: d.id,
            name: d.displayName,
            // hostname is shown in the UI but never used for connect.
            hostname: "relay/\(String(d.daemonID.prefix(8)))…",
            port: 0,
            username: "bento",
            authMethod: .privateKey(keyLabel: d.deviceKeyLabel),
            transport: .relay(daemonID: d.daemonID, hostFingerprint: d.hostFingerprint),
            lastConnected: d.lastConnected
        )
    }

    // Lenient decoder — every field defaults if missing so adding new fields
    // never invalidates previously-saved JSON. When you add a new field to
    // this struct, default it here too.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.hostname = (try? c.decode(String.self, forKey: .hostname)) ?? ""
        self.port = (try? c.decode(UInt16.self, forKey: .port)) ?? 22
        self.username = (try? c.decode(String.self, forKey: .username)) ?? "root"
        self.authMethod = (try? c.decode(AuthMethod.self, forKey: .authMethod)) ?? .password
        self.transport = (try? c.decode(HostTransport.self, forKey: .transport)) ?? .directTCP
        self.lastConnected = try? c.decodeIfPresent(Date.self, forKey: .lastConnected)
        self.lastInputMode = try? c.decodeIfPresent(String.self, forKey: .lastInputMode)
        self.unlockMacKeychain = (try? c.decode(Bool.self, forKey: .unlockMacKeychain)) ?? false
    }
}
