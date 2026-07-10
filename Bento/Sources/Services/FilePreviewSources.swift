import Foundation
import BentoTerminalCore
import Citadel
import NIOCore

// MARK: - Direct SSH (Citadel SFTP)

/// File source for direct-TCP SSH hosts: opens one SFTP subsystem channel on
/// the EXISTING Citadel connection (no re-auth, no second socket) and reuses
/// it across previews. Any standard sshd serves this — plain SSH keeps full
/// features, per the transport-independence rule.
actor CitadelSFTPFileSource: FilePreviewSource {
    /// Citadel's SSHClient predates Sendable; it's the same instance
    /// SSHService already drives from multiple tasks, and openSFTP() is
    /// internally thread-safe (NIO event loop), so region-checking is noise.
    private nonisolated(unsafe) let client: SSHClient
    private var sftp: SFTPClient?
    private var home: String?

    init(client: SSHClient) {
        self.client = client
    }

    private func session() async throws -> SFTPClient {
        if let sftp, sftp.isActive { return sftp }
        let fresh = try await client.openSFTP()
        sftp = fresh
        return fresh
    }

    func stat(path: String, cwd: String?) async throws -> (resolvedPath: String, stat: FilePreviewStat) {
        let sftp = try await session()
        if home == nil {
            // The SFTP session starts in the login home — realpath(".") = home,
            // which unlocks `~/…` resolution.
            home = try? await sftp.getRealPath(atPath: ".")
        }
        var resolved = try FilePathResolver.resolve(path: path, cwd: cwd, home: home)
        if !resolved.hasPrefix("/") {
            resolved = try await sftp.getRealPath(atPath: resolved)   // "~user/…" etc.
        }
        do {
            let attrs = try await sftp.getAttributes(at: resolved)
            let type = (attrs.permissions ?? 0o100000) & 0o170000
            return (resolved, FilePreviewStat(
                size: Int64(attrs.size ?? 0),
                isDirectory: type == 0o040000,
                isRegular: type == 0o100000,
                modified: attrs.accessModificationTime?.modificationTime))
        } catch {
            throw FilePreviewError.notFound(resolved)
        }
    }

    func read(resolvedPath: String, maxBytes: Int) async throws -> Data {
        let sftp = try await session()
        let length = UInt32(clamping: maxBytes)
        return try await sftp.withFile(filePath: resolvedPath, flags: .read) { file in
            var buf = try await file.read(from: 0, length: length)
            return buf.readData(length: buf.readableBytes) ?? Data()
        }
    }
}

// MARK: - Relay (bento-file subsystem on the daemon)

/// File source for relay hosts: one-shot `bento-file` subsystem channels over
/// the SAME SSH-over-WSS session the shell rides — no second socket, no
/// re-pairing. The daemon resolves `~`/relative paths server-side and streams
/// back a JSON header + raw bytes (see desktop/internal/sshserver/filefetch.go).
final class RelayFileSource: FilePreviewSource, @unchecked Sendable {
    private weak var client: BentoRelayClient?

    init(client: BentoRelayClient) {
        self.client = client
    }

    func stat(path: String, cwd: String?) async throws -> (resolvedPath: String, stat: FilePreviewStat) {
        let (header, _) = try await fetch(op: "stat", path: path, cwd: cwd, maxBytes: 0)
        return (header.path, header.previewStat)
    }

    func read(resolvedPath: String, maxBytes: Int) async throws -> Data {
        let (_, data) = try await fetch(op: "read", path: resolvedPath, cwd: nil, maxBytes: maxBytes)
        return data
    }

    private func fetch(op: String, path: String, cwd: String?, maxBytes: Int) async throws
        -> (BentoFileHeader, Data) {
        guard let client else {
            throw FilePreviewError.unavailable("Connection is gone.")
        }
        let response = try await client.fetchFile(
            .init(op: op, path: path, cwd: cwd, maxBytes: maxBytes))
        guard response.header.ok else {
            let msg = response.header.error ?? "unknown error"
            if msg.contains("no such file") || msg.contains("not exist") {
                throw FilePreviewError.notFound(path)
            }
            throw FilePreviewError.unavailable(msg)
        }
        return (response.header, response.data)
    }
}

/// Wire types for the daemon's `bento-file` subsystem.
struct BentoFileRequest: Encodable {
    let op: String            // "stat" | "read"
    let path: String
    let cwd: String?
    let maxBytes: Int

    enum CodingKeys: String, CodingKey {
        case op, path, cwd
        case maxBytes = "max_bytes"
    }
}

struct BentoFileHeader: Decodable {
    let ok: Bool
    let error: String?
    let path: String
    let size: Int64
    let isDir: Bool
    let isRegular: Bool
    let mtime: Int64
    let dataLen: Int64

    enum CodingKeys: String, CodingKey {
        case ok, error, path, size, mtime
        case isDir = "is_dir"
        case isRegular = "is_regular"
        case dataLen = "data_len"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        size = (try? c.decode(Int64.self, forKey: .size)) ?? 0
        isDir = (try? c.decode(Bool.self, forKey: .isDir)) ?? false
        isRegular = (try? c.decode(Bool.self, forKey: .isRegular)) ?? false
        mtime = (try? c.decode(Int64.self, forKey: .mtime)) ?? 0
        dataLen = (try? c.decode(Int64.self, forKey: .dataLen)) ?? 0
    }

    var previewStat: FilePreviewStat {
        FilePreviewStat(size: size, isDirectory: isDir, isRegular: isRegular,
                        modified: mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil)
    }
}
