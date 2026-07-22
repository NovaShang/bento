import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import BentoCore

/// FirstRunWindow is the macOS onboarding wizard (design doc §4): a five-step
/// environment-preparation flow shown on first launch INSTEAD of dropping the
/// user at a menubar icon they can't find. Its two jobs are the design doc's
/// two: get the environment actually ready (daemon, agent, account), and teach
/// the concepts the user will need (host vs. remote, agents, workspaces).
///
/// Gate: `UserDefaults firstRunCompleted_v1`, forced by BENTO_FORCE_FIRST_RUN=1
/// for testing. Skipping counts as completing (pros hate being taught).
struct FirstRunWindow: View {
    static let completedKey = "firstRunCompleted_v1"

    @EnvironmentObject var bento: BentoCLI
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int { case welcome, connect, workspace, voice, done }
    /// BENTO_FIRST_RUN_STEP=0…4 jumps straight to a step — walkthrough /
    /// screenshot hook for testing, inert in production.
    @State private var step: Step = ProcessInfo.processInfo
        .environment["BENTO_FIRST_RUN_STEP"]
        .flatMap(Int.init).flatMap(Step.init) ?? .welcome

    // Connect-your-AI state. The store runs the whole install → browser
    // sign-in → verified-green chain; the first ACTION-connected provider
    // becomes the default agent (what a bare pane spawns) — passive entry
    // probes only badge the current default, they never write it.
    @StateObject private var providers = ProviderConnectStore(
        executor: LocalProviderExecutor(),
        keyStore: KeychainProviderKeyStore(),
        defaultProviderID: { AgentWorkspaceStore.defaultPreset.id },
        onFirstConnected: { AgentWorkspaceStore.setDefaultAgentID($0.id) })
    /// Daemon health is an invisible precondition — surfaced only as a
    /// banner when it fails to start, not a checklist row.
    @State private var daemonOK = true

    // Workspace state
    @State private var workingDir: String = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Bento Projects/My First Project").path
    @State private var launchError: String?
    @State private var launched = false

    // Voice state
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @AppStorage("speech_engine") private var speechEngine = "apple"

    // Opt-in telemetry consent (done step). Default OFF, mirrors Settings.
    @ObservedObject private var telemetry = TelemetryService.shared

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(28)
            footer
        }
        .frame(width: 620, height: 700)
        .task {
            TelemetryService.shared.record(.firstRunStarted)
            await refreshChecklist()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .connect: connect
        case .workspace: workspace
        case .voice: voice
        case .done: done
        }
    }

    // MARK: - Step 1 · Welcome + the architecture picture

    private var welcome: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            VStack(spacing: 8) {
                Text("Welcome to Bento")
                    .font(.system(size: 26, weight: .bold))
                Text("Run a team of AI agents. Speak to them.\nCommand them from anywhere.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            ArchitectureDiagramView(accent: .green)
                .padding(.horizontal, 12)
            Text("This Mac is the host — the place where your agents live and work. Your phone, when you pair it later, is just the remote control.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 20)
    }

    // MARK: - Step 2 · Connect your AI

    /// Provider cards instead of an environment checklist: the user claims a
    /// subscription they already pay for; one click runs install → browser
    /// sign-in → verified green (see ConnectProvidersView / memory
    /// project-provider-connect). Already-configured machines flip green on
    /// entry with zero action.
    private var connect: some View {
        // Scrolls: expanding "More agents" grows past the fixed window height.
        ScrollView {
            connectContent
                .frame(maxWidth: .infinity, alignment: .leading)
                // Keep card shadows/borders clear of the scroll clip edge.
                .padding(.horizontal, 2)
                .padding(.bottom, 8)
        }
        .scrollIndicators(.automatic)
    }

    private var connectContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader("Connect your AI",
                       "Bento runs the coding agents you already subscribe to. Connect one to get started — your work stays between you and your provider.")

            if !daemonOK {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Bento's background service didn't start — it keeps agents alive and your phone connected.")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Retry") { Task { await startDaemonAndRefresh() } }
                        .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }

            ConnectProvidersView(store: providers)

            if providers.anyConnected {
                Label("You're ready — your agent is verified and waiting.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }

    // MARK: - Step 3 · First workspace (zero-input)

    /// The provider the workspace step launches: the connected default.
    private var connectedProvider: AIProvider? {
        providers.cards.first { $0.isDefault && $0.phase.isConnected }?.provider
            ?? providers.cards.first { $0.phase.isConnected }?.provider
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("Give \(connectedProvider?.name ?? "your agent") a workspace",
                       "A workspace is a living project site: the agent works in one folder, and everything stays put until you close it — even if you disconnect or walk away.")

            VStack(alignment: .leading, spacing: 8) {
                Text("FOLDER")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(abbreviatedDir)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { pickDirectory() }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                Text("We'll create this folder if it doesn't exist. Working on a real project? Point it there instead.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let launchError {
                Label(launchError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if launched {
                Label("Workspace launched — check the window that just opened.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        }
    }

    private var abbreviatedDir: String {
        (workingDir as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Step 4 · First voice command

    private var voice: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("Talk to your agent",
                       "Voice is the fastest way to give instructions — no window switching, no typing.")

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.green)
                    Text("Bento turns your speech into instructions on this Mac. Audio is used for transcription only — nothing is stored.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch micStatus {
                case .authorized:
                    Label("Microphone enabled", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .denied, .restricted:
                    Label("Microphone denied — enable it in System Settings → Privacy → Microphone", systemImage: "xmark.circle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                default:
                    Button("Enable microphone") {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            Task { @MainActor in
                                micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))

            VStack(alignment: .leading, spacing: 8) {
                Text("Try it in your workspace:")
                    .font(.system(size: 14, weight: .semibold))
                Label {
                    Text("**Hold right-click** on an agent's pane and speak. Release to send — slide up to send instantly, down to cancel.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "cursorarrow.click.badge.clock").foregroundStyle(.green)
                }
                Label {
                    Text("First mission idea: *“Build me a snake game as a single web page, then open it in the browser.”*")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lightbulb").foregroundStyle(.green)
                }
                Label {
                    Text("While it works, the pane's title turns **blue**. **Amber** means it needs your answer. You watch colors, not text.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.blue)
                }
            }

            if Locale.preferredLanguages.first?.hasPrefix("zh") == true, speechEngine == "apple" {
                HStack(spacing: 10) {
                    Text("说中文?Qwen 引擎对中文和中英混说准得多 — 免费、免配置。")
                        .font(.system(size: 13))
                    Spacer()
                    Button("切换到 Qwen") { speechEngine = "qwen" }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
            }
        }
    }

    // MARK: - Step 5 · Done + cross-guidance

    private var done: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("You're set up",
                       "Your workspace is live. Two ways to level up from here:")

            doneCard(
                symbol: "square.grid.2x2",
                title: "Open a second agent",
                detail: "Agents work in parallel — one writes code while another researches. Each gets its own box."
            ) {
                Button("New agent workspace…") { Windows.show(.wizard, env: bento) }
            }

            doneCard(
                symbol: "iphone",
                title: "Put Bento in your pocket",
                detail: "Install Bento on your iPhone or iPad and pair it — then command these same agents from the sofa, or anywhere."
            ) {
                HStack(alignment: .top, spacing: 16) {
                    if let qr = QRCodeImage.make("https://bento.novashang.com/ios", size: 96) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 96, height: 96)
                            .padding(4)
                            .background(Color.white)
                            .cornerRadius(6)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Scan to get the app\n2. In the app choose “I have a Mac”\n3. Show it the pairing code:")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("Show pairing code…") { Windows.show(.pair, env: bento) }
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "menubar.arrow.up.rectangle")
                    .foregroundStyle(.secondary)
                Text("Bento lives in your **menu bar** (top-right of the screen). Close every window — agents keep working in the background. Revisit this guide anytime: menu bar → Help.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(
                    get: { telemetry.enabled },
                    set: { telemetry.enabled = $0 }
                )) {
                    Text("Share anonymous usage statistics")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                Text("No terminal content, commands, transcripts, paths, or hostnames — ever. Events go through the same Bento relay; no third-party SDKs. Change anytime in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            .padding(.top, 2)
        }
    }

    private func doneCard(symbol: String, title: String, detail: String, @ViewBuilder accessory: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.green)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Footer navigation

    private var footer: some View {
        HStack {
            if step == .welcome {
                Button("I'm a pro — skip the tour") { finish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else if step == .connect, !providers.anyConnected {
                // Escape hatch with an honest consequence: no agent → the
                // workspace step is moot, so it skips ahead to the teaching
                // steps. Connect anytime later in Settings.
                Button("I'll connect later") { withAnimation { step = .voice } }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("You can connect anytime in Settings — Bento can't do much until you do.")
            } else if step != .done {
                Button("Back") { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome } }
            }
            Spacer()
            stepDots
            Spacer()
            primaryButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<5) { i in
                Circle()
                    .fill(i == step.rawValue ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .welcome:
            Button("Get started") { withAnimation { step = .connect } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .connect:
            Button("Continue") { withAnimation { step = .workspace } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!providers.anyConnected)
        case .workspace:
            Button(launched ? "Continue" : "Launch my first workspace") {
                if launched {
                    withAnimation { step = .voice }
                } else {
                    Task { await launchFirstWorkspace() }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .voice:
            Button("Continue") { withAnimation { step = .done } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .done:
            Button("Finish") { finish() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func refreshChecklist() async {
        // BENTO_SKIP_DAEMON=1: test hook for debug instances. `tunnel start`
        // uses a FIXED launchd label even under an isolated BENTO_HOME, so a
        // debug wizard auto-starting the daemon would bootout the user's real
        // one (killing every live agent). Visual tests must never touch launchd.
        if ProcessInfo.processInfo.environment["BENTO_SKIP_DAEMON"] == nil {
            daemonOK = await bento.status() != nil
            if !daemonOK { await startDaemonAndRefresh() }
        }
        // Silent entry probe: already-installed, already-signed-in providers
        // flip green before the user reaches the connect step.
        await providers.refreshAll()
    }

    private func startDaemonAndRefresh() async {
        try? await bento.startDaemon(relay: nil)
        daemonOK = await bento.status() != nil
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            workingDir = url.path
        }
    }

    private func launchFirstWorkspace() async {
        launchError = nil
        do {
            try FileManager.default.createDirectory(
                atPath: workingDir, withIntermediateDirectories: true)
        } catch {
            launchError = "Couldn't create the folder: \(error.localizedDescription)"
            return
        }
        let spec = BentoCore.AgentSpec(
            workspaceName: "my-first-project",
            workingDir: workingDir,
            agentCommand: connectedProvider?.seedCommand ?? "",
            layout: .solo
        )
        WorkspaceWindow.newWindow(agent: spec)
        launched = true
        TelemetryService.shared.record(.workspaceCreated)
        withAnimation { step = .voice }
    }

    private func finish() {
        // finish() is reached two ways: the welcome step's "skip the tour"
        // escape hatch, or the done step's Finish button. Same completion
        // flag either way; different funnel event.
        TelemetryService.shared.record(step == .done ? .firstRunCompleted : .firstRunSkipped)
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        dismiss()
    }
}

// MARK: - QR helper

enum QRCodeImage {
    static func make(_ string: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage else { return nil }
        let scale = size / max(ci.extent.width, 1)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
