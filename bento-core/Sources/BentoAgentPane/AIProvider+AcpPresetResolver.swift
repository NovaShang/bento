import BentoFoundation
import BentoUI
import BentoVoiceKit
import BentoFilePreviewKit
import BentoWorkbench
import ACPHostKit
import Foundation

extension AIProvider {
    /// API-key providers (Kimi/GLM/DeepSeek — Claude Code harness) resolve to
    /// a preset carrying the vendor endpoint env plus the user's stored key,
    /// so their panes spawn authenticated. Mac-side only: the Keychain lives
    /// on the host; an iOS client spawning one of these panes sends no key
    /// (known v1 gap until the daemon-side connect engine owns keys).
    ///
    /// Installed into `AgentWorkspaceStore.apiKeyPresetResolver` by
    /// `AcpPaneModule.install` — the workspace layer stays provider-blind.
    static func acpApiKeyPreset(matching commandOrID: String) -> ACPAgentPreset? {
        guard let provider = AIProvider.apiKeyProviders.first(where: {
            $0.id == commandOrID || $0.seedCommand == commandOrID
        }) else { return nil }
        #if os(macOS)
        let key = KeychainProviderKeyStore().key(for: provider.id)
        #else
        let key: String? = nil
        #endif
        return provider.acpPreset(withKey: key)
    }
}
