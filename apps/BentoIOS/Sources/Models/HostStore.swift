#if canImport(UIKit)
import Foundation
import BentoFoundation
import UIKit
import SwiftUI

@MainActor
public final class HostStore: ObservableObject {
    public static let shared = HostStore()

    @Published public var hosts: [BentoFoundation.Host] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("hosts.json")
    }()

    public init() {
        load()
    }

    public func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // No file yet (first launch) or unreadable — leave hosts empty
            // without touching disk. Don't back up; nothing to back up.
            return
        }

        do {
            hosts = try JSONDecoder().decode([BentoFoundation.Host].self, from: data)
        } catch {
            // Decode failed even with lenient init(from:). Preserve the
            // broken file under a timestamped name so no save() can clobber
            // the user's data, and surface the failure in logs.
            quarantineBrokenFile(reason: "hosts decode failed: \(error)")
        }
    }

    private func quarantineBrokenFile(reason: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = fileURL.deletingPathExtension()
            .appendingPathExtension("json.broken-\(stamp)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
            dlog("\(reason). Moved bad file to \(backup.lastPathComponent)")
        } catch {
            dlog("\(reason). Failed to move bad file: \(error)")
        }
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func add(_ host: BentoFoundation.Host) {
        hosts.append(host)
        save()
    }

    public func update(_ host: BentoFoundation.Host) {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[idx] = host
        save()
    }

    public func delete(_ host: BentoFoundation.Host) {
        hosts.removeAll { $0.id == host.id }
        save()
        SessionManager.shared.handleHostDeleted(host)
    }

    public func markConnected(_ host: BentoFoundation.Host) {
        var updated = host
        updated.lastConnected = Date()
        update(updated)
    }
}
#endif
