import ACPKit
import MarkdownUI
import SwiftUI

// The SwiftUI chat content for one ACP agent session: plan card, streaming
// transcript, permission prompt, composer. Platform-neutral so iOS can embed
// the same views later; the macOS pane host embeds it via `AgentChatSurface`.
//
// Design language: clean modern GUI on SYSTEM colors (adapts to light/dark
// automatically). Monospace only where it is literally true — code, diffs,
// tool output. State-colored accents come from the canonical PaneState
// palette so chat panes speak the same status language as terminal panes.

// MARK: - Bridge model

/// The AppKit/UIKit ↔ SwiftUI bridge for one chat surface: which session is
/// shown (nil = still starting), plus one-shot tokens the host view bumps to
/// drive focus / scrolling from platform code.
@MainActor
public final class AgentChatModel: ObservableObject {
    @Published public var session: AgentSessionViewModel?
    /// Bumped when platform code wants the composer to take keyboard focus.
    @Published public private(set) var composerFocusToken = 0
    /// Bumped when platform code wants the transcript pinned back to bottom.
    @Published public private(set) var scrollToBottomToken = 0

    public init(session: AgentSessionViewModel? = nil) {
        self.session = session
    }

    public func requestComposerFocus() { composerFocusToken += 1 }
    public func requestScrollToBottom() { scrollToBottomToken += 1 }
}

// MARK: - Open-file environment

/// Injected by the embedding surface; when present, file paths in tool cards
/// and diffs become clickable and open in the host's preview dock.
struct AcpOpenFileKey: EnvironmentKey {
    static let defaultValue: ((String, Int?) -> Void)? = nil
}

extension EnvironmentValues {
    var acpOpenFile: ((String, Int?) -> Void)? {
        get { self[AcpOpenFileKey.self] }
        set { self[AcpOpenFileKey.self] = newValue }
    }
}

// MARK: - Palette

/// System colors for chrome, PaneState hexes for state accents. NOT a theme
/// system — just the shared lookups so every chat view agrees.
enum AcpPalette {
    static func stateColor(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    #if os(macOS)
    static let background = Color(nsColor: .textBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let panelBorder = Color(nsColor: .separatorColor)
    #else
    static let background = Color(uiColor: .systemBackground)
    static let panel = Color(uiColor: .secondarySystemBackground)
    static let panelBorder = Color(uiColor: .separator)
    #endif
    static let codeBackground = Color.primary.opacity(0.055)
    static let userBubble = Color.accentColor.opacity(0.1)

    static let working = stateColor(PaneState.workingHex)
    static let awaiting = stateColor(PaneState.awaitingHex)
    static let done = stateColor(PaneState.doneUnseenHex)
    static let failed = Color.red

    static let diffAdded = stateColor(PaneState.doneUnseenHex).opacity(0.16)
    static let diffRemoved = Color.red.opacity(0.13)
}

// MARK: - Root

/// One full agent conversation. Shows a starting placeholder until the
/// session view model exists.
public struct AgentChatView: View {
    @ObservedObject var model: AgentChatModel

    public init(model: AgentChatModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let session = model.session {
                AcpSessionContentView(session: session, model: model)
            } else {
                AcpStartingPlaceholder()
            }
        }
        .background(AcpPalette.background)
    }
}

/// Hosting-root wrapper: injects the surface-provided open-file action.
struct AgentChatSurfaceRoot: View {
    @ObservedObject var model: AgentChatModel
    let openFile: ((String, Int?) -> Void)?

    var body: some View {
        AgentChatView(model: model)
            .environment(\.acpOpenFile, openFile)
    }
}

struct AcpStartingPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Starting…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Plan (when present) + transcript + permission prompt + composer.
struct AcpSessionContentView: View {
    @ObservedObject var session: AgentSessionViewModel
    @ObservedObject var model: AgentChatModel

    var body: some View {
        VStack(spacing: 0) {
            if !session.plan.isEmpty {
                AcpPlanCard(entries: session.plan)
            }

            AcpTranscriptView(session: session, model: model)

            if let prompt = session.pendingPermission {
                AcpPermissionCard(prompt: prompt) { outcome in
                    session.respondPermission(outcome)
                }
            }

            AcpComposerBar(session: session, model: model)
        }
    }
}

// MARK: - Transcript

/// The scrolling transcript. Auto-follows the tail while the user is at the
/// bottom; scrolling up unpins and shows a jump-to-latest affordance. Rows
/// observe their own item object, so a streaming chunk re-renders only its
/// row at the item's coalesced (~30 ms) flush rate.
struct AcpTranscriptView: View {
    @ObservedObject var session: AgentSessionViewModel
    @ObservedObject var model: AgentChatModel
    @State private var pinnedToBottom = true

    private static let bottomID = "acp-transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(session.items) { item in
                            AcpTranscriptRow(item: item)
                        }
                        if session.isTurnActive {
                            AcpWorkingIndicator()
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                            .onAppear { pinnedToBottom = true }
                            .onDisappear { pinnedToBottom = false }
                    }
                    .padding(.vertical, 10)
                }
                .onChange(of: session.items.count) { _, _ in
                    if pinnedToBottom {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: session.isTurnActive) { _, _ in
                    if pinnedToBottom {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: model.scrollToBottomToken) { _, _ in
                    pinnedToBottom = true
                    withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }

                if !pinnedToBottom {
                    Button {
                        withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.accentColor)
                            .background(Circle().fill(AcpPalette.panel))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
        }
    }
}

/// Dispatches a transcript item to its row view by concrete type.
struct AcpTranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        if let message = item as? MessageItem {
            switch message.role {
            case .user: AcpUserMessageRow(item: message)
            case .agent: AcpAgentMessageRow(item: message)
            case .thought: AcpThoughtRow(item: message)
            }
        } else if let tool = item as? ToolCallItem {
            AcpToolCallCard(item: tool)
        } else if let notice = item as? NoticeItem {
            AcpNoticeRow(item: notice)
        }
    }
}

struct AcpWorkingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(AcpPalette.working)
                .frame(width: 7, height: 7)
                .opacity(0.4 + 0.6 * abs(sin(phase)))
            Text("Working…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: false)) {
                phase = .pi
            }
        }
    }
}

// MARK: - Message rows

/// Agent prose: full markdown. The streaming row re-renders at the coalesced
/// flush rate (~30 ms); completed rows are static.
struct AcpAgentMessageRow: View {
    @ObservedObject var item: MessageItem

    var body: some View {
        Markdown(item.text)
            .markdownTheme(.acpChat)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
    }
}

struct AcpUserMessageRow: View {
    @ObservedObject var item: MessageItem

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(item.text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AcpPalette.userBubble, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// Reasoning: collapsed to a one-line summary; expandable.
struct AcpThoughtRow: View {
    @ObservedObject var item: MessageItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption)
                    Text(item.isStreaming ? "Thinking…" : "Thought")
                        .font(.caption.weight(.medium))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(item.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

struct AcpNoticeRow: View {
    let item: NoticeItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.severity == .error ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(item.severity == .error ? AcpPalette.failed : Color.secondary)
            Text(item.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

// MARK: - Markdown theme

extension MarkdownUI.Theme {
    /// MarkdownUI theme on system colors: primary text, accent links,
    /// monospace only inside code.
    static let acpChat = MarkdownUI.Theme()
        .text {
            ForegroundColor(.primary)
            FontSize(13.5)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
            BackgroundColor(AcpPalette.codeBackground)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.86))
                    }
                    .padding(12)
            }
            .background(AcpPalette.codeBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .markdownMargin(top: 6, bottom: 6)
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.35)) }
                .markdownMargin(top: 14, bottom: 6)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.2)) }
                .markdownMargin(top: 12, bottom: 4)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.05)) }
                .markdownMargin(top: 10, bottom: 3)
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(AcpPalette.panelBorder).frame(width: 3)
                }
        }
}
