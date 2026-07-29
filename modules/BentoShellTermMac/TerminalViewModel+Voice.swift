// Ported from frozen TerminalViewModel+Voice.swift @ 8fa54b6^; data layer swapped, UI verbatim.
import Foundation


public extension TerminalViewModel {
    /// Apply a voice result to the active pane, per the compass direction.
    /// Shared by iOS + macOS (both just hand off the `VoiceInputResult`).
    func handleVoiceResult(_ result: VoiceInputResult) {
        switch result.direction {
        case .none:
            sendString(result.text)
        case .up:
            sendString(result.text)
            sendReturnDistinct()
        case .left, .right:
            // LLM-assisted: convert NL to a shell command using recent context.
            Task {
                let context = recentPaneContext()
                let command = await LLMService.shared.convertToShellCommand(
                    transcript: result.text,
                    context: context
                )
                if !command.isEmpty {
                    sendString(command)
                    if result.direction == .right { sendReturnDistinct() }
                }
            }
        case .down:
            break
        }
    }

    /// Send Enter as its OWN keystroke, shortly after the text, so it isn't
    /// coalesced into the same `send-keys` burst as the inserted text — a TUI
    /// input box (e.g. Claude Code) treats text+CR arriving together as pasted
    /// content and won't submit, but a standalone CR is a real Enter.
    private func sendReturnDistinct() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            if let data = "\r".data(using: .utf8) { sendData(data) }
        }
    }

    /// Recent terminal text used as LLM context for the active pane. (The
    /// frozen read came from the shared detection buffers; the trunk's live
    /// scrollback read is the same information at the same moment.)
    private func recentPaneContext() -> String {
        guard let activePaneID,
              let vm = paneViewModels.first(where: { $0.paneID == activePaneID }),
              let text = vm.onReadScrollback?() else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(30).joined(separator: "\n")
    }
}
