import Testing
@testable import SwiftTmux

@Suite("TmuxCommand builder")
struct CommandTests {
    @Test func splitWindowCommand() {
        let cmd = TmuxCommand.splitWindow(target: TmuxPaneID(0), horizontal: true)
        #expect(cmd.commandString == "split-window -h -t %0")
    }

    @Test func splitWindowVertical() {
        let cmd = TmuxCommand.splitWindow(target: TmuxPaneID(2), horizontal: false)
        #expect(cmd.commandString == "split-window -v -t %2")
    }

    @Test func sendKeysLiteral() {
        let cmd = TmuxCommand.sendKeys(pane: TmuxPaneID(1), keys: "hello", literal: true)
        #expect(cmd.commandString == "send-keys -t %1 -l hello")
    }

    @Test func sendKeysWithSpacesEscaped() {
        let cmd = TmuxCommand.sendKeys(pane: TmuxPaneID(1), keys: "hello world", literal: true)
        #expect(cmd.commandString == "send-keys -t %1 -l 'hello world'")
    }

    @Test func refreshClient() {
        let cmd = TmuxCommand.refreshClient(width: 120, height: 40)
        #expect(cmd.commandString == "refresh-client -C 120,40")
    }

    @Test func listPanesFormat() {
        let cmd = TmuxCommand.listPanes()
        #expect(cmd.commandString.hasPrefix("list-panes -F "))
        #expect(cmd.commandString.contains("#{pane_id}"))
        #expect(cmd.commandString.contains("#{pane_active}"))
    }

    @Test func listWindowsFormat() {
        let cmd = TmuxCommand.listWindows()
        #expect(cmd.commandString.hasPrefix("list-windows -F "))
        #expect(cmd.commandString.contains("#{window_id}"))
    }

    @Test func capturePaneHasFlags() {
        let cmd = TmuxCommand.capturePane(id: TmuxPaneID(3), lines: 50)
        #expect(cmd.commandString == "capture-pane -t %3 -p -e -J -S -50")
    }

    @Test func resizePaneByDirection() {
        let cmd = TmuxCommand.resizePaneBy(id: TmuxPaneID(0), direction: "L", amount: 4)
        #expect(cmd.commandString == "resize-pane -t %0 -L 4")
    }

    @Test func zoomPane() {
        let cmd = TmuxCommand.zoomPane(id: TmuxPaneID(5))
        #expect(cmd.commandString == "resize-pane -Z -t %5")
    }

    @Test func killSessionWithoutName() {
        let cmd = TmuxCommand.killSession()
        #expect(cmd.commandString == "kill-session")
    }

    @Test func killSessionWithName() {
        let cmd = TmuxCommand.killSession(name: "main")
        #expect(cmd.commandString == "kill-session -t main")
    }

    @Test func newSessionGrouped() {
        let cmd = TmuxCommand.newSession(name: "main-mobile", groupWith: "main")
        #expect(cmd.commandString == "new-session -d -t main -s main-mobile")
    }

    @Test func argEscapingForQuote() {
        let cmd = TmuxCommand.renameWindow(id: TmuxWindowID(0), name: "it's mine")
        #expect(cmd.commandString == "rename-window -t @0 'it'\\''s mine'")
    }
}

@Suite("Tmux ID parsing")
struct IDParsingTests {
    @Test func paneID() {
        let id = TmuxPaneID(string: "%5")
        #expect(id != nil)
        #expect(id?.raw == 5)
        #expect(id?.description == "%5")
    }

    @Test func windowID() {
        let id = TmuxWindowID(string: "@10")
        #expect(id != nil)
        #expect(id?.raw == 10)
    }

    @Test func sessionID() {
        let id = TmuxSessionID(string: "$0")
        #expect(id != nil)
        #expect(id?.raw == 0)
    }

    @Test func wrongSigilRejected() {
        #expect(TmuxPaneID(string: "0") == nil)
        #expect(TmuxPaneID(string: "@0") == nil)
        #expect(TmuxWindowID(string: "%0") == nil)
        #expect(TmuxSessionID(string: "@0") == nil)
    }

    @Test func nonNumericRejected() {
        #expect(TmuxPaneID(string: "%abc") == nil)
    }
}
