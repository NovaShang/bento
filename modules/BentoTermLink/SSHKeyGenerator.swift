import Foundation
import Crypto

/// Generates a new ed25519 SSH key pair and renders the public key in
/// OpenSSH's `authorized_keys` line format so the user can paste it onto
/// the server.
public enum SSHKeyGenerator {
    public struct GeneratedKey {
        /// 32-byte raw private key bytes — what Citadel's
        /// `Curve25519.Signing.PrivateKey(rawRepresentation:)` expects.
        public let privateKeyData: Data
        /// `ssh-ed25519 AAAA... comment` — paste this into authorized_keys.
        public let openSSHPublicKey: String
        /// Suggested keychain label.
        public let label: String
    }

    /// Generate a new ed25519 key pair.
    /// - Parameter comment: Trailing comment in the public-key line. Defaults
    ///   to `bento@<host>` when called from a host edit screen.
    public static func generate(comment: String) -> GeneratedKey {
        let priv = Curve25519.Signing.PrivateKey()
        let privBytes = priv.rawRepresentation
        let pubBytes = priv.publicKey.rawRepresentation

        // Wire format (string "ssh-ed25519" ‖ string <32 key bytes>) is shared
        // with the relay pairing path — see SSHKey in RelayPairingService.swift.
        let payload = SSHKey.ed25519WireFormat(rawPublicKey: pubBytes)
        let base64 = payload.base64EncodedString()
        let openSSHLine = "ssh-ed25519 \(base64) \(comment)"

        // Stable label: short hash of the public key.
        let suffix = pubBytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        let label = "bento-\(suffix).pub"

        return GeneratedKey(
            privateKeyData: privBytes,
            openSSHPublicKey: openSSHLine,
            label: label
        )
    }
}

/// OpenSSH public-key wire format: a sequence of length-prefixed strings.
/// Restored alongside the generator — it used to live in the relay pairing
/// service, but nothing about it is relay-specific; it is just how OpenSSH
/// spells an ed25519 public key.
enum SSHKey {
    static func ed25519WireFormat(rawPublicKey: Data) -> Data {
        var out = Data()
        out.append(sshString("ssh-ed25519"))
        out.append(sshString(rawPublicKey))
        return out
    }

    private static func sshString(_ s: String) -> Data {
        sshString(Data(s.utf8))
    }

    private static func sshString(_ d: Data) -> Data {
        var out = Data()
        var len = UInt32(d.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(d)
        return out
    }
}
