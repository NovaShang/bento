#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import Darwin

/// A local pseudo-terminal running a login shell, for the macOS terminal.
/// Spawns via `forkpty`, streams master-fd output to `onData`, accepts input via
/// `write`, and tracks window size via `resize`. This is the macOS counterpart
/// to iOS's SSH transport — the surface and tmux logic above it are identical.
public final class LocalPty {
    public var onData: ((Data) -> Void)?
    public var onExit: (() -> Void)?

    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?

    public init() {}

    /// Spawn the shell. `command` overrides the default login shell (e.g.
    /// `["/opt/homebrew/bin/tmux", "-CC", "new", "-A", "-s", "bento"]`).
    public func start(cols: Int, rows: Int, command: [String]? = nil) {
        var ws = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(cols, 1)),
                         ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = 0
        let pid = forkpty(&master, nil, nil, &ws)
        if pid < 0 { return }

        if pid == 0 {
            // Child: exec the shell, replacing this process image.
            let shellPath = command?.first
                ?? ProcessInfo.processInfo.environment["SHELL"]
                ?? "/bin/zsh"
            let args = command ?? [shellPath, "-l"]
            setenv("TERM", "xterm-256color", 1)
            var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
            argv.append(nil)
            execvp(shellPath, argv)
            _exit(1)
        }

        masterFD = master
        childPID = pid

        let src = DispatchSource.makeReadSource(
            fileDescriptor: master,
            queue: DispatchQueue.global(qos: .userInteractive)
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(self.masterFD, &buf, buf.count)
            if n > 0 {
                let data = Data(buf[0..<n])
                DispatchQueue.main.async { self.onData?(data) }
            } else {
                DispatchQueue.main.async { self.handleExit() }
            }
        }
        src.resume()
        readSource = src
    }

    public func write(_ data: Data) {
        guard masterFD >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(masterFD, base, raw.count)
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var ws = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(cols, 1)),
                         ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, UInt(TIOCSWINSZ), &ws)
    }

    public func stop() {
        readSource?.cancel()
        readSource = nil
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        if childPID > 0 { kill(childPID, SIGTERM); childPID = -1 }
    }

    private func handleExit() {
        stop()
        onExit?()
    }
}
#endif
