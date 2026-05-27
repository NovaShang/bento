import Foundation

enum AuthMethod: Codable, Hashable {
    case password
    case privateKey(keyLabel: String)
}

struct Host: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var hostname: String
    var port: UInt16
    var username: String
    var authMethod: AuthMethod
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
        self.lastConnected = lastConnected
        self.lastInputMode = lastInputMode
        self.unlockMacKeychain = unlockMacKeychain
    }

    var displayName: String {
        name.isEmpty ? "\(username)@\(hostname)" : name
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
        self.lastConnected = try? c.decodeIfPresent(Date.self, forKey: .lastConnected)
        self.lastInputMode = try? c.decodeIfPresent(String.self, forKey: .lastInputMode)
        self.unlockMacKeychain = (try? c.decode(Bool.self, forKey: .unlockMacKeychain)) ?? false
    }
}
