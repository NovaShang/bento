import BentoFoundation
import BentoUI
import BentoVoiceKit
import BentoFilePreviewKit
import BentoWorkbench
import ACPHostKit
import Foundation

/// Wires the ACP agent module into a workspace store: runtime construction,
/// store-facing callbacks, and provider-aware preset resolution. The store
/// itself never names an agent type (the `PaneRuntime` seam) — this is the
/// other side of that seam, called once per store by each app shell before
/// the first pane spawns. A store without an install is structure-only,
/// which is exactly what the structure tests run.
@MainActor
public enum AcpPaneModule {
    public static func install(on store: AgentWorkspaceStore) {
        AgentDefaults.apiKeyPresetResolver = AIProvider.acpApiKeyPreset(matching:)
        store.runtimeFactory = { [unowned store] paneID, entry, preset in
            let runtime = AgentSessionViewModel(preset: preset, cwd: entry.cwd)
            if let title = entry.title { runtime.title = title }
            // Seed the agent-side name from the catalog so a reopened
            // conversation is named immediately — the agent only re-sends
            // session_info_update at the next turn end.
            if let sid = entry.acpSessionID, let recorded = store.catalog.entries[sid],
               !recorded.title.isEmpty {
                runtime.sessionTitle = recorded.title
            }
            runtime.onActivityChange = { [weak store] in
                store?.emit(.activity(pane: paneID))
                store?.catalogNoteActivity(paneID: paneID)
            }
            runtime.onSessionTitleChange = { [weak store] in
                guard let store else { return }
                if let name = store.workspaceName(ofPane: paneID) {
                    store.emit(.structure(session: name))
                }
                if let entry = store.paneEntry(paneID) {
                    store.catalogUpsert(pane: entry)
                }
            }
            runtime.onSessionLoadFailed = { [weak store] sessionID in
                // Resuming a recorded session drew an agent-side error: the
                // conversation was likely GC'd — grey its history entry.
                store?.markExpired(sessionID)
            }
            runtime.onRestartRequested = { [weak store] in
                store?.restartPane(paneID)
            }
            runtime.onConnectionLost = { [weak store] in
                store?.reconnectPane(paneID)
            }
            return runtime
        }
    }
}

public extension AgentWorkspaceStore {
    /// The pane's runtime downcast to the ACP agent implementation — for
    /// agent-side callers (chat surfaces and views) that bind the concrete
    /// type. Workspace-layer code uses `runtime(forPane:)` instead.
    func agentRuntime(forPane paneID: Int) -> AgentSessionViewModel? {
        runtime(forPane: paneID) as? AgentSessionViewModel
    }
}
