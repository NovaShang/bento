import Foundation
import os

/// File-based logger for debugging in simulator.
/// Logs are written to the app's Documents directory and can be read from the Mac.
final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()

    private let fileHandle: FileHandle?
    private let lock = OSAllocatedUnfairLock(initialState: ())
    let logFileURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFileURL = docs.appendingPathComponent("debug.log")

        // Truncate on launch
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()

        log("=== Bento Debug Log Started ===")
    }

    func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let entry = "[\(timestamp)] [\(fileName):\(line)] \(message)\n"

        lock.withLock { _ in
            if let data = entry.data(using: .utf8) {
                fileHandle?.write(data)
                // Also mirror to os_log for console
                os_log(.debug, "%{public}@", message)
            }
        }
    }

    deinit {
        fileHandle?.closeFile()
    }
}

/// Shorthand
func dlog(_ message: String, file: String = #fileID, line: Int = #line) {
    DebugLogger.shared.log(message, file: file, line: line)
}
