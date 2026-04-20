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
    }

    private struct CommandBlock {
        let commandNumber: Int
        var lines: [String] = []
    }

    // Line buffer for incoming data
    private let bufferLock = OSAllocatedUnfairLock(initialState: Data())

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
        sendToSSH?(cmdString)
    }

    /// Send raw keys to a specific pane.
    func sendKeys(to pane: TmuxPaneID, keys: String) {
        sendFireAndForget(.sendKeys(pane: pane, keys: keys))
    }

    /// Send raw bytes to a pane (for terminal input).
    /// Uses `send-keys -H` (hex mode) to safely transmit any byte including
    /// control characters like \r, \n, \x1b without breaking the tmux protocol.
    func sendData(to pane: TmuxPaneID, data: Data) {
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
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = buffer[(newlineIndex + 1)...]
                if let last = lineData.last, last == UInt8(ascii: "\r") {
                    return String(data: lineData.dropLast(), encoding: .utf8)
                }
                return String(data: lineData, encoding: .utf8)
            }

            guard var line = maybeLine else { break }

            // tmux -CC sends DCS \033P1000p before entering control mode.
            // Strip everything before %begin/%output/% notification if present.
            if let range = line.range(of: "%begin ") ?? line.range(of: "%output ") ??
               line.range(of: "%end ") ?? line.range(of: "%error ") ??
               line.range(of: "%session-changed ") ?? line.range(of: "%layout-change ") ??
               line.range(of: "%window-") ?? line.range(of: "%pane-") ??
               line.range(of: "%exit") {
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
        let parts = line.split(separator: " ", maxSplits: 2)
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
    private func unescapeTmuxOutput(_ escaped: String) -> Data {
        var result = Data()
        var chars = escaped.makeIterator()

        while let ch = chars.next() {
            if ch == "\\" {
                var octalStr = ""
                for _ in 0..<3 {
                    guard let digit = chars.next() else { break }
                    octalStr.append(digit)
                }
                if let value = UInt8(octalStr, radix: 8) {
                    result.append(value)
                } else {
                    result.append(UInt8(ascii: "\\"))
                    result.append(contentsOf: octalStr.utf8)
                }
            } else {
                result.append(contentsOf: String(ch).utf8)
            }
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
