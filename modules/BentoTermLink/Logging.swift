import Foundation
import os

// Package-local logging, same subsystem the rest of the tree uses so a single
// `log stream --subsystem com.novashang.bento` still shows the whole picture.

private let log = Logger(subsystem: "com.novashang.bento", category: "TermLink")

/// Optional file sink. Package logs default to os_log only, which is invisible
/// in the app's pullable `debug.log` — set this once at app start so a real
/// device incident can be diagnosed from one file pull.
public nonisolated(unsafe) var termLinkDlogFileSink: (@Sendable (String) -> Void)?

func dlog(_ s: String) {
    log.debug("\(s, privacy: .public)")
    termLinkDlogFileSink?(s)
}
