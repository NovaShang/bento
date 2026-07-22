import Foundation
#if os(macOS)
import Security
#endif

/// Where `.apiKey` providers' pasted keys live. Keychain on the Mac (keys are
/// credentials, not preferences); an in-memory fake for tests. iOS clients
/// don't hold keys in v1 — spawn-time env injection happens on the host side
/// (see AgentWorkspaceStore.preset(forCommand:)), and the future daemon-side
/// connect engine will own keys for phone-driven connects.
public protocol ProviderKeyStoring: Sendable {
    func key(for providerID: String) -> String?
    func setKey(_ key: String, for providerID: String)
    func deleteKey(for providerID: String)
}

public final class InMemoryProviderKeyStore: ProviderKeyStoring, @unchecked Sendable {
    private var keys: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func key(for providerID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return keys[providerID]
    }

    public func setKey(_ key: String, for providerID: String) {
        lock.lock(); defer { lock.unlock() }
        keys[providerID] = key
    }

    public func deleteKey(for providerID: String) {
        lock.lock(); defer { lock.unlock() }
        keys[providerID] = nil
    }
}

#if os(macOS)
/// Generic-password Keychain items: service = one fixed identifier,
/// account = the provider id.
public struct KeychainProviderKeyStore: ProviderKeyStoring {
    static let service = "com.bento.acp.provider-key"

    public init() {}

    public func key(for providerID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: providerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setKey(_ key: String, for providerID: String) {
        deleteKey(for: providerID)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: providerID,
            kSecValueData as String: Data(key.utf8),
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    public func deleteKey(for providerID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: providerID,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif
