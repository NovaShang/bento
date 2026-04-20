import Foundation
import os

/// Parses and manages the tmux control mode (-CC) protocol.
///
/// Commands are sent as plain text lines via stdin. Responses come back
/// wrapped in `%begin`/`%end` blocks with tmux-assigned command numbers.
/// We use a FIFO queue to match responses to awaiting callers, since
/// tmux's command numbers are globally incremented (not per-client).
final class TmuxControlModeService: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.speakterm", category: "tmux")

    /// Called for each parsed notification (output, layout changes, etc.)
    var onNotification: (@Sendable (TmuxNotification) -> Void)?

    /// Called to send raw data to the SSH channel
    var sendToSSH: (@Sendable (String) -> Void)?

    // Response tracking: FIFO queue of continuations
    private let responseLock = OSAllocatedUnfairLock(initialState: ResponseState())

    private struct ResponseState {
        var pendingQueue: [CheckedContinuation<TmuxCommandResponse, Never>] = []
        var currentBlock: CommandBlock?
        var pendingFireAndForget: Int = 0
    }

    private struct CommandBlock {
        let commandNumber: Int
        var lines: [String] = []
    }

    // Line buffer for incoming data
    private let bufferLock = OSAllocatedUnfairLock(initialState: Data())

    // Input batching: collect keystrokes per pane and flush after 16ms
    private struct InputBatchState {
        var buffers: [TmuxPaneID: Data] = [:]
        var scheduledFlush: [TmuxPaneID: Bool] = [:]
    }
    private let inputBatchLock = OSAllocatedUnfairLock(initialState: InputBatchState())

    // MARK: - Public API

    /// Start tmux control mode on the remote host.
    func launchCommand(sessionName: String? = nil, groupWith: String? = nil) -> String {
        if let groupWith {
            let name = sessionName ?? "\(groupWith)-mobile"
            return "tmux -CC new-session -A -s \(name) -t \(groupWith)\n"
        } else if let sessionName {
            return "tmux -CC new-session -A -s \(sessionName)\n"
        } else {
            return "tmux -CC new-session\n"
        }
    }

    /// Feed raw bytes from SSH into the parser.
    func feedData(_ data: Data) {
        bufferLock.withLock { buffer in
            buffer.append(data)
        }
        processLines()
    }

    /// Send a tmux command and wait for the response.
    func send(_ command: TmuxCommand) async -> TmuxCommandResponse {
        return await withCheckedContinuation { continuation in
            responseLock.withLock { state in
                state.pendingQueue.append(continuation)
            }
            let cmdString = command.commandString + "\n"
            dlog("tmux send: \(cmdString.trimmingCharacters(in: .whitespacesAndNewlines))")
            sendToSSH?(cmdString)
        }
    }

    /// Send a tmux command without waiting for response (fire-and-forget).
    func sendFireAndForget(_ command: TmuxCommand) {
        let cmdString = command.commandString + "\n"
        dlog("tmux send (fire): \(cmdString.trimmingCharacters(in: .whitespacesAndNewlines))")
        responseLock.withLock { state in
            state.pendingFireAndForget += 1
        }
        sendToSSH?(cmdString)
    }

    /// Send raw keys to a specific pane.
    func sendKeys(to pane: TmuxPaneID, keys: String) {
        sendFireAndForget(.sendKeys(pane: pane, keys: keys))
    }

    /// Send raw bytes to a pane (for terminal input).
    /// Uses `send-keys -H` (hex mode) to safely transmit any byte including
    /// control characters like \r, \n, \x1b without breaking the tmux protocol.
    /// Batches input with a 16ms debounce window per pane for performance.
    func sendData(to pane: TmuxPaneID, data: Data) {
        let needsSchedule = inputBatchLock.withLock { state -> Bool in
            state.buffers[pane, default: Data()].append(data)
            if state.scheduledFlush[pane] == true {
                return false // already scheduled
            }
            state.scheduledFlush[pane] = true
            return true
        }

        if needsSchedule {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
                self?.flushInputBuffer(for: pane)
            }
        }
    }

    private func flushInputBuffer(for pane: TmuxPaneID) {
        let data = inputBatchLock.withLock { state -> Data? in
            state.scheduledFlush[pane] = false
            guard let buffer = state.buffers.removeValue(forKey: pane), !buffer.isEmpty else {
                return nil
            }
            return buffer
        }

        guard let data else { return }
        let hexBytes = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        let cmd = "send-keys -t \(pane) -H \(hexBytes)\n"
        sendToSSH?(cmd)
    }

    // MARK: - Line Processing

    private func processLines() {
        while true {
            let maybeLine = bufferLock.withLock { (buffer: inout Data) -> String? in
                guard let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) else {
                    return nil
                }
                var lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = buffer[(newlineIndex + 1)...]
                if let last = lineData.last, last == UInt8(ascii: "\r") {
                    lineData = lineData.dropLast()
                }
                // Try UTF-8 first; fall back to Latin-1 (which never fails) for
                // incomplete multi-byte sequences so lines are never silently dropped.
                if let str = String(data: lineData, encoding: .utf8) {
                    return str
                }
                return String(data: lineData, encoding: .isoLatin1)
            }

            guard var line = maybeLine else { break }

            // tmux -CC sends DCS \033P1000p before entering control mode.
            // Strip everything before % notification if present.
            let prefixes = ["%begin ", "%output ", "%end ", "%error ",
                            "%session", "%layout-change ", "%window-", "%pane-",
                            "%exit", "%unlinked-", "%client-", "%config-"]
            let range: Range<String.Index>? = prefixes.lazy.compactMap { line.range(of: $0) }.first
            if let range {
                if range.lowerBound != line.startIndex {
                    // There's junk before the % notification — strip it
                    line = String(line[range.lowerBound...])
                }
            }

            parseLine(line)
        }
    }

    private func parseLine(_ line: String) {
        let inBlock = responseLock.withLock { $0.currentBlock != nil }

        if inBlock {
            if line.hasPrefix("%end ") || line.hasPrefix("%error ") {
                finishBlock(line: line, isError: line.hasPrefix("%error"))
            } else {
                responseLock.withLock { state in
                    state.currentBlock?.lines.append(line)
                }
            }
            return
        }

        // Log non-output notifications for debugging
        if !line.hasPrefix("%output ") {
            dlog("tmux recv: \(line)")
        }

        // Parse notification lines
        if line.hasPrefix("%output ") {
            parseOutput(line)
        } else if line.hasPrefix("%begin ") {
            parseBegin(line)
        } else if line.hasPrefix("%layout-change ") {
            parseLayoutChange(line)
        } else if line.hasPrefix("%window-add ") {
            parseWindowAdd(line)
        } else if line.hasPrefix("%window-close ") {
            parseWindowClose(line)
        } else if line.hasPrefix("%window-renamed ") {
            parseWindowRenamed(line)
        } else if line.hasPrefix("%session-changed ") {
            parseSessionChanged(line)
        } else if line.hasPrefix("%session-renamed ") {
            parseSessionRenamed(line)
        } else if line.hasPrefix("%pane-mode-changed ") {
            parsePaneModeChanged(line)
        } else if line.hasPrefix("%exit") {
            let reason = line.count > 5 ? String(line.dropFirst(6)) : nil
            onNotification?(.exit(reason: reason))
        } else if line.hasPrefix("%sessions-changed") ||
                  line.hasPrefix("%unlinked-window-add") ||
                  line.hasPrefix("%unlinked-window-close") ||
                  line.hasPrefix("%window-pane-changed") ||
                  line.hasPrefix("%client-session-changed") ||
                  line.hasPrefix("%config-error") {
            // Known notifications that we intentionally ignore
            dlog("tmux ignored notification: \(line.prefix(60))")
        } else {
            // Ignore unrecognized lines (e.g. DCS sequences, echo)
        }
    }

    // MARK: - Notification Parsers

    private func parseOutput(_ line: String) {
        // Format: %output %<id> <escaped_data>
        let rest = String(line.dropFirst(8)) // drop "%output "
        guard let spaceIdx = rest.firstIndex(of: " ") else { return }
        let paneStr = String(rest[rest.startIndex..<spaceIdx])
        let escapedData = String(rest[rest.index(after: spaceIdx)...])

        guard let paneID = TmuxPaneID(string: paneStr) else { return }
        let data = unescapeTmuxOutput(escapedData)
        onNotification?(.output(pane: paneID, data: data))
    }

    private func parseBegin(_ line: String) {
        // Format: %begin <timestamp> <cmdnum> <flags>
        let parts = line.split(separator: " ")
        guard parts.count >= 3, let cmdNum = Int(parts[2]) else {
            dlog("Invalid %begin: \(line)")
            return
        }
        responseLock.withLock { state in
            state.currentBlock = CommandBlock(commandNumber: cmdNum)
        }
    }

    private func finishBlock(line: String, isError: Bool) {
        let (block, continuation) = responseLock.withLock { state -> (CommandBlock?, CheckedContinuation<TmuxCommandResponse, Never>?) in
            guard let block = state.currentBlock else { return (nil, nil) }
            state.currentBlock = nil

            // If this response belongs to a fire-and-forget command, discard it
            if state.pendingFireAndForget > 0 {
                state.pendingFireAndForget -= 1
                return (block, nil)
            }

            // FIFO: pop the first pending continuation
            let cont = state.pendingQueue.isEmpty ? nil : state.pendingQueue.removeFirst()
            return (block, cont)
        }

        guard let block else { return }

        let response = TmuxCommandResponse(
            commandNumber: block.commandNumber,
            isError: isError,
            output: block.lines.joined(separator: "\n")
        )

        dlog("tmux response #\(block.commandNumber) (error=\(isError)): \(response.output.prefix(200))")

        if let continuation {
            continuation.resume(returning: response)
        }
    }

    private func parseLayoutChange(_ line: String) {
        // Format: %layout-change @0 <layout> [<visible_layout> <flags>]
        // Newer tmux may include extra fields after the layout string; ignore them.
        let parts = line.split(separator: " ")
        guard parts.count >= 3,
              let winID = TmuxWindowID(string: String(parts[1])) else { return }
        let layout = String(parts[2])
        onNotification?(.layoutChange(window: winID, layout: layout))
    }

    private func parseWindowAdd(_ line: String) {
        let parts = line.split(separator: " ")
        guard parts.count >= 2,
              let winID = TmuxWindowID(string: String(parts[1])) else { return }
        onNotification?(.windowAdd(window: winID))
    }

    private func parseWindowClose(_ line: String) {
        let parts = line.split(separator: " ")
        guard parts.count >= 2,
              let winID = TmuxWindowID(string: String(parts[1])) else { return }
        onNotification?(.windowClose(window: winID))
    }

    private func parseWindowRenamed(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 3,
              let winID = TmuxWindowID(string: String(parts[1])) else { return }
        let name = String(parts[2])
        onNotification?(.windowRenamed(window: winID, name: name))
    }

    private func parseSessionChanged(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 3,
              let sesID = TmuxSessionID(string: String(parts[1])) else { return }
        let name = String(parts[2])
        onNotification?(.sessionChanged(session: sesID, name: name))
    }

    private func parseSessionRenamed(_ line: String) {
        let rest = String(line.dropFirst(18)) // drop "%session-renamed "
        onNotification?(.sessionRenamed(name: rest))
    }

    private func parsePaneModeChanged(_ line: String) {
        let parts = line.split(separator: " ")
        guard parts.count >= 2,
              let paneID = TmuxPaneID(string: String(parts[1])) else { return }
        let mode = parts.count >= 3 ? String(parts[2]) : ""
        onNotification?(.paneModeChanged(pane: paneID, mode: mode))
    }

    // MARK: - Output Unescaping

    /// Unescape tmux control mode output.
    /// Characters with ASCII < 32 and backslash are escaped as \XXX (3 octal digits).
    /// Operates on raw UTF-8 bytes for performance on large TUI output.
    private func unescapeTmuxOutput(_ escaped: String) -> Data {
        let backslash = UInt8(ascii: "\\")
        let zero = UInt8(ascii: "0")

        return escaped.utf8.withContiguousStorageIfAvailable { buf -> Data in
            unescapeBytes(buf, backslash: backslash, asciiZero: zero)
        } ?? {
            // Fallback for non-contiguous storage
            let bytes = Array(escaped.utf8)
            return bytes.withUnsafeBufferPointer { buf in
                unescapeBytes(buf, backslash: backslash, asciiZero: zero)
            }
        }()
    }

    private func unescapeBytes(_ buf: UnsafeBufferPointer<UInt8>, backslash: UInt8, asciiZero: UInt8) -> Data {
        var result = Data(capacity: buf.count)
        var i = 0
        let count = buf.count

        while i < count {
            let byte = buf[i]
            if byte == backslash, i + 3 < count {
                let d0 = buf[i + 1]
                let d1 = buf[i + 2]
                let d2 = buf[i + 3]
                // Check all three are octal digits (0-7)
                if d0 >= asciiZero, d0 <= asciiZero + 7,
                   d1 >= asciiZero, d1 <= asciiZero + 7,
                   d2 >= asciiZero, d2 <= asciiZero + 7 {
                    let value = (d0 - asciiZero) &* 64 + (d1 - asciiZero) &* 8 + (d2 - asciiZero)
                    result.append(value)
                    i += 4
                    continue
                }
            }
            result.append(byte)
            i += 1
        }

        return result
    }

    // MARK: - Pane List Parsing

    /// Parse the output of list-panes command into Pane models.
    func parsePaneList(_ output: String) -> [Pane] {
        // Format: %<id>:<width>:<height>:<left>:<top>:<active>:<command>:<title>
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 7)
            guard parts.count >= 6,
                  let paneID = TmuxPaneID(string: String(parts[0])),
                  let width = Int(parts[1]),
                  let height = Int(parts[2]),
                  let x = Int(parts[3]),
                  let y = Int(parts[4]) else {
                return nil
            }
            let isActive = parts[5] == "1"
            let command = parts.count > 6 ? String(parts[6]) : nil
            let title = parts.count > 7 ? String(parts[7]) : nil

            return Pane(
                id: paneID,
                width: width,
                height: height,
                x: x,
                y: y,
                isActive: isActive,
                currentCommand: command,
                title: title
            )
        }
    }

    /// Parse the output of list-windows command into TmuxWindow models.
    func parseWindowList(_ output: String) -> [TmuxWindow] {
        // Format: @<id>:<name>:<layout>:<active>
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 3)
            guard parts.count >= 2,
                  let winID = TmuxWindowID(string: String(parts[0])) else {
                return nil
            }
            let name = String(parts[1])
            let layout = parts.count > 2 ? String(parts[2]) : nil

            return TmuxWindow(
                id: winID,
                name: name,
                panes: [],
                layout: layout
            )
        }
    }
}
