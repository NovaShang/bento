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

    init(
        id: UUID = UUID(),
        name: String = "",
        hostname: String = "",
        port: UInt16 = 22,
        username: String = "root",
        authMethod: AuthMethod = .password,
        lastConnected: Date? = nil,
        lastInputMode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.lastConnected = lastConnected
        self.lastInputMode = lastInputMode
    }

    var displayName: String {
        name.isEmpty ? "\(username)@\(hostname)" : name
    }
}
