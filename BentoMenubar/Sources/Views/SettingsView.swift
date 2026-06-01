import SwiftUI
import ServiceManagement
import BentoTerminalCore
import UniformTypeIdentifiers

/// SettingsView is the content of the app's Settings scene. macOS renders it
/// in the canonical "preferences window" chrome with toolbar + grouped form.
struct SettingsView: View {
    @EnvironmentObject var bento: BentoCLI
    @ObservedObject private var themeStore = ThemeStore.shared
    @State private var relayURL: String = ""
    @State private var launchAtLogin: Bool = LoginItem.isEnabled
    @State private var loginErr: String?
    @State private var applying = false
    @State private var applied = false
    @State private var preferredTerminal: TerminalAppKind = TerminalAppKind.preferred
    @AppStorage("terminal_font_size") private var fontSize: Double = 13
    @AppStorage("terminal_font_family") private var fontFamily: String = "sf-mono"
    @State private var showThemeImporter = false
    @State private var importError: String?

    private let fontFamilies: [(token: String, label: String)] = [
        ("sf-mono", "SF Mono"), ("menlo", "Menlo"),
        ("jetbrains", "JetBrains Mono"), ("maple-nf-cn", "Maple Mono NF CN"),
        ("courier", "Courier"),
    ]

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            terminalTab
                .tabItem { Label("Terminal", systemImage: "terminal") }
            relayTab
                .tabItem { Label("Relay", systemImage: "network") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 360)
    }

    // MARK: - Terminal (font + theme)

    private var terminalTab: some View {
        Form {
            Section {
                HStack {
                    Text("Font size")
                    Slider(value: $fontSize, in: 8...24, step: 1)
                    Text("\(Int(fontSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
                }
                .onChange(of: fontSize) { _, _ in
                    NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
                }
                Picker("Font", selection: $fontFamily) {
                    ForEach(fontFamilies, id: \.token) { Text($0.label).tag($0.token) }
                }
                .onChange(of: fontFamily) { _, _ in
                    NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
                }
            } header: { Text("Font") }

            Section {
                Picker("Theme", selection: Binding(
                    get: { themeStore.current.id },
                    set: { themeStore.select(id: $0) }
                )) {
                    ForEach(themeStore.allThemes) { Text($0.name).tag($0.id) }
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
                Text("Applies live to open Bento terminal windows.")
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
                Picker("Open tmux sessions in", selection: $preferredTerminal) {
                    ForEach(TerminalAppKind.allInstalled) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .onChange(of: preferredTerminal) { _, new in
                    TerminalAppKind.preferred = new
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text(terminalFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var terminalFooter: String {
        if preferredTerminal.isNative {
            return "Sessions open in Bento's own tiled terminal (libghostty + `tmux -CC`), in-app."
        }
        return preferredTerminal.supportsTmuxControlMode
            ? "Bento attaches with `tmux -CC` so \(preferredTerminal.displayName) renders each tmux pane as a native window."
            : "Bento attaches with plain `tmux attach`; \(preferredTerminal.displayName) shows the standard tmux UI."
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
            Text("Mac menubar companion for the Bento iOS terminal.")
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
