import Foundation
import SwiftUI

@MainActor
final class HostStore: ObservableObject {
    @Published var hosts: [Host] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("hosts.json")
    }()

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Host].self, from: data) else {
            return
        }
        hosts = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func add(_ host: Host) {
        hosts.append(host)
        save()
    }

    func update(_ host: Host) {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[idx] = host
        save()
    }

    func delete(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        save()
    }

    func markConnected(_ host: Host) {
        var updated = host
        updated.lastConnected = Date()
        update(updated)
    }
}
