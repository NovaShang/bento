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
    /// Bumped when platform code detects a REAL user scroll toward older
    /// content (macOS wheel monitor). Unpinning rides user intent only —
    /// geometry can't tell a user scroll from streaming growth.
    @Published public private(set) var userScrolledUpToken = 0
    /// The terminal theme's background (0xRRGGBB), pushed by the host so the
    /// chat pane sits on the SAME canvas color as the old terminal panes —
    /// the window's whole look (incl. the toolbar blur) rides on it. nil =
    /// plain system background.
    @Published public var themeBackground: UInt32?
    /// True while the transcript is pinned at (or near) its live bottom. The
    /// composer reads this to collapse its options strip when the reader
    /// scrolls up into history — that vertical space goes back to content.
    @Published public var transcriptAtBottom = true

    public init(session: AgentSessionViewModel? = nil) {
        self.session = session
    }

    public func requestComposerFocus() { composerFocusToken += 1 }
    public func requestScrollToBottom() { scrollToBottomToken += 1 }
    public func noteUserScrolledUp() { userScrolledUpToken += 1 }
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
        .background(model.themeBackground.map { AcpPalette.stateColor($0) } ?? AcpPalette.background)
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

            if session.phase == .authRequired {
                AcpAuthCard(session: session)
            }

            if let elicitation = session.pendingElicitation {
                AcpElicitationCard(session: session, prompt: elicitation)
            }

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

/// Distance of the transcript's bottom sentinel from the viewport top —
/// re-pins auto-follow when the user returns to the tail.
private struct AcpBottomEdgeKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// The scrolling transcript. Auto-follow design:
/// - Layout starts AT the bottom (`defaultScrollAnchor`) — no entry crawl.
/// - The tail stays pinned via the session's growth pulse (new items AND
///   in-place growth: streaming flushes, tool merges), scrolled unanimated.
/// - Unpinning is USER-INTENT ONLY: an upward drag (iOS) or a wheel-up event
///   from the host surface (macOS). Geometry can't distinguish a user scroll
///   from content growth, so it only ever re-pins (sentinel near viewport).
/// - Long transcripts render the last `visibleLimit` items; older history
///   reveals in chunks, keeping first-frame cost bounded.
/// - Width changes (pane divider drags, sidebar toggles) reflow every row;
///   position is BOTTOM-relative through them: natively where the
///   `.sizeChanges` anchor role exists, and via the macOS surface's
///   bottom-distance ledger (which also covers the unpinned reader).
/// Rows observe their own item object, so a streaming chunk re-renders only
/// its row at the item's coalesced (~30 ms) flush rate.
struct AcpTranscriptView: View {
    @ObservedObject var session: AgentSessionViewModel
    @ObservedObject var model: AgentChatModel
    @State private var pinnedToBottom = true
    @State private var visibleLimit = AcpTranscriptView.revealChunk

    private static let bottomID = "acp-transcript-bottom"
    static let revealChunk = 300

    private var visibleItems: ArraySlice<TranscriptItem> {
        session.items.suffix(visibleLimit)
    }
    private var hiddenCount: Int { max(0, session.items.count - visibleLimit) }

    /// Visible items with runs of consecutive tool calls AND thoughts folded
    /// into one group row — that traffic renders as a single subdued summary
    /// line (expandable to the full cards), not a card stack. Prose and
    /// notices break the run and render on their own.
    private var rows: [AcpTranscriptRowGroup] {
        var rows: [AcpTranscriptRowGroup] = []
        var run: [TranscriptItem] = []
        for item in visibleItems {
            if Self.isGroupable(item) {
                run.append(item)
            } else {
                if !run.isEmpty {
                    rows.append(.toolGroup(run))
                    run = []
                }
                rows.append(.item(item))
            }
        }
        if !run.isEmpty { rows.append(.toolGroup(run)) }
        return rows
    }

    /// Tool calls and reasoning fold into the collapsed group; everything
    /// else (user/agent prose, notices) stands alone.
    private static func isGroupable(_ item: TranscriptItem) -> Bool {
        if item is ToolCallItem { return true }
        if let message = item as? MessageItem, message.role == .thought { return true }
        return false
    }

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if hiddenCount > 0 {
                                revealEarlierButton(proxy)
                            }
                            ForEach(rows) { row in
                                switch row {
                                case .item(let item): AcpTranscriptRow(item: item)
                                case .toolGroup(let items): AcpToolGroupRow(items: items)
                                }
                            }
                            if session.isTurnActive {
                                AcpWorkingIndicator()
                            }
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: AcpBottomEdgeKey.self,
                                    value: geo.frame(in: .named("acpTranscript")).minY)
                            }
                            .frame(height: 1)
                            .id(Self.bottomID)
                        }
                        .padding(.vertical, 6)
                        // Short transcripts grow from the TOP like any chat;
                        // without this, defaultScrollAnchor(.bottom) pins
                        // less-than-a-screen content to the viewport bottom.
                        .frame(minHeight: outer.size.height, alignment: .top)
                    }
                    .defaultScrollAnchor(.bottom)
                    .acpKeepBottomThroughSizeChanges()
                    .coordinateSpace(name: "acpTranscript")
                    #if os(iOS)
                    .simultaneousGesture(
                        DragGesture().onChanged { value in
                            // Finger moving down = viewing older content.
                            if value.translation.height > 12 { pinnedToBottom = false }
                        }
                    )
                    #endif
                    .onPreferenceChange(AcpBottomEdgeKey.self) { minY in
                        guard let minY else { return }
                        // Re-pin only. (Unpinning from geometry would misfire
                        // whenever growth outruns the throttled follow scroll.)
                        if minY <= outer.size.height + 60 {
                            pinnedToBottom = true
                        }
                    }
                    .onChange(of: session.items.count) { _, _ in followTail(proxy) }
                    .onChange(of: session.isTurnActive) { _, _ in followTail(proxy) }
                    .onReceive(session.transcriptGrowthPulse) { _ in followTail(proxy) }
                    .onChange(of: model.userScrolledUpToken) { _, _ in
                        pinnedToBottom = false
                    }
                    .onChange(of: model.scrollToBottomToken) { _, _ in
                        pinnedToBottom = true
                        withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                    // Mirror the pin state so the composer can collapse its
                    // options strip while the reader is up in history.
                    .onChange(of: pinnedToBottom) { _, atBottom in
                        model.transcriptAtBottom = atBottom
                    }

                    if !pinnedToBottom {
                        Button {
                            // Through the token so the macOS surface's
                            // bottom ledger snaps to the tail with us.
                            model.requestScrollToBottom()
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

    private func followTail(_ proxy: ScrollViewProxy) {
        guard pinnedToBottom else { return }
        // Unanimated: animated follows pile up against streaming and land at
        // stale offsets (the "jumps back to the middle" failure).
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }

    private func revealEarlierButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            let anchorID = visibleItems.first?.id
            visibleLimit += Self.revealChunk
            // Keep the reader where they were: the previous first row returns
            // to the viewport top after the newly-revealed rows land above it.
            if let anchorID {
                DispatchQueue.main.async {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11))
                Text("Show \(min(hiddenCount, Self.revealChunk)) earlier")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AcpPalette.codeBackground, in: Capsule())
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

private extension View {
    /// Where the anchor-role API exists, tell SwiftUI natively that size
    /// changes (streaming growth, width reflow) keep the tail on screen
    /// while the reader is at the bottom. Older OSes rely on the growth
    /// pulses — and, on macOS, the surface's bottom-distance ledger.
    @ViewBuilder func acpKeepBottomThroughSizeChanges() -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            self
        }
    }
}

/// A transcript row after grouping: one plain item, or a run of consecutive
/// tool calls and thoughts rendered as a single collapsible summary line.
/// Group identity rides on the first item's id so the row keeps its expansion
/// state while the run grows in place.
enum AcpTranscriptRowGroup: Identifiable {
    case item(TranscriptItem)
    case toolGroup([TranscriptItem])

    var id: String {
        switch self {
        case .item(let item): return item.id
        case .toolGroup(let items): return "toolgroup-\(items.first?.id ?? "?")"
        }
    }
}

/// Dispatches a transcript item to its row view by concrete type. Tool calls
/// and thoughts normally never land here — grouping routes them to
/// `AcpToolGroupRow`; the `.thought` arm stays as a defensive fallback.
struct AcpTranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        if let message = item as? MessageItem {
            switch message.role {
            case .user: AcpUserMessageRow(item: message)
            case .agent: AcpAgentMessageRow(item: message)
            case .thought: AcpThoughtRow(item: message)
            }
        } else if let notice = item as? NoticeItem {
            AcpNoticeRow(item: notice)
        }
    }
}

/// The pulse rides phaseAnimator, NOT withAnimation(.repeatForever) — a
/// repeatForever transaction leaks onto sibling layout changes, which put the
/// whole transcript's growth reflow into an endless scroll-and-reset loop.
struct AcpWorkingIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(AcpPalette.working)
                .frame(width: 7, height: 7)
                .phaseAnimator([0.35, 1.0]) { view, opacity in
                    view.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: 0.7)
                }
            Text("Working…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }
}

// MARK: - Message rows

/// Agent prose: full markdown. The streaming row re-renders at the coalesced
/// flush rate (~30 ms); completed rows are static.
struct AcpAgentMessageRow: View {
    @ObservedObject var item: MessageItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.images.isEmpty {
                AcpMessageImages(images: item.images)
            }
            if !item.text.isEmpty {
                Markdown(item.text)
                    .markdownTheme(.acpChat)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

struct AcpUserMessageRow: View {
    @ObservedObject var item: MessageItem

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if !item.images.isEmpty {
                    AcpMessageImages(images: item.images)
                }
                if !item.text.isEmpty {
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// Inline message images, capped small enough to keep the transcript flowing.
struct AcpMessageImages: View {
    let images: [Data]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                AcpImageThumbnail(data: data, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
            }
        }
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
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: item.severity == .error ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(item.severity == .error ? AcpPalette.failed : Color.secondary)
                Text(item.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if item.detail != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showDetail.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text(showDetail ? "Hide log" : "Show log")
                                .font(.caption)
                            Image(systemName: showDetail ? "chevron.down" : "chevron.right")
                                .font(.system(size: 7.5, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if showDetail, let detail = item.detail {
                AcpMonoBlock(text: detail, maxHeight: 180)
            }
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
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(
                    TableBorderStyle(.insideHorizontalBorders, color: AcpPalette.panelBorder))
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.clear, Color.clear, header: AcpPalette.codeBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
                .markdownMargin(top: 8, bottom: 8)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    FontSize(.em(0.95))
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .relativeLineSpacing(.em(0.2))
        }
}
