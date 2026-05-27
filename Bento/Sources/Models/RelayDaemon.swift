import Foundation

/// RelayDaemon is a paired Bento daemon reachable through the Cloudflare
/// relay. It is conceptually separate from a direct-SSH `Host`:
///   - identity is `daemonID`, not hostname/port
///   - the device key + host fingerprint were pinned at pairing time
///   - tapping it opens a relay-routed SSH session (no shared TCP path)
struct RelayDaemon: Identifiable, Codable, Hashable {
    var id: UUID
    /// daemon_id assigned by the relay (UUID string).
    var daemonID: String
    /// Optional user-friendly label ("Mac mini", "office iMac").
    var label: String
    /// SHA256:… fingerprint of the daemon's SSH host key, pinned on pairing.
    var hostFingerprint: String
    /// Keychain label for the iOS device's Ed25519 private key bound to
    /// this daemon. The actual key bytes live in KeychainService.
    var deviceKeyLabel: String
    /// device_id the daemon assigned on pairing (e.g. "dev-a7s38a7s"). The
    /// daemon's authorized_keys uses this as a stable identifier.
    var deviceID: String
    var pairedAt: Date
    var lastConnected: Date?

    var displayName: String {
        label.isEmpty ? "Mac · \(daemonID.prefix(8))…" : label
    }

    init(
        id: UUID = UUID(),
        daemonID: String,
        label: String = "",
        hostFingerprint: String,
        deviceKeyLabel: String,
        deviceID: String,
        pairedAt: Date = Date(),
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.daemonID = daemonID
        self.label = label
        self.hostFingerprint = hostFingerprint
        self.deviceKeyLabel = deviceKeyLabel
        self.deviceID = deviceID
        self.pairedAt = pairedAt
        self.lastConnected = lastConnected
    }

    // Lenient decoder — same pattern as Host.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.daemonID = (try? c.decode(String.self, forKey: .daemonID)) ?? ""
        self.label = (try? c.decode(String.self, forKey: .label)) ?? ""
        self.hostFingerprint = (try? c.decode(String.self, forKey: .hostFingerprint)) ?? ""
        self.deviceKeyLabel = (try? c.decode(String.self, forKey: .deviceKeyLabel)) ?? ""
        self.deviceID = (try? c.decode(String.self, forKey: .deviceID)) ?? ""
        self.pairedAt = (try? c.decode(Date.self, forKey: .pairedAt)) ?? Date()
        self.lastConnected = try? c.decodeIfPresent(Date.self, forKey: .lastConnected)
    }
}
