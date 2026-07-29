#if os(macOS)
import BentoAgentPane
import BentoWorkbench
import Foundation

/// The Mac shell's side of the seams: hand shell chrome (preview dock,
/// native directory panel) to the modules that must not import it. One
/// public entry so the app delegate stays a single line and the shell's
/// internals stay internal.
@MainActor
public enum ShellMacWiring {
    public static func install() {
        AgentChatSurface.previewOpener = { path, line, context in
            WorkspaceWindow.openPreview(path: path, line: line, context: context)
        }
        PaneSidebar.directoryPanelPresenter = { title, prompt, dir, onCreate, onResume in
            presentNewPaneDirectoryPanel(
                title: title, prompt: prompt, initialDirectory: dir,
                onCreate: onCreate, onResume: onResume)
        }
    }
}
#endif
