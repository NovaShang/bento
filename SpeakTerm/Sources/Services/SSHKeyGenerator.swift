import Foundation
import Crypto

/// Generates a new ed25519 SSH key pair and renders the public key in
/// OpenSSH's `authorized_keys` line format so the user can paste it onto
/// the server.
enum SSHKeyGenerator {
    struct GeneratedKey {
        /// 32-byte raw private key bytes — what Citadel's
        /// `Curve25519.Signing.PrivateKey(rawRepresentation:)` expects.
        let privateKeyData: Data
        /// `ssh-ed25519 AAAA... comment` — paste this into authorized_keys.
        let openSSHPublicKey: String
        /// Suggested keychain label.
        let label: String
    }

    /// Generate a new ed25519 key pair.
    /// - Parameter comment: Trailing comment in the public-key line. Defaults
    ///   to `speakterm@<host>` when called from a host edit screen.
    static func generate(comment: String) -> GeneratedKey {
        let priv = Curve25519.Signing.PrivateKey()
        let privBytes = priv.rawRepresentation
        let pubBytes = priv.publicKey.rawRepresentation

        let payload = encodeOpenSSHEd25519PublicKey(pubBytes: pubBytes)
        let base64 = payload.base64EncodedString()
        let openSSHLine = "ssh-ed25519 \(base64) \(comment)"

        // Stable label: short hash of the public key.
        let suffix = pubBytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        let label = "speakterm-\(suffix).pub"

        return GeneratedKey(
            privateKeyData: privBytes,
            openSSHPublicKey: openSSHLine,
            label: label
        )
    }

    /// Wire format for an OpenSSH ed25519 public key, suitable for base64
    /// encoding into the second field of an authorized_keys line.
    ///
    ///   string  "ssh-ed25519"
    ///   string  <32 bytes of public key>
    ///
    /// Each "string" is a 4-byte big-endian length followed by the bytes.
    private static func encodeOpenSSHEd25519PublicKey(pubBytes: Data) -> Data {
        var out = Data()
        out.append(lengthPrefixed("ssh-ed25519".data(using: .ascii)!))
        out.append(lengthPrefixed(pubBytes))
        return out
    }

    private static func lengthPrefixed(_ bytes: Data) -> Data {
        var out = Data(capacity: 4 + bytes.count)
        let len = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: len) { out.append(contentsOf: $0) }
        out.append(bytes)
        return out
    }
}
