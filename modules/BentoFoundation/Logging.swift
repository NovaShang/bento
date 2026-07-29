import Foundation
import os

private let log = Logger(subsystem: "com.novashang.bento", category: "BentoCore")

/// Optional file sink for the core package's `dlog`. Core logs default to
/// os_log only, which is invisible in the app's pullable `debug.log` — set
/// this once at app start to mirror every core log line into the host app's
/// file logger so real-device incidents can be diagnosed from a single pull.
public nonisolated(unsafe) var coreDlogFileSink: (@Sendable (String) -> Void)?

/// Package-internal debug log.
public func dlog(_ s: String) {
    log.debug("\(s, privacy: .public)")
    coreDlogFileSink?(s)
}
