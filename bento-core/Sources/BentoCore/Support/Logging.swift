import Foundation
import os

private let log = Logger(subsystem: "com.novashang.bento", category: "BentoCore")

/// Optional file sink for the core package's `dlog`. Core logs default to
/// os_log only, which is invisible in the app's pullable `debug.log` — set
/// this once at app start to mirror every core log line into the host app's
/// file logger so real-device incidents can be diagnosed from a single pull.
public nonisolated(unsafe) var coreDlogFileSink: (@Sendable (String) -> Void)?

/// Package-internal debug log.
func dlog(_ s: String) {
    log.debug("\(s, privacy: .public)")
    coreDlogFileSink?(s)
}

private let perf = Logger(subsystem: "com.novashang.bento", category: "perf")

/// TEMP startup-cost instrumentation (notice level so `log show` picks it up
/// without enabling debug logging).
func plog(_ s: String) {
    perf.notice("\(s, privacy: .public)")
}
