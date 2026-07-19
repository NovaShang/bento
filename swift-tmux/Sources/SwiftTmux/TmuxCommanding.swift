import Foundation

/// The command-level seam between TerminalViewModel and its backend. The
/// terminal path implements it with the real control-mode codec
/// (`TmuxControlMode`); the ACP path implements it with a bridge that
/// interprets `TmuxCommand` values against a local workspace store — so the
/// view model's forty-odd command sites never change.
public protocol TmuxCommanding: AnyObject, Sendable {
    var onNotification: (@Sendable (TmuxNotification) -> Void)? { get set }
    var sendToSSH: (@Sendable (String) -> Void)? { get set }
    var logHandler: (@Sendable (String) -> Void)? { get set }

    func launchCommand(sessionName: String?, groupWith: String?) -> String
    func feedData(_ data: Data)
    func send(_ command: TmuxCommand, timeout: Duration) async -> TmuxCommandResponse
    func awaitControlMode(timeout: Duration) async -> Bool
    func reset()
    func sendFireAndForget(_ command: TmuxCommand)
    func sendData(to pane: TmuxPaneID, data: Data)
}

public extension TmuxCommanding {
    /// Call-site parity with TmuxControlMode's defaulted parameters.
    func send(_ command: TmuxCommand) async -> TmuxCommandResponse {
        await send(command, timeout: .seconds(10))
    }
}

extension TmuxControlMode: TmuxCommanding {}
