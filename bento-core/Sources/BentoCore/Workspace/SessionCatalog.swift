import Foundation

/// One remembered conversation: WHO (preset), WHERE (cwd) and WHEN
/// (created / last active) — never the content. The conversation itself
/// lives in the agent's own storage and comes back through session/load
/// (docs/session-history-design.md, v3).
public struct CatalogEntry: Codable, Equatable, Identifiable, Sendable {
    public var acpSessionID: String
    public var title: String
    public var presetID: String
    public var cwd: String
    public var createdAt: Date
    public var lastActive: Date
    /// The agent GC'd the conversation (session/load failed): the entry
    /// stays visible but greyed, so the user learns why it won't open.
    public var expired: Bool = false

    public var id: String { acpSessionID }

    private enum CodingKeys: String, CodingKey {
        case acpSessionID, title, presetID, cwd, createdAt, lastActive, expired
    }

    public init(acpSessionID: String, title: String, presetID: String, cwd: String,
                createdAt: Date, lastActive: Date, expired: Bool = false) {
        self.acpSessionID = acpSessionID
        self.title = title
        self.presetID = presetID
        self.cwd = cwd
        self.createdAt = createdAt
        self.lastActive = lastActive
        self.expired = expired
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        acpSessionID = try c.decode(String.self, forKey: .acpSessionID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastActive = try c.decodeIfPresent(Date.self, forKey: .lastActive) ?? createdAt
        expired = try c.decodeIfPresent(Bool.self, forKey: .expired) ?? false
    }
}

/// The session catalog: entries keyed by ACP session id. Synced across
/// devices as a whole blob (statekv key "history-catalog"); conflicting
/// copies reconcile by UNION — per-entry, newer lastActive wins and
/// `expired` is sticky — so no device's catalog can silently drop another's
/// sessions the way last-write-wins would.
public struct SessionCatalog: Codable, Equatable {
    public private(set) var entries: [String: CatalogEntry] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([String: CatalogEntry].self, forKey: .entries) ?? [:]
    }

    /// Insert or refresh an entry. `lastActive` only ever moves forward;
    /// nil leaves the existing stamp alone (metadata-only refresh).
    public mutating func upsert(acpSessionID: String, title: String, presetID: String,
                                cwd: String, lastActive: Date? = nil) {
        guard !acpSessionID.isEmpty else { return }
        if var existing = entries[acpSessionID] {
            if !title.isEmpty { existing.title = title }
            if !presetID.isEmpty { existing.presetID = presetID }
            if !cwd.isEmpty { existing.cwd = cwd }
            if let lastActive, lastActive > existing.lastActive {
                existing.lastActive = lastActive
            }
            entries[acpSessionID] = existing
        } else {
            let now = Date()
            entries[acpSessionID] = CatalogEntry(
                acpSessionID: acpSessionID, title: title, presetID: presetID,
                cwd: cwd, createdAt: now, lastActive: lastActive ?? now)
        }
    }

    public mutating func markExpired(_ acpSessionID: String) {
        entries[acpSessionID]?.expired = true
    }

    @discardableResult
    public mutating func remove(_ acpSessionID: String) -> Bool {
        entries.removeValue(forKey: acpSessionID) != nil
    }

    /// Union merge with a remote copy: entries only accumulate; for a shared
    /// id the newer-lastActive side's fields win, createdAt keeps the oldest
    /// stamp, and expired stays true once either side saw it expire.
    public mutating func merge(_ remote: SessionCatalog) {
        for (id, theirs) in remote.entries {
            guard let ours = entries[id] else {
                entries[id] = theirs
                continue
            }
            var winner = theirs.lastActive > ours.lastActive ? theirs : ours
            winner.createdAt = min(ours.createdAt, theirs.createdAt)
            winner.expired = ours.expired || theirs.expired
            entries[id] = winner
        }
    }

    /// Entries filtered by directory, newest activity first. `cwd` nil = all;
    /// `subtree` widens an exact match to everything under the directory.
    public func list(cwd: String? = nil, subtree: Bool = false) -> [CatalogEntry] {
        var result = Array(entries.values)
        if let cwd, !cwd.isEmpty {
            let base = Self.normalize(cwd)
            result = result.filter { entry in
                let dir = Self.normalize(entry.cwd)
                if dir == base { return true }
                return subtree && dir.hasPrefix(base + "/")
            }
        }
        return result.sorted { $0.lastActive > $1.lastActive }
    }

    static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
