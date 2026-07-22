#if os(macOS)
import SwiftUI
import AppKit

/// The "Connect your AI" card grid — the onboarding wizard's step 2 and,
/// later, Settings → AI Providers. One card per subscription the user
/// recognizes; one button runs the whole chain (install → browser sign-in →
/// verified green). Interaction contract (design session 2026-07-22):
/// one click + one browser login; green only from a real ACP session; every
/// error is one sentence + a fix button + the raw truth behind "Show details".
///
/// The four first-class providers (Claude / OpenAI Codex / Gemini / OpenCode)
/// carry real brand logos on a white app-icon chip; the rest are text-forward.
public struct ConnectProvidersView: View {
    @ObservedObject var store: ProviderConnectStore
    @State private var showMore = false

    public init(store: ProviderConnectStore) {
        self.store = store
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(store.firstScreenCards) { card in
                    ProviderCardView(card: card, store: store)
                }
            }

            // Custom disclosure: the whole row (chevron AND text) toggles.
            // A DisclosureGroup's `.tint` would also cascade into the cards'
            // prominent Connect buttons and grey them out.
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showMore.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showMore ? 90 : 0))
                    Text("More agents")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showMore {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(store.moreCards) { card in
                        ProviderCardView(card: card, store: store)
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Brand logo loading

private enum BrandLogo {
    /// Cache the loaded NSImages so scrolling/animation doesn't re-read disk.
    private static var cache: [String: Image?] = [:]

    static func image(_ id: String) -> Image? {
        if let hit = cache[id] { return hit }
        let img: Image? = Bundle.module
            .url(forResource: id, withExtension: "png", subdirectory: "ProviderIcons")
            .flatMap { NSImage(contentsOf: $0) }
            .map { Image(nsImage: $0) }
        cache[id] = img
        return img
    }
}

// MARK: - One card

struct ProviderCardView: View {
    @ObservedObject var card: ProviderCardModel
    let store: ProviderConnectStore
    @State private var showDetails = false
    @State private var hovering = false
    /// Local draft for the `.needsKey` paste field; cleared on success.
    @State private var keyDraft = ""

    private var provider: AIProvider { card.provider }
    private var logo: Image? { BrandLogo.image(provider.id) }
    /// Another card's flow is running — hold this card's buttons.
    private var otherFlowBusy: Bool {
        store.busyProviderID != nil && store.busyProviderID != provider.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            stateArea
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(hovering ? 0.10 : 0.05),
                        radius: hovering ? 9 : 5, y: hovering ? 3 : 1.5)
        }
        .overlay {
            if card.isDefault {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.green.opacity(0.07))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderColor, lineWidth: card.isDefault ? 2 : 1)
        }
        .contentShape(Rectangle())
        // Click a connected card to make it the default agent (the one a bare
        // pane spawns). Inner buttons consume their own taps.
        .onTapGesture {
            if card.phase.isConnected, !card.isDefault { store.makeDefault(card) }
        }
        .onHover { h in
            hovering = h
            let clickable = card.phase.isConnected && !card.isDefault
            (h && clickable ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .help(card.phase.isConnected && !card.isDefault ? "Click to make \(provider.name) the default agent" : "")
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: card.phase)
        .animation(.easeOut(duration: 0.2), value: card.isDefault)
    }

    private var borderColor: Color {
        if card.isDefault { return .green }
        if card.phase.isConnected { return .green.opacity(0.4) }
        return .primary.opacity(hovering ? 0.14 : 0.07)
    }

    // MARK: Header (logo chip + name + subtitle + help)

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            logoChip
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if card.isDefault {
                        Text("Default")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Capsule().fill(.green))
                    }
                }
                Text(subtitleText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                store.openSignInURL(provider.docsURL)
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("About \(provider.name)")
        }
    }

    /// White app-icon chip with the real brand logo — first-class providers
    /// only; the rest are text-forward (no icon).
    @ViewBuilder
    private var logoChip: some View {
        if let logo {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white)
                .frame(width: 36, height: 36)
                .overlay {
                    logo.resizable().aspectRatio(contentMode: .fit).padding(6)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.black.opacity(0.07), lineWidth: 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    if card.phase.isConnected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.green)
                            .background(Circle().fill(Color(nsColor: .controlBackgroundColor)).padding(1))
                            .offset(x: 4, y: 4)
                    }
                }
                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        }
    }

    private var subtitleText: String {
        if case .needsSignIn = card.phase { return "Installed — sign in to connect" }
        if case .needsKey = card.phase { return "Paste an API key to connect" }
        return provider.subtitle
    }

    // MARK: State-dependent action area

    @ViewBuilder
    private var stateArea: some View {
        switch card.phase {
        case .unknown, .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
            }

        case .notInstalled:
            VStack(alignment: .leading, spacing: 5) {
                Button("Connect") { store.connect(card) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(otherFlowBusy)
                Text("Installs and signs in · about a minute")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

        case .needsSignIn:
            Button("Sign in") { store.connect(card) }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(otherFlowBusy)

        case .needsKey:
            // Paste-your-key flow (Kimi/GLM/DeepSeek — Claude Code harness).
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SecureField("Paste your API key", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { store.submitKey(card, key: keyDraft) }
                    Button("Connect") { store.submitKey(card, key: keyDraft) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || otherFlowBusy)
                }
                if let console = provider.apiKey?.consoleURL {
                    Button("Get a key from \(provider.name) ↗") { store.openSignInURL(console) }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5))
                }
            }

        case .installing:
            VStack(alignment: .leading, spacing: 6) {
                busyLabel("Installing \(provider.name)…")
                if let line = card.progressLine {
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
                }
                detailsDisclosure
            }

        case .signingIn:
            VStack(alignment: .leading, spacing: 6) {
                busyLabel("Finish signing in — check your browser")
                HStack(spacing: 12) {
                    if let url = card.signInURL {
                        Button("Open the sign-in page again") { store.openSignInURL(url) }
                            .buttonStyle(.link).font(.system(size: 10.5))
                    }
                    Button("Cancel") { store.cancel() }
                        .buttonStyle(.plain).font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

        case .verifying:
            busyLabel("Verifying…")

        case .connected:
            connectedRow

        case .attention(let issue):
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                    Text(issue.message)
                        .font(.system(size: 11)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(fixLabel(issue.fix)) { store.fix(card) }
                        .controlSize(.small)
                        .disabled(otherFlowBusy)
                    if !card.log.isEmpty { detailsToggle }
                }
                if showDetails { detailsLog }
            }
        }
    }

    private func busyLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Connected: green status + identity. Default selection is the whole-card
    /// tap + the "Default" badge, so there's no control here.
    private var connectedRow: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Connected")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
            if let identity = card.identity {
                Text(identity)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func fixLabel(_ fix: ProviderIssue.Fix) -> String {
        switch fix {
        case .retryInstall, .retrySignIn, .installNode: return "Try again"
        case .retryVerify: return "I've signed in — retry"
        case .retryKey: return "Paste the key again"
        case .fixInstall: return "Fix install"
        }
    }

    // MARK: Details disclosure (the raw truth stays readable)

    @ViewBuilder
    private var detailsDisclosure: some View {
        detailsToggle
        if showDetails { detailsLog }
    }

    private var detailsToggle: some View {
        Button(showDetails ? "Hide details" : "Show details") { showDetails.toggle() }
            .buttonStyle(.plain)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
    }

    private var detailsLog: some View {
        ScrollView {
            Text(card.log.isEmpty ? "—" : card.log)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 84)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }
}
#endif
