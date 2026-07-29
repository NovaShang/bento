import Foundation

public enum AuthMethod: Codable, Hashable, Sendable {
    case password
    case privateKey(keyLabel: String)
}

/// Where the SSH bytes go on the wire. The transport is a property of the
/// Host so all downstream code (TerminalViewModel, TmuxLister, SessionManager)
/// stays transport-agnostic; only SSHService.connect branches on this.
public enum HostTransport: Codable, Hashable, Sendable {
    /// Plain TCP/SSH to host.hostname:port — what users add via the +
    /// menu's "Add SSH host…" entry.
    case directTCP

    /// Relay-routed to a Bento daemon paired earlier via 6-digit code. The
    /// carried fields are everything SSHService needs to instantiate
    /// BentoRelayClient without re-querying RelayDaemonStore.
    /// `deviceID` is the opaque identifier the daemon assigned at pair
    /// time; iOS includes it in the device-attach challenge so the relay
    /// can pin our pubkey before bridging the stream.
    case relay(daemonID: String, hostFingerprint: String, deviceID: String)
}

public struct Host: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: UInt16
    public var username: String
    public var authMethod: AuthMethod
    public var transport: HostTransport
    public var lastConnected: Date?
    public var lastInputMode: String?
    public var unlockMacKeychain: Bool = false

    public init(
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

    public var displayName: String {
        name.isEmpty ? "\(username)@\(hostname)" : name
    }

    /// True if this Host is reached via the Bento relay rather than direct TCP.
    public var isRelay: Bool {
        if case .relay = transport { return true }
        return false
    }

    // Lenient decoder — every field defaults if missing so adding new fields
    // never invalidates previously-saved JSON. When you add a new field to
    // this struct, default it here too.
    public init(from decoder: Decoder) throws {
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
