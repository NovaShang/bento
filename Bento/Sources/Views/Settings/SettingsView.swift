import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showThemeImporter = false
    @State private var themeImportError: String?
    @State private var showThemeImportError = false
    @AppStorage("terminal_font_size") private var fontSize: Double = 12
    @AppStorage("terminal_font_family") private var fontFamily: String = "maple-nf-cn"
    @AppStorage("haptics_enabled") private var hapticsEnabled = true
    @AppStorage("speech_locale") private var speechLocale = "auto"
    @AppStorage("speech_engine") private var speechEngine: String = "apple"
    @AppStorage("openai_api_key") private var openaiAPIKey: String = ""
    @AppStorage("openai_proxy_url") private var openaiProxyURL: String = ""
    @AppStorage("openai_proxy_secret") private var openaiProxySecret: String = ""
    @AppStorage("llm_enabled") private var llmEnabled: Bool = true
    @AppStorage("llm_api_key") private var llmAPIKey: String = ""
    @AppStorage("llm_model") private var llmModel: String = "gpt-4o-mini"
    @AppStorage("llm_endpoint") private var llmEndpoint: String = "https://api.openai.com/v1/chat/completions"
    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Terminal") {
                    HStack {
                        Text("Font Size")
                        Slider(value: $fontSize, in: 8...24, step: 1) { editing in
                            if !editing {
                                NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
                            }
                        }
                        Text("\(Int(fontSize))")
                            .monospacedDigit()
                    }

                    Picker("Font", selection: $fontFamily) {
                        Text("SF Mono").tag("system")
                        Text("SF Mono (Medium)").tag("system-medium")
                        Text("JetBrains Mono").tag("jetbrains")
                        Text("Maple Mono NF CN").tag("maple-nf-cn")
                        Text("Menlo").tag("menlo")
                        Text("Courier New").tag("courier")
                    }
                    .onChange(of: fontFamily) { _, _ in
                        NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
                    }

                    Picker("Theme", selection: Binding(
                        get: { themeStore.current.id },
                        set: { themeStore.current = TerminalColorTheme.find(id: $0) }
                    )) {
                        ForEach(themeStore.allThemes) { theme in
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
                                    .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                                Text(theme.name)
                                Spacer()
                                Button {
                                    themeStore.removeCustomTheme(theme.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section {
                    Picker("Engine", selection: $speechEngine) {
                        Text("Apple (on-device)").tag("apple")
                        Text("OpenAI gpt-realtime-whisper").tag("openai")
                    }
                    Picker("Language", selection: $speechLocale) {
                        Text("Auto").tag("auto")
                        Text("中文").tag("zh-Hans")
                        Text("English").tag("en-US")
                        Text("日本語").tag("ja-JP")
                    }
                    if speechEngine == "openai" {
                        SecureField("OpenAI API Key (direct BYOK)", text: $openaiAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Token-Mint Proxy URL (optional)", text: $openaiProxyURL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.caption.monospaced())
                        if !openaiProxyURL.isEmpty {
                            SecureField("Proxy Shared Secret (optional)", text: $openaiProxySecret)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                } header: {
                    Text("Speech Recognition")
                } footer: {
                    switch speechEngine {
                    case "apple":
                        Text("Uses Apple's on-device SFSpeechRecognizer. No API key needed; quality varies by language.")
                    case "openai":
                        Text("OpenAI Realtime API with gpt-realtime-whisper ($0.017/min, low-latency streaming). Provide either an API key directly, or a Proxy URL pointing at the Bento relay mint endpoint, e.g. https://<your-relay>.workers.dev/v1/asr/mint (recommended — keeps the real key off the device). Shared secret matches ASR_MINT_SECRET set in the Worker.")
                    default:
                        EmptyView()
                    }
                }

                Section("Feedback") {
                    Toggle("Haptic Feedback", isOn: $hapticsEnabled)
                }

                Section {
                    NavigationLink("State Detection Profiles") {
                        ProfileListView()
                    }
                } footer: {
                    Text("Configure patterns to detect when a pane is waiting for input, and which quick keys to show.")
                }

                Section {
                    Toggle("Enabled", isOn: $llmEnabled)
                    if llmEnabled {
                        SecureField("API Key", text: $llmAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Picker("Model", selection: $llmModel) {
                            Text("gpt-4o-mini").tag("gpt-4o-mini")
                            Text("gpt-4o").tag("gpt-4o")
                            Text("gpt-4.1-mini").tag("gpt-4.1-mini")
                            Text("gpt-4.1").tag("gpt-4.1")
                        }
                        TextField("Endpoint", text: $llmEndpoint)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.caption.monospaced())
                    }
                } header: {
                    Text("Voice → Shell Command (LLM)")
                } footer: {
                    Text("Bring your own key. Swipe left/right while holding to talk: the LLM converts what you said into a shell command. Right swipe also runs it. Endpoint must be OpenAI-compatible chat completions.")
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("0.2.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
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

// MARK: - Profile List

struct ProfileListView: View {
    @ObservedObject private var store = ProfileStore.shared
    @State private var editingProfile: StateProfile?
    @State private var showAddSheet = false

    var body: some View {
        List {
            ForEach(store.profiles) { profile in
                Button {
                    editingProfile = profile
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(profile.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                if profile.isBuiltIn {
                                    Text("Built-in")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary)
                                        .clipShape(Capsule())
                                }
                            }
                            Text("\(profile.outputPatterns.count) patterns · \(profile.quickKeys.count) keys")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let cmd = profile.commandPattern {
                                Text("command: \(cmd)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .onDelete { indexSet in
                for i in indexSet where !store.profiles[i].isBuiltIn {
                    store.profiles.remove(at: i)
                }
                store.save()
            }
        }
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showAddSheet = true }) {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Reset to Defaults") { store.resetToDefaults() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
            }
        }
        .sheet(item: $editingProfile) { profile in
            NavigationStack {
                ProfileEditView(profile: profile) { updated in
                    if let idx = store.profiles.firstIndex(where: { $0.id == updated.id }) {
                        store.profiles[idx] = updated
                    }
                    store.save()
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                ProfileEditView(profile: StateProfile(
                    id: UUID().uuidString,
                    name: "",
                    outputPatterns: [],
                    commandPattern: nil,
                    quickKeys: []
                )) { newProfile in
                    store.profiles.append(newProfile)
                    store.save()
                }
            }
        }
    }
}

// MARK: - Profile Edit

struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: StateProfile
    let onSave: (StateProfile) -> Void

    @State private var newPattern = ""
    @State private var newKeyLabel = ""
    @State private var newKeyString = ""
    @State private var newKeyIsEnter = true

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $profile.name)
                TextField("Command pattern (optional)", text: Binding(
                    get: { profile.commandPattern ?? "" },
                    set: { profile.commandPattern = $0.isEmpty ? nil : $0 }
                ))
                .font(.system(.body, design: .monospaced))
                .autocapitalization(.none)
            }

            Section {
                ForEach(profile.outputPatterns.indices, id: \.self) { i in
                    Text(profile.outputPatterns[i])
                        .font(.system(.caption, design: .monospaced))
                }
                .onDelete { profile.outputPatterns.remove(atOffsets: $0) }

                HStack {
                    TextField("New regex pattern", text: $newPattern)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                    Button(action: {
                        guard !newPattern.isEmpty else { return }
                        profile.outputPatterns.append(newPattern)
                        newPattern = ""
                    }) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newPattern.isEmpty)
                }
            } header: {
                Text("Output Patterns (regex)")
            } footer: {
                Text("If any pattern matches the recent terminal output, the pane is considered 'awaiting input'.")
            }

            Section {
                ForEach(profile.quickKeys) { key in
                    HStack {
                        Text(key.label)
                            .font(.body.weight(.medium))
                        Spacer()
                        if key.isEnter {
                            Text("+ Enter")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(key.keys.isEmpty ? "(none)" : key.keys)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { profile.quickKeys.remove(atOffsets: $0) }

                HStack(spacing: 8) {
                    TextField("Label", text: $newKeyLabel)
                        .frame(width: 60)
                    TextField("Keys", text: $newKeyString)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                    Toggle("↵", isOn: $newKeyIsEnter)
                        .labelsHidden()
                        .frame(width: 40)
                    Button(action: {
                        guard !newKeyLabel.isEmpty else { return }
                        profile.quickKeys.append(QuickKey(
                            id: UUID().uuidString,
                            label: newKeyLabel,
                            keys: newKeyString,
                            isEnter: newKeyIsEnter
                        ))
                        newKeyLabel = ""
                        newKeyString = ""
                    }) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newKeyLabel.isEmpty)
                }
            } header: {
                Text("Quick Keys")
            } footer: {
                Text("Keys shown when this profile matches. Toggle ↵ to send Enter after the key.")
            }
        }
        .navigationTitle(profile.name.isEmpty ? "New Profile" : profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(profile)
                    dismiss()
                }
                .disabled(profile.name.isEmpty || profile.outputPatterns.isEmpty)
            }
        }
    }
}
