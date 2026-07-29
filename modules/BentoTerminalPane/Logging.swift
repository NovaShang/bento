import Foundation
import os

// Package-local logging, copied from bento-terminal-core's
// TerminalViewModel.swift preamble (the view model itself stays behind — only
// its logging helpers are rendering-shared).

private let log = Logger(subsystem: "com.novashang.bento", category: "TerminalPane")

/// Shared by the path-detection pipeline (same subsystem/category the
/// term-era logger in FileTreeSearch.swift used, so `log stream` filters
/// keep working across both packages).
let pathPreviewLog = Logger(subsystem: "com.novashang.bento", category: "PathPreview")

/// Optional file sink for the package's `dlog`. Package logs default to
/// os_log only, which is invisible in the app's pullable `debug.log` — set
/// this once at app start (before any terminal work) to mirror every log
/// line into the host app's file logger so real-device incidents can be
/// diagnosed from a single file pull.
public nonisolated(unsafe) var paneDlogFileSink: (@Sendable (String) -> Void)?

/// Package-local debug log (the app's global `dlog` lives in the app target).
func dlog(_ s: String) {
    log.debug("\(s, privacy: .public)")
    paneDlogFileSink?(s)
}

// File diagnostics ordering surface-lifecycle vs seed-feed events (os_log
// debug doesn't reliably reach `log show`). Off by default; opt in per-run
// with BENTO_DIAG=1 to trace to /tmp/bento-diag.log.
let _diagEnabled = ProcessInfo.processInfo.environment["BENTO_DIAG"] == "1"
let _diagLock = NSLock()
func DIAG(_ s: @autoclosure () -> String) {
    guard _diagEnabled else { return }
    _diagLock.lock(); defer { _diagLock.unlock() }
    let line = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, s())
    let url = URL(fileURLWithPath: "/tmp/bento-diag.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.data(using: .utf8)?.write(to: url)
    }
}
