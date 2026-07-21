import SwiftUI
import ServiceManagement
import ACPHostKit
import BentoCore
import UniformTypeIdentifiers

/// SettingsView is the content of the app's Settings scene. macOS renders it
/// in the canonical "preferences window" chrome with toolbar + grouped form.
struct SettingsView: View {
    @EnvironmentObject var bento: BentoCLI
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var providerStore = ClaudeCodeProviderStore.shared
    @State private var relayURL: String = ""
    @State private var launchAtLogin: Bool = LoginItem.isEnabled
    @State private var loginErr: String?
    @State private var applying = false
    @State private var applied = false
    @AppStorage(WorkspaceWindow.defaultSessionNameKey) private var defaultSessionName: String = "bento"
    @AppStorage(WorkspaceWindow.autoHideToolbarFullscreenKey) private var autoHideToolbar = true
    @AppStorage("speech_engine") private var speechEngine = "apple"
    @AppStorage("speech_locale") private var speechLocale = "auto"
    @AppStorage("dashscope_api_key") private var dashscopeKey = ""
    @AppStorage("asr_auto_context") private var asrAutoContext = true
    @AppStorage("asr_vocab") private var asrVocab = ""
    @AppStorage("acp_default_agent") private var defaultAgent = "opencode"
    @State private var showThemeImporter = false
    @State private var importError: String?
    @State private var showProviderEditor = false
    @ObservedObject private var telemetry = TelemetryService.shared

    private var defaultAgentDetail: String {
        ACPAgentPreset.builtin.first { $0.id == defaultAgent }?.detail ?? defaultAgent
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            voiceTab
                .tabItem { Label("Voice", systemImage: "mic") }
            relayTab
                .tabItem { Label("Relay", systemImage: "network") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 360)
        .sheet(isPresented: $showProviderEditor) {
            ClaudeCodeProviderEditorView()
        }
    }

    // MARK: - Voice (shared engine + settings with iOS)

    private var voiceTab: some View {
        Form {
            Section {
                Picker("Engine", selection: $speechEngine) {
                    Text("Apple (on-device)").tag("apple")
                    Text("Qwen (中文 / 中英混说)").tag("qwen")
                }
                Picker("Language", selection: $speechLocale) {
                    Text("Auto").tag("auto")
                    Text("中文").tag("zh-Hans")
                    Text("English").tag("en-US")
                    Text("日本語").tag("ja-JP")
                }
                if speechEngine == "qwen" {
                    SecureField("DashScope API key (optional)", text: $dashscopeKey)
                    Toggle("Bias from on-screen text", isOn: $asrAutoContext)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Custom vocabulary (names, jargon — one per line or comma-separated)")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $asrVocab)
                            .frame(height: 56).font(.caption.monospaced())
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    }
                }
            } header: { Text("Speech") } footer: {
                Text(speechEngine == "qwen"
                     ? "Qwen realtime (qwen3-asr-flash) — best for Chinese and Chinese-English mixed speech. Uses the bundled relay unless you add a DashScope key."
                     : "Apple runs on-device (no key needed).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
            } footer: {
                Text("Right-click-and-hold a pane to dictate. While held, drag: ↑ send · ↓ cancel · release to insert into the composer.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    // MARK: - Appearance (theme)

    private var appearanceTab: some View {
        Form {
            Section {
                Picker("Appearance", selection: Binding(
                    get: { themeStore.appearanceMode },
                    set: { themeStore.appearanceMode = $0 }
                )) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
            } header: { Text("Appearance") } footer: {
                Text("Follow System matches macOS's light/dark; pick Light or Dark to pin it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Dark theme", selection: Binding(
                    get: { themeStore.darkThemeID },
                    set: { themeStore.select(id: $0, forDark: true) }
                )) {
                    ForEach(themeStore.themes(forDark: true)) { Text($0.name).tag($0.id) }
                }
                Picker("Light theme", selection: Binding(
                    get: { themeStore.lightThemeID },
                    set: { themeStore.select(id: $0, forDark: false) }
                )) {
                    ForEach(themeStore.themes(forDark: false)) { Text($0.name).tag($0.id) }
                }
                Button("Import iTerm2 Theme…") { showThemeImporter = true }
                if let importError {
                    Label(importError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
                ForEach(themeStore.customThemes) { theme in
                    HStack {
                        Text(theme.name)
                        Spacer()
                        Button(role: .destructive) {
                            themeStore.removeCustomTheme(theme.id)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            } header: { Text("Color theme") } footer: {
                Text("The Dark theme is used in dark appearance, the Light theme in light. Applies live to open windows.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Auto-hide toolbar in full screen", isOn: $autoHideToolbar)
            } header: { Text("Full Screen") } footer: {
                Text("Hide the toolbar and session tabs in full screen, revealing them when the pointer reaches the top. Takes effect the next time you enter full screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Default session name", text: $defaultSessionName, prompt: Text("bento"))
            } header: { Text("Sessions") } footer: {
                Text("Clicking the app icon opens the terminal window and reconnects the session you last had open. With no previous session, it creates one with this name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showThemeImporter,
                      allowedContentTypes: [UTType(filenameExtension: "itermcolors") ?? .data]) { result in
            handleThemeImport(result)
        }
    }

    private func handleThemeImport(_ result: Result<URL, Error>) {
        importError = nil
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            let theme = try TerminalColorTheme.fromITermColors(data: data, name: name)
            themeStore.addCustomTheme(theme)
        } catch {
            importError = (error as NSError).localizedDescription
        }
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch Bento at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LoginItem.setEnabled(newValue)
                            loginErr = nil
                        } catch {
                            loginErr = (error as NSError).localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
            } footer: {
                if let loginErr {
                    Label(loginErr, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    Text("Bento will appear in your menu bar after every login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Default agent", selection: $defaultAgent) {
                    ForEach(ACPAgentPreset.builtin) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                Picker("Claude Code provider", selection: Binding(
                    get: { providerStore.activeID },
                    set: { providerStore.setActive($0) }
                )) {
                    ForEach(providerStore.providers) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                Button("Edit Providers…") { showProviderEditor = true }
            } header: { Text("Agents") } footer: {
                Text("Used when a new pane or session doesn't pick an agent explicitly (\(defaultAgentDetail)). The Claude Code provider picks which upstream API claude-agent-acp talks to.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Share anonymous usage statistics", isOn: Binding(
                    get: { telemetry.enabled },
                    set: { telemetry.enabled = $0 }
                ))
                DisclosureGroup("What gets counted") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(TelemetryEvent.allCases, id: \.rawValue) { event in
                            Text(event.rawValue)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("No conversation content, commands, transcripts, paths, or hostnames — ever. Just the event names above, tied to a random ID that is deleted when you turn this off. Events go through the same Bento relay; no third-party SDKs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var relayTab: some View {
        Form {
            Section {
                TextField("Relay URL", text: $relayURL, prompt: Text(BentoCLI.defaultRelayURL))
            } footer: {
                Text("Leave blank to use the default Cloudflare-hosted relay. " +
                     "The daemon restarts to pick up the new URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    if applied {
                        Label("Applied", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                    Button("Apply") {
                        Task { await applyRelay() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(applying)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadCurrent() }
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Bento")
                .font(.title2).bold()
            Text("Parallel coding agents on your Mac — and in your pocket.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadCurrent() {
        relayURL = bento.currentRelayURL()
    }

    private func applyRelay() async {
        applying = true
        applied = false
        defer { applying = false }
        try? await bento.stopDaemon()
        try? await bento.startDaemon(relay: relayURL.isEmpty ? nil : relayURL)
        applied = true
    }
}

// MARK: - Claude Code Provider editor

/// Sheet that lists all Claude Code providers, lets the user pick the
/// active one, and add/edit/delete entries. Mirrors the ProfileListView
/// pattern (list + edit sheet, built-ins deletable only via reset).
struct ClaudeCodeProviderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ClaudeCodeProviderStore.shared
    @State private var editing: ClaudeCodeProvider?
    @State private var isAddingNew = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(store.providers) { provider in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(provider.name)
                                        .font(.body.weight(.medium))
                                    if provider.id == store.activeID {
                                        Text("Active")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(.tint.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                    if provider.isBuiltIn {
                                        Text("Built-in")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(.quaternary)
                                            .clipShape(Capsule())
                                    }
                                }
                                if !provider.baseURL.isEmpty {
                                    Text(provider.baseURL)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Text(modelSummary(provider))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button {
                                editing = provider
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.setActive(provider.id)
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet { store.delete(store.providers[i].id) }
                    }
                } header: {
                    Text("Providers")
                } footer: {
                    Text("Click a row to make it active. The active provider's env vars (base URL, auth token, model aliases) are injected into claude-agent-acp when Bento launches Claude Code. Custom panes' env wins over the provider.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 520, height: 380)
        .navigationTitle("Claude Code Providers")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingNew = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button("Reset to Defaults") { store.resetToDefaults() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
            }
        }
        .sheet(item: $editing) { provider in
            ClaudeCodeProviderEditView(provider: provider, isNew: false) { updated in
                store.upsert(updated)
            }
        }
        .sheet(isPresented: $isAddingNew) {
            ClaudeCodeProviderEditView(
                provider: ClaudeCodeProvider(id: UUID().uuidString, name: ""),
                isNew: true
            ) { newProvider in
                store.upsert(newProvider)
                store.setActive(newProvider.id)
            }
        }
    }

    private func modelSummary(_ p: ClaudeCodeProvider) -> String {
        let parts = [p.opusModel, p.sonnetModel, p.haikuModel].filter { !$0.isEmpty }
        if parts.isEmpty { return "Default models" }
        return "Models: " + parts.joined(separator: ", ")
    }
}

struct ClaudeCodeProviderEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State var provider: ClaudeCodeProvider
    let isNew: Bool
    let onSave: (ClaudeCodeProvider) -> Void

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $provider.name)
            } header: { Text("Identity") } footer: {
                Text("Shown in the provider picker.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Base URL", text: $provider.baseURL, prompt: Text("https://api.anthropic.com"))
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                SecureField("Auth token", text: $provider.authToken, prompt: Text("sk-…"))
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
            } header: { Text("Endpoint") } footer: {
                Text("Leave both blank to use Anthropic's official endpoint with the agent's own login (claude /login).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Opus model", text: $provider.opusModel, prompt: Text("claude-opus-4-5"))
                    .font(.system(.body, design: .monospaced))
                TextField("Sonnet model", text: $provider.sonnetModel, prompt: Text("claude-sonnet-4-5"))
                    .font(.system(.body, design: .monospaced))
                TextField("Haiku model", text: $provider.haikuModel, prompt: Text("claude-haiku-4-5"))
                    .font(.system(.body, design: .monospaced))
            } header: { Text("Model aliases") } footer: {
                Text("Overrides ANTHROPIC_DEFAULT_OPUS_MODEL / SONNET / HAIKU. Leave blank for the agent's defaults.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Request timeout (ms)", text: $provider.apiTimeoutMs, prompt: Text("3000000"))
                    .font(.system(.body, design: .monospaced))
            } header: { Text("Advanced") }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 480)
        .navigationTitle(isNew ? "New Provider" : provider.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(provider)
                    dismiss()
                }
                .disabled(provider.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
