import SwiftUI
import ServiceManagement

/// SettingsView is the content of the app's Settings scene. macOS renders it
/// in the canonical "preferences window" chrome with toolbar + grouped form.
struct SettingsView: View {
    @EnvironmentObject var bento: BentoCLI
    @State private var relayURL: String = ""
    @State private var launchAtLogin: Bool = LoginItem.isEnabled
    @State private var loginErr: String?
    @State private var applying = false
    @State private var applied = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            relayTab
                .tabItem { Label("Relay", systemImage: "network") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 320)
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
                            // Revert UI to actual state.
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
