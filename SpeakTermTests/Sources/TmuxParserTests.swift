import Testing
@testable import SpeakTerm

@Suite("Tmux Parser Tests")
struct TmuxParserTests {
    let service = TmuxControlModeService()

    @Test func parsePaneList() {
        let output = "%0:80:24:0:0:1:zsh:localhost"
        let panes = service.parsePaneList(output)
        #expect(panes.count == 1)
        #expect(panes[0].id == TmuxPaneID(0))
        #expect(panes[0].width == 80)
        #expect(panes[0].height == 24)
        #expect(panes[0].isActive == true)
    }

    @Test func parsePaneListMultiple() {
        let output = """
        %0:40:24:0:0:1:zsh:host
        %1:40:24:40:0:0:vim:host
        """
        let panes = service.parsePaneList(output)
        #expect(panes.count == 2)
        #expect(panes[1].x == 40)
        #expect(panes[1].isActive == false)
        #expect(panes[1].currentCommand == "vim")
    }

    @Test func parseWindowList() {
        let output = "@0:zsh:b25d,80x24,0,0,0:1"
        let windows = service.parseWindowList(output)
        #expect(windows.count == 1)
        #expect(windows[0].id == TmuxWindowID(0))
        #expect(windows[0].name == "zsh")
    }

    @Test func tmuxPaneIDParsing() {
        let id = TmuxPaneID(string: "%5")
        #expect(id != nil)
        #expect(id?.raw == 5)
        #expect(id?.description == "%5")
    }

    @Test func tmuxWindowIDParsing() {
        let id = TmuxWindowID(string: "@10")
        #expect(id != nil)
        #expect(id?.raw == 10)
    }

    @Test func tmuxSessionIDParsing() {
        let id = TmuxSessionID(string: "$0")
        #expect(id != nil)
        #expect(id?.raw == 0)
    }

    @Test func invalidIDParsing() {
        #expect(TmuxPaneID(string: "0") == nil)
        #expect(TmuxPaneID(string: "@0") == nil)
        #expect(TmuxWindowID(string: "%0") == nil)
    }
}

@Suite("State Detection Tests")
struct StateDetectionTests {
    @Test func detectAwaitingInput() {
        let service = StateDetectionService()
        let pane = TmuxPaneID(0)

        // Feed output that matches a shell prompt pattern
        let data = "Do you want to continue? [y/N] ".data(using: .utf8)!
        service.recordOutput(pane: pane, data: data)

        let state = service.detectState(pane: pane, currentCommand: nil)
        if case .awaitingInput = state {
            // Expected
        } else {
            Issue.record("Expected awaitingInput, got \(state)")
        }
    }

    @Test func detectWorking() {
        let service = StateDetectionService()
        let pane = TmuxPaneID(0)

        let data = "Compiling module 'App'...\n".data(using: .utf8)!
        service.recordOutput(pane: pane, data: data)

        let state = service.detectState(pane: pane, currentCommand: nil)
        #expect(state == .working)
    }
}

@Suite("Command Builder Tests")
struct CommandBuilderTests {
    @Test func splitWindowCommand() {
        let cmd = TmuxCommand.splitWindow(target: TmuxPaneID(0), horizontal: true)
        #expect(cmd.commandString == "split-window -h -t %0")
    }

    @Test func sendKeysLiteral() {
        let cmd = TmuxCommand.sendKeys(pane: TmuxPaneID(1), keys: "hello", literal: true)
        #expect(cmd.commandString == "send-keys -t %1 -l hello")
    }

    @Test func refreshClient() {
        let cmd = TmuxCommand.refreshClient(width: 120, height: 40)
        #expect(cmd.commandString == "refresh-client -C 120,40")
    }

    @Test func listPanes() {
        let cmd = TmuxCommand.listPanes()
        #expect(cmd.commandString.hasPrefix("list-panes"))
    }
}
