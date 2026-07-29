import BentoFoundation
import BentoUI
import Foundation
import BentoLink

/// File source for iOS panes: reads the paired Mac's files through the SAME
/// relay transport the agent conversation rides (the daemon's bento-file ops —
/// stat / readbytes / listtree). No second socket, no re-pairing.
///
/// An `actor` so calls serialize: the transport keeps a single waiter slot per
/// file op, so overlapping stats/reads would collide. SmartPathResolver already
/// awaits sequentially; the actor makes that a guarantee.
public actor RelayFileSource: FilePreviewSource {
    /// Weak — the session owns the transport; when it tears down we degrade to
    /// an honest "not connected" instead of pinning a dead pipe.
    private weak var transport: AcpHostTransport?

    public init(transport: AcpHostTransport?) {
        self.transport = transport
    }

    private func require() throws -> AcpHostTransport {
        guard let transport else {
            throw FilePreviewError.unavailable("Not connected to the host.")
        }
        return transport
    }

    public func stat(path: String, cwd: String?) async throws -> (resolvedPath: String, stat: FilePreviewStat) {
        let s = try await require().stat(path: path, cwd: cwd)
        return (s.resolvedPath, FilePreviewStat(
            size: s.size,
            isDirectory: s.isDir,
            isRegular: s.isRegular,
            modified: s.mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(s.mtime)) : nil))
    }

    public func read(resolvedPath: String, maxBytes: Int) async throws -> Data {
        try await require().readBytes(path: resolvedPath, maxBytes: maxBytes)
    }

    public func listTree(root: String, request: TreeListRequest) async throws -> [FileTreeEntry] {
        let (_, entries) = try await require().listTree(
            root: root, cwd: nil,
            maxDepth: request.maxDepth, maxEntries: request.maxEntries,
            maxDirs: request.maxDirs, maxChildren: request.maxChildrenPerDir)
        return entries.map { FileTreeEntry(relPath: $0.rel, isDir: $0.dir) }
    }
}
