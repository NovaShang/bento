#if canImport(UIKit)
import CryptoKit
import Foundation

// Generating a key needs ed25519 and a wire format — not an SSH client. Living
// here rather than in BentoTermLink keeps Citadel (and 30k symbols of NIOSSH)
// out of Bento Agents, which shares this shell but never opens an SSH
// connection. CryptoKit rather than swift-crypto for the same reason: the raw
// 32 bytes are identical, so a key made here is readable by the Citadel side.
//
// The `SSHKey` wire format it calls lives in RelayPairingService — same module,
// same bytes, and pairing needed it first.

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
#endif
