import SwiftUI
import ACPHostKit
import BentoCore

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showThemeImporter = false
    @State private var themeImportError: String?
    @State private var showThemeImportError = false
    @State private var showTipsResetConfirm = false
    @ObservedObject private var providerStore = ClaudeCodeProviderStore.shared
    @AppStorage("haptics_enabled") private var hapticsEnabled = true
    @AppStorage("speech_locale") private var speechLocale = "auto"
    @AppStorage("speech_engine") private var speechEngine: String = "apple"
    @AppStorage("dashscope_api_key") private var dashscopeAPIKey: String = ""
    @AppStorage("asr_auto_context") private var asrAutoContext: Bool = true
    @AppStorage("asr_vocab") private var asrVocab: String = ""
    @AppStorage("acp_default_agent") private var defaultAgent = "opencode"
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var telemetry = TelemetryService.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: Binding(
                        get: { themeStore.appearanceMode },
                        set: { themeStore.appearanceMode = $0 }
                    )) {
                        ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    BentoFormHeader("Appearance")
                } footer: {
                    BentoFormFooter("Follow System matches your device's light/dark setting. Pick Light or Dark to pin it. Each appearance keeps its own terminal color theme below.")
                }
                .bentoSectionStyle()

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
                    NavigationLink("Edit Providers…") {
                        ClaudeCodeProviderListView()
                    }
                } header: {
                    BentoFormHeader("Agents")
                } footer: {
                    BentoFormFooter("Used when a new pane or session doesn't pick an agent explicitly. The Claude Code provider picks which upstream API claude-agent-acp talks to.")
                }
                .bentoSectionStyle()

                Section {
                    themePicker(title: "Dark theme", dark: true)
                    themePicker(title: "Light theme", dark: false)

                    Button {
                        showThemeImporter = true
                    } label: {
                        Label("Import iTerm2 Theme…", systemImage: "square.and.arrow.down")
                    }

                    if !themeStore.customThemes.isEmpty {
                        ForEach(themeStore.customThemes) { theme in
                            HStack {
                                Circle()
                                    .fill(Color(theme.bgColor))
                                    .frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(Color.bentoBorder, lineWidth: 0.5))
                                Text(theme.name)
                                Spacer()
                                Button {
                                    themeStore.removeCustomTheme(theme.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(Color.bentoRed)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                } header: {
                    BentoFormHeader("Theme")
                } footer: {
                    BentoFormFooter("The canvas color behind every pane, per appearance.")
                }
                .bentoSectionStyle()

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
                        SecureField("DashScope API Key (optional)", text: $dashscopeAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("Bias from on-screen text", isOn: $asrAutoContext)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Custom vocabulary (names, jargon)")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $asrVocab)
                                .frame(height: 60).font(.caption.monospaced())
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                } header: {
                    BentoFormHeader("Speech Recognition")
                } footer: {
                    switch speechEngine {
                    case "apple":
                        BentoFormFooter("Uses Apple's on-device SFSpeechRecognizer. No API key needed; quality varies by language.")
                    case "qwen":
                        BentoFormFooter("Alibaba Qwen realtime (qwen3-asr-flash) — best accuracy for Chinese and Chinese-English mixed speech. Works out of the box via the Bento relay — no setup required. Paste a DashScope key only to run against your own quota.")
                    default:
                        EmptyView()
                    }
                }
                .bentoSectionStyle()

                Section {
                    Toggle("Haptic Feedback", isOn: $hapticsEnabled)
                } header: {
                    BentoFormHeader("Feedback")
                }
                .bentoSectionStyle()

                Section {
                    Toggle("Share anonymous usage statistics", isOn: Binding(
                        get: { telemetry.enabled },
                        set: { telemetry.enabled = $0 }
                    ))
                    DisclosureGroup("What gets counted") {
                        ForEach(TelemetryEvent.allCases, id: \.rawValue) { event in
                            Text(event.rawValue)
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.bentoInkDim)
                        }
                    }
                } header: {
                    BentoFormHeader("Privacy")
                } footer: {
                    BentoFormFooter("No conversation content, commands, transcripts, paths, or hostnames — ever. Just the event names above, tied to a random ID that is deleted when you turn this off. Events go through the same Bento relay; no third-party SDKs.")
                }
                .bentoSectionStyle()

                Section {
                    NavigationLink {
                        HowBentoWorksSettingsPage()
                    } label: {
                        Label("How Bento works", systemImage: "questionmark.circle")
                    }
                    Button {
                        TipCenter.shared.resetAll()
                        showTipsResetConfirm = true
                    } label: {
                        Label("Replay tips & gesture guide", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    BentoFormHeader("Help")
                } footer: {
                    BentoFormFooter("Replaying brings back every one-time hint — the gesture overlay, the color legend, and the coaching toasts — at their natural moments.")
                }
                .bentoSectionStyle()

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("0.2.0")
                            .foregroundStyle(Color.bentoInkDim)
                    }
                } header: {
                    BentoFormHeader("About")
                }
                .bentoSectionStyle()
            }
            .bentoForm()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showThemeImporter,
                allowedContentTypes: [.xml, .data],
                allowsMultipleSelection: false
            ) { result in
                handleThemeImport(result)
            }
            .alert("Theme Import Failed", isPresented: $showThemeImportError) {
                Button("OK") {}
            } message: {
                Text(themeImportError ?? "")
            }
            .alert("Tips will replay", isPresented: $showTipsResetConfirm) {
                Button("OK") {}
            } message: {
                Text("Every one-time hint is armed again and will appear at its natural moment.")
            }
        }
    }

    /// One terminal-theme picker bound to a single appearance slot (dark/light),
    /// listing only themes that match that appearance.
    @ViewBuilder
    private func themePicker(title: String, dark: Bool) -> some View {
        Picker(title, selection: Binding(
            get: { dark ? themeStore.darkThemeID : themeStore.lightThemeID },
            set: { themeStore.select(id: $0, forDark: dark) }
        )) {
            ForEach(themeStore.themes(forDark: dark)) { theme in
                HStack {
                    Circle()
                        .fill(Color(theme.bgColor))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                    Text(theme.name)
                }
                .tag(theme.id)
            }
        }
    }

    private func handleThemeImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                themeImportError = "Cannot access file."
                showThemeImportError = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let data = try Data(contentsOf: url)
            let baseName = url.deletingPathExtension().lastPathComponent
            let theme = try TerminalColorTheme.fromITermColors(data: data, name: baseName)
            themeStore.addCustomTheme(theme)
        } catch {
            themeImportError = error.localizedDescription
            showThemeImportError = true
        }
    }
}

// MARK: - Claude Code Provider list + edit

struct ClaudeCodeProviderListView: View {
    @ObservedObject private var store = ClaudeCodeProviderStore.shared
    @State private var editing: ClaudeCodeProvider?
    @State private var isAddingNew = false

    var body: some View {
        List {
            Section {
                ForEach(store.providers) { provider in
                    Button {
                        store.setActive(provider.id)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(provider.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if provider.id == store.activeID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.bentoEmerald)
                                            .font(.caption)
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
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet { store.delete(store.providers[i].id) }
                }
            } header: {
                BentoFormHeader("Providers")
            } footer: {
                BentoFormFooter("Tap a row to make it active. The active provider's env vars (base URL, auth token, model aliases) are injected into claude-agent-acp when launching Claude Code.")
            }
            .bentoSectionStyle()
        }
        .bentoForm()
        .navigationTitle("Claude Code Providers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAddingNew = true
                } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Reset to Defaults") { store.resetToDefaults() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
            }
        }
        .sheet(item: $editing) { provider in
            NavigationStack {
                ClaudeCodeProviderEditView(provider: provider, isNew: false) { updated in
                    store.upsert(updated)
                }
            }
        }
        .sheet(isPresented: $isAddingNew) {
            NavigationStack {
                ClaudeCodeProviderEditView(
                    provider: ClaudeCodeProvider(id: UUID().uuidString, name: ""),
                    isNew: true
                ) { newProvider in
                    store.upsert(newProvider)
                    store.setActive(newProvider.id)
                }
            }
        }
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
            } header: {
                BentoFormHeader("Identity")
            } footer: {
                BentoFormFooter("Shown in the provider picker.")
            }
            .bentoSectionStyle()

            Section {
                TextField("Base URL", text: $provider.baseURL, prompt: Text("https://api.anthropic.com"))
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Auth token", text: $provider.authToken, prompt: Text("sk-…"))
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                BentoFormHeader("Endpoint")
            } footer: {
                BentoFormFooter("Leave both blank to use Anthropic's official endpoint with the agent's own login (claude /login).")
            }
            .bentoSectionStyle()

            Section {
                TextField("Opus model", text: $provider.opusModel, prompt: Text("claude-opus-4-5"))
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                TextField("Sonnet model", text: $provider.sonnetModel, prompt: Text("claude-sonnet-4-5"))
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                TextField("Haiku model", text: $provider.haikuModel, prompt: Text("claude-haiku-4-5"))
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
            } header: {
                BentoFormHeader("Model aliases")
            } footer: {
                BentoFormFooter("Overrides ANTHROPIC_DEFAULT_OPUS_MODEL / SONNET / HAIKU. Leave blank for the agent's defaults.")
            }
            .bentoSectionStyle()

            Section {
                TextField("Request timeout (ms)", text: $provider.apiTimeoutMs, prompt: Text("3000000"))
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numberPad)
            } header: {
                BentoFormHeader("Advanced")
            }
            .bentoSectionStyle()
        }
        .bentoForm()
        .navigationTitle(isNew ? "New Provider" : provider.name)
        .navigationBarTitleDisplayMode(.inline)
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
