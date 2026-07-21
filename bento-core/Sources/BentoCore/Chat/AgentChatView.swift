import ACPKit
import MarkdownUI
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

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

    /// Highlighted row in the slash-command completion panel. Lives here (not
    /// in the composer view) because the panel is rendered OUTSIDE the pane —
    /// by the platform pane host, above the tiled panes — so it escapes the
    /// pane's clip without stealing the composer's keyboard focus. The
    /// composer drives it from ↑/↓; the host reads it to paint the selection.
    @Published public var slashSelection = 0

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

// MARK: - Copy

/// Cross-platform clipboard write. Assistant prose renders as MarkdownUI blocks,
/// which are separate SwiftUI views — `.textSelection` can't drag across them —
/// so one-click copy is how you lift a whole answer or a code block out.
enum AcpClipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// A small copy affordance that flashes a checkmark for feedback. Its reveal
/// (hover opacity) is the caller's job; this owns only the click + confirmation.
struct AcpCopyButton: View {
    let text: String
    var help: String = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            AcpClipboard.copy(text)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? AcpPalette.done : Color.secondary)
                .frame(width: 22, height: 22)
                .background(AcpPalette.panel, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(AcpPalette.panelBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : help)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }
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

extension View {
    /// A restrained elevation shadow for the FLOATING chat cards (plan +
    /// interruption prompts). Deliberately small (radius 4, opacity 0.12):
    /// these are one or two on screen and mostly sit over STATIC content
    /// (interruption cards show while the turn is paused for input), so the
    /// compositor just caches them. This is nothing like the composer's old
    /// large shadow, which re-composited over the streaming tail every frame,
    /// times every pane. The cards render as an opaque rounded rect on
    /// transparent padding, so the shadow hugs that shape, not the bounds.
    func acpFloatingCardShadow() -> some View {
        shadow(color: .black.opacity(0.12), radius: 4, y: 1.5)
    }

    /// Claim the normal arrow pointer over a floating card's opaque body.
    /// AppKit resolves the cursor from the view whose tracking area sits under
    /// the pointer — NOT z-order — so the composer NSTextView's I-beam (and the
    /// selectable transcript's) bled up through a card drawn on top of it.
    /// `.pointerStyle` (macOS 15+) registers with the pointer system properly,
    /// so the frontmost card wins. macOS only; touch platforms have no pointer.
    @ViewBuilder func acpCardPointer() -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            pointerStyle(.default)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension AnyTransition {
    /// Floating cards settle into place from a small offset toward their own
    /// edge, plus a fade — a gentle arrival, not a full-height slide. Cheap:
    /// it runs once on appear/dismiss, not per frame.
    static var acpCardDropFromTop: AnyTransition {
        .opacity.combined(with: .offset(y: -12))
    }
    static var acpCardRiseFromBottom: AnyTransition {
        .opacity.combined(with: .offset(y: 12))
    }
}

/// Measures the natural height of a floating card's content.
private struct AcpCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A card floating over the transcript at `alignment`, HEIGHT-CAPPED to the
/// pane: it hugs the card while it fits — so the transparent remainder passes
/// scroll gestures straight through to the transcript below — and scrolls the
/// card internally the moment it would run past the pane. A short pane
/// (parallel mode) or a long body (a big permission diff, an expanded plan)
/// must never push its buttons or tail off screen where they can't be reached.
///
/// `gap` is the margin from the pane edge — but ONLY while the card fits. The
/// user-visible rule: a card that DOESN'T need to scroll floats with the gap;
/// a card that DOES scroll reaches the edge (no gap), giving the scroll region
/// the whole height. The gap tapers shut over the last `gap` points before the
/// switch so there's no jump.
struct AcpFloatingCard<Content: View>: View {
    var alignment: Alignment
    var gap: CGFloat = 0
    @ViewBuilder var content: Content
    @State private var cardHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.height
            let needsScroll = cardHeight > available
            // Full gap while it fits comfortably; tapering to 0 as the card
            // approaches the edge; gone entirely once it scrolls.
            let edgeGap = needsScroll ? 0 : max(0, min(gap, available - cardHeight))
            ScrollView {
                content
                    // Opaque body claims the arrow so the composer / selectable
                    // transcript beneath it can't bleed their I-beam through.
                    .acpCardPointer()
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(key: AcpCardHeightKey.self, value: inner.size.height)
                        })
            }
            // No bounce / no grabbing scroll while the card fits — only the
            // over-tall case actually scrolls.
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(cardHeight, available), alignment: alignment)
            .padding(gapEdge, edgeGap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .onPreferenceChange(AcpCardHeightKey.self) { cardHeight = $0 }
            .acpFloatingCardShadow()
        }
    }

    /// The pane edge the card is docked to — where the gap goes.
    private var gapEdge: Edge.Set {
        alignment == .top ? .top : .bottom
    }
}

/// Plan (when present) + transcript + permission prompt + composer.
struct AcpSessionContentView: View {
    @ObservedObject var session: AgentSessionViewModel
    @ObservedObject var model: AgentChatModel

    /// The transcript's fixed bottom inset: the composer's worst-case height
    /// (a 3-line field + the options strip + padding). Constant so composer
    /// changes never re-inset (and re-render) the transcript.
    private static let composerReservedHeight: CGFloat = 110

    var body: some View {
        // The transcript fills the whole pane; the composer FLOATS at the
        // bottom via a safe-area inset. This decouples the composer's height
        // (growing a line, folding the options strip, adding attachments) from
        // the transcript's LAYOUT: a height change only re-insets the scroll
        // content — no row reflow, no viewport-resize churn the keep-bottom
        // ledger has to chase. Content scrolls UNDER the opaque bar; the last
        // message stops above it. The plan / interruption cards stay overlays
        // (they respect the same reduced safe area, so they sit above the bar).
        AcpTranscriptView(session: session, model: model)
            // The plan card FLOATS over the transcript's top edge rather than
            // docking: docked, expanding/collapsing it resized the viewport.
            // Collapsed it's a one-line pill; the reader rides the tail, so
            // the covered top is off screen anyway. Expanded past the pane it
            // scrolls internally (AcpFloatingCard) rather than run off screen.
            .overlay(alignment: .top) {
                if !session.plan.isEmpty {
                    AcpFloatingCard(alignment: .top) {
                        AcpPlanCard(entries: session.plan)
                    }
                    .transition(.acpCardDropFromTop)
                }
            }
            .animation(.easeOut(duration: 0.22), value: session.plan.isEmpty)
            // FIXED reserved height — sized for the worst case (a 3-line field
            // plus the options strip). Animating the inset with the composer's
            // real height re-insets the scroll content every frame, which
            // flickered the whole (MarkdownUI) transcript. A constant inset
            // keeps the transcript perfectly STATIC through any composer change
            // (strip fold, field growth); the composer floats within, and the
            // freed space above a short composer is just transparent canvas the
            // content scrolls under. `minHeight` so a rare attachment row can
            // still push past it rather than clip.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                AcpComposerBar(session: session, model: model)
                    .frame(minHeight: Self.composerReservedHeight, alignment: .bottom)
            }
            // Interruption cards float at the pane BOTTOM (small gap), LAYERED
            // ON TOP of the composer. The z-order is the whole point: the
            // composer is a safeAreaInset that draws above overlay content, so
            // the card must be added AFTER it (and ignore the bottom safe area
            // to reach the pane floor) or the bar clips its Allow/Deny buttons.
            // AcpFloatingCard caps it to the pane height and scrolls a long
            // diff / short pane internally. Mutually exclusive in practice; the
            // VStack stacks them if two ever coincide.
            .overlay(alignment: .bottom) {
                if hasInterruptionCard {
                    AcpFloatingCard(alignment: .bottom, gap: Self.floatingCardGap) {
                        VStack(spacing: 0) {
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
                            if session.isStopped {
                                AcpStoppedCard(session: session)
                            }
                        }
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                    .transition(.acpCardRiseFromBottom)
                }
            }
            .animation(.easeOut(duration: 0.22), value: hasInterruptionCard)
    }

    /// Gap between a bottom-floating interruption card and the pane floor —
    /// present while the card fits, gone once it scrolls (AcpFloatingCard).
    private static let floatingCardGap: CGFloat = 10

    /// Any bottom interruption card currently showing — gates the floating
    /// overlay so its GeometryReader isn't mounted (eating nothing, but idle)
    /// when the transcript is running clean.
    private var hasInterruptionCard: Bool {
        session.phase == .authRequired
            || session.pendingElicitation != nil
            || session.pendingPermission != nil
            || session.isStopped
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

/// Viewport-relative top (`minY` in the transcript coordinate space) of each
/// rendered row, keyed by the row's first item id. The prev/next-message nav
/// buttons read this to find which item sits at the viewport top, so a jump is
/// relative to what the reader is actually looking at.
private struct AcpRowTopsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Non-observed sink for the row tops (`AcpRowTopsKey`). A plain class so the
/// per-frame scroll updates land here WITHOUT invalidating the transcript body
/// — mutating a reference held by `@State` doesn't trip SwiftUI's change
/// detection, so this stays off the scroll hot path.
@MainActor final class AcpScrollNav {
    var rowTops: [String: CGFloat] = [:]
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
    @State private var rowsMemo = AcpRowsMemo()
    @State private var nav = AcpScrollNav()

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
    ///
    /// Memoized: this view observes the session, so its body re-evaluates on
    /// EVERY @Published change (streaming pulses, usage ticks, composer
    /// keystrokes). Regrouping each time not only walked up to `visibleLimit`
    /// items, it produced fresh arrays whose new buffer identity defeated
    /// SwiftUI's diffing for every visible row — every row body re-ran per
    /// session change (the sampled scroll-jank). Grouping depends only on
    /// item count and types (fixed at creation), so the memo keys on
    /// count/limit plus boundary identity (replay swaps the array wholesale)
    /// and hands back the SAME arrays until the transcript really changes.
    private var rows: [AcpTranscriptRowGroup] {
        rowsMemo.rows(
            visible: visibleItems, totalCount: session.items.count, limit: visibleLimit
        ) { visible in
            var rows: [AcpTranscriptRowGroup] = []
            var run: [TranscriptItem] = []
            for item in visible {
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
                                Group {
                                    switch row {
                                    case .item(let item): AcpTranscriptRow(item: item, session: session)
                                    case .toolGroup(let items): AcpToolGroupRow(items: items)
                                    }
                                }
                                // Report the row's top edge so the nav buttons
                                // can locate the user message just above/below
                                // the viewport top. Rides the existing sentinel
                                // geometry pass; lands in a non-observed sink.
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: AcpRowTopsKey.self,
                                            value: [row.anchorItemID:
                                                geo.frame(in: .named("acpTranscript")).minY])
                                    })
                            }
                            if session.isTurnActive {
                                AcpWorkingIndicator(startedAt: session.turnStartedAt)
                            }
                            // Prompts queued during the turn: pending user
                            // bubbles pinned below the live tail, above the
                            // bottom sentinel. They auto-send in order at turn
                            // end (graduating into real user rows).
                            ForEach(session.queuedMessages) { queued in
                                AcpQueuedRow(session: session, message: queued)
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
                    .onPreferenceChange(AcpRowTopsKey.self) { tops in
                        nav.rowTops = tops
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
                    // Publish the pin state so the composer can fold its options
                    // strip away while the reader is up in history (instant, no
                    // transaction). iOS only: on macOS the pane surface drives
                    // `transcriptAtBottom` from its own reliable pin flag (the
                    // SwiftUI one here can't track AppKit wheel scrolling).
                    #if os(iOS)
                    .onChange(of: pinnedToBottom) { _, atBottom in
                        model.transcriptAtBottom = atBottom
                    }
                    #endif

                    // Two subdued nav chips (copy-button style, same trailing
                    // column): up = the previous user prompt, down = the next
                    // prompt / live bottom. Each shows ONLY when it can act —
                    // down hides once you're at the bottom, up hides at the
                    // very top — so they stay out of the way until useful.
                    VStack(spacing: 6) {
                        if canJumpUp {
                            navButton("chevron.up") { jumpToPreviousUserMessage(proxy) }
                                .transition(.opacity)
                        }
                        if canJumpDown {
                            navButton("chevron.down") { jumpToNextUserMessage(proxy) }
                                .transition(.opacity)
                        }
                    }
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                    .animation(.easeInOut(duration: 0.15), value: canJumpDown)
                    .animation(.easeInOut(duration: 0.15), value: canJumpUp)
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

    // MARK: Prev/next user-message navigation

    /// Same visual as `AcpCopyButton`: a small secondary glyph in a bordered
    /// panel chip — deliberately quiet, not an accent-colored disc.
    private func navButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(width: 22, height: 22)
                .background(AcpPalette.panel, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(AcpPalette.panelBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// The up chip can act when a user prompt sits above the current viewport
    /// top; the down chip when we're not already at the live bottom (there's
    /// always the tail to fall to). `transcriptAtBottom` is the surface's
    /// reliable pin flag, so "down" hides the moment you settle near the tail.
    private var canJumpUp: Bool {
        !session.items.isEmpty && userMessageIndices().contains { $0 < topVisibleItemIndex() }
    }
    private var canJumpDown: Bool {
        !session.items.isEmpty && !model.transcriptAtBottom
    }

    /// Indices of the user's own messages within `session.items`, in order.
    private func userMessageIndices() -> [Int] {
        session.items.indices.filter { (session.items[$0] as? MessageItem)?.role == .user }
    }

    /// Index into `session.items` of the item currently at the viewport top,
    /// read from the row-tops sink. Falls back to the last item when geometry
    /// is unavailable (empty sink), so "up" still finds the newest prompt.
    private func topVisibleItemIndex() -> Int {
        let tops = nav.rowTops
        guard !tops.isEmpty else { return max(0, session.items.count - 1) }
        // The row occupying the top edge is the one whose top sits at/just
        // above it (largest minY ≤ tol). If none qualifies we're scrolled to
        // the very top, so take the first visible row (smallest minY).
        let tol: CGFloat = 12
        let anchorID = tops.filter { $0.value <= tol }.max(by: { $0.value < $1.value })?.key
            ?? tops.min(by: { $0.value < $1.value })?.key
        guard let id = anchorID,
              let idx = session.items.firstIndex(where: { $0.id == id }) else {
            return max(0, session.items.count - 1)
        }
        return idx
    }

    private func jumpToPreviousUserMessage(_ proxy: ScrollViewProxy) {
        let top = topVisibleItemIndex()
        guard let target = userMessageIndices().last(where: { $0 < top }) else { return }
        scrollToItem(at: target, proxy: proxy)
    }

    private func jumpToNextUserMessage(_ proxy: ScrollViewProxy) {
        let top = topVisibleItemIndex()
        if let target = userMessageIndices().first(where: { $0 > top }) {
            scrollToItem(at: target, proxy: proxy)
        } else {
            // No prompt below → go to the live bottom. Through the token so the
            // macOS surface's bottom ledger snaps to the tail with us.
            model.requestScrollToBottom()
        }
    }

    /// Pin a specific item to the viewport top, leaving the tail so the jump
    /// sticks. Targets older than the rendered window are revealed first.
    private func scrollToItem(at index: Int, proxy: ScrollViewProxy) {
        let items = session.items
        guard items.indices.contains(index) else { return }
        // Unpin BOTH the SwiftUI flag and the macOS surface's bottom ledger (it
        // subscribes to the same token) so the next growth pulse can't yank us
        // back down. Unanimated, like the reveal-earlier jump: one layout pass
        // moves the sentinel clear, dodging the near-bottom re-pin race.
        pinnedToBottom = false
        model.noteUserScrolledUp()
        let id = items[index].id
        if index < items.count - visibleLimit {
            visibleLimit = items.count - index + Self.revealChunk
            DispatchQueue.main.async {
                proxy.scrollTo(id, anchor: .top)
            }
        } else {
            proxy.scrollTo(id, anchor: .top)
        }
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
    /// while the reader is at the bottom. macOS opts OUT: AppKit owns
    /// keep-bottom there (AgentChatSurface's bottom anchor, enforced against
    /// REAL geometry) and SwiftUI's sizeChanges anchor competes with it
    /// using lazy ESTIMATED heights — it drifted the viewport off the tail
    /// on composer growth (see TranscriptScrollAnchorTests).
    @ViewBuilder func acpKeepBottomThroughSizeChanges() -> some View {
        #if os(macOS)
        self
        #else
        if #available(iOS 18.0, *) {
            defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            self
        }
        #endif
    }
}

extension View {
    /// Transcript text selection — enabled ONLY where it doesn't collide with a
    /// press-anywhere gesture. On iOS the whole pane is a voice surface (hold to
    /// record), and SwiftUI's `.textSelection(.enabled)` installs its own
    /// long-press → system Copy/Look-Up callout menu that fires *alongside* the
    /// voice hold (they recognize simultaneously; `cancelsTouchesInView` can't
    /// cancel the text interaction's recognizers). The result is a menu popping
    /// up every time you start speaking — so iOS opts out. macOS selects by
    /// mouse drag, which never conflicts, and keeps it.
    @ViewBuilder func acpSelectableText() -> some View {
        #if os(iOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }
}

/// Memo box for the transcript's row grouping (see `AcpTranscriptView.rows`).
/// A class so body evaluation can consult/refresh it without touching view
/// state: same key → the exact same row arrays, keeping child-view identity
/// byte-stable across unrelated session churn.
@MainActor
final class AcpRowsMemo {
    private var key: (count: Int, limit: Int, first: ObjectIdentifier?, last: ObjectIdentifier?) =
        (-1, -1, nil, nil)
    private var cached: [AcpTranscriptRowGroup] = []

    func rows(
        visible: ArraySlice<TranscriptItem>, totalCount: Int, limit: Int,
        group: (ArraySlice<TranscriptItem>) -> [AcpTranscriptRowGroup]
    ) -> [AcpTranscriptRowGroup] {
        let key = (
            totalCount, limit,
            visible.first.map(ObjectIdentifier.init),
            visible.last.map(ObjectIdentifier.init))
        if key != self.key {
            self.key = key
            cached = group(visible)
        }
        return cached
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

    /// The id of the row's FIRST underlying transcript item — the anchor the
    /// scroll-nav buttons map back to an index in `session.items` (the group's
    /// own `id` carries a "toolgroup-" prefix, so it can't be looked up there).
    var anchorItemID: String {
        switch self {
        case .item(let item): return item.id
        case .toolGroup(let items): return items.first?.id ?? id
        }
    }
}

/// Dispatches a transcript item to its row view by concrete type. Tool calls
/// and thoughts normally never land here — grouping routes them to
/// `AcpToolGroupRow`; the `.thought` arm stays as a defensive fallback.
struct AcpTranscriptRow: View {
    let item: TranscriptItem
    /// Unobserved — the agent row's copy menu reads `session.items` at click
    /// time to lift a whole answer / conversation; rows don't observe it.
    var session: AgentSessionViewModel?

    var body: some View {
        if let message = item as? MessageItem {
            switch message.role {
            case .user: AcpUserMessageRow(item: message)
            case .agent: AcpAgentMessageRow(item: message, session: session)
            case .thought: AcpThoughtRow(item: message)
            }
        } else if let notice = item as? NoticeItem {
            AcpNoticeRow(item: notice)
        }
    }
}

/// Liveness = the ticking elapsed readout (1 Hz), NOT a per-frame animation.
/// This view is on screen for the whole turn, once PER visible working pane;
/// a continuous `.symbolEffect` / spinner here forced a Core-Animation commit
/// every display frame, and — multiplied across parallel panes — drove the
/// window's compositor to ~40% CPU on a fanless M2 Air (main thread stayed
/// idle; the cost was in the per-frame commit + WindowServer IPC, invisible
/// to a stack sampler). The counter already reads as alive, so a static
/// PaneState-blue dot carries the rest with zero repeating animation.
struct AcpWorkingIndicator: View {
    /// When the turn began; drives the elapsed readout. Nil hides the timer.
    var startedAt: Date?

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(AcpPalette.working)
                .frame(width: 7, height: 7)
            Text("Working")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let startedAt {
                // Built-in self-updating counter — no manual Timer, and it
                // ticks once a second (not per frame). Monospaced so the
                // digits don't jitter; this IS the "still alive" cue now.
                Text(startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
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
    /// Unobserved; only the copy menu touches it (at click time).
    var session: AgentSessionViewModel?
    #if os(macOS)
    @State private var hovering = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.images.isEmpty {
                AcpMessageImages(images: item.images)
            }
            if !item.text.isEmpty {
                Markdown(item.text)
                    .markdownTheme(.acpChat)
                    .acpSelectableText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        #if os(macOS)
        // MarkdownUI blocks can't be drag-selected across, so give the whole
        // message a one-click copy of its raw markdown. The chip is an OVERLAY
        // (no reserved row, no layout shift) pinned bottom-RIGHT: prose is
        // left-aligned, so the last line's trailing edge is usually whitespace —
        // the chip lands there instead of on top of text. It fades in on hover;
        // contentShape makes the whole row one stable hover target. Right-click too.
        .overlay(alignment: .bottomTrailing) {
            if !item.text.isEmpty {
                AcpCopyButton(text: item.text, help: "Copy message")
                    .padding(.trailing, 12)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
        }
        .contentShape(Rectangle())
        // Track which message the cursor is over so the surface's right-click
        // menu can scope copy-message / copy-answer to it. (macOS owns
        // right-click for the voice gesture + its native menu, so SwiftUI's own
        // .contextMenu never fires on these rows — the menu lives in
        // AgentChatSurface.showChatContextMenu.)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.1)) { hovering = inside }
            if inside {
                session?.hoveredMessage = item
            } else if session?.hoveredMessage === item {
                session?.hoveredMessage = nil
            }
        }
        #endif
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
                        .acpSelectableText()
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

/// A prompt queued while a turn runs, shown at the transcript bottom as a
/// PENDING user bubble — dashed, dimmed, clock-tagged — so it reads as "lined
/// up next" rather than already sent. It graduates into a real `AcpUserMessageRow`
/// when the turn finishes and it auto-sends (or on tap, when idle). × drops it.
struct AcpQueuedRow: View {
    @ObservedObject var session: AgentSessionViewModel
    let message: QueuedMessage

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 48)
            Image(systemName: "clock")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 9)
            VStack(alignment: .trailing, spacing: 4) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .acpSelectableText()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(AcpPalette.userBubble.opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(AcpPalette.panelBorder,
                                              style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                if !message.attachments.isEmpty {
                    Label("\(message.attachments.count) image"
                            + (message.attachments.count == 1 ? "" : "s"),
                          systemImage: "paperclip")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Button {
                session.removeQueuedMessage(message.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // Tap sends now when idle (e.g. after a cancel parked the queue); while
        // a turn runs `sendQueuedMessageNow` no-ops and it just waits its turn.
        .onTapGesture { session.sendQueuedMessageNow(message.id) }
        .help(session.isTurnActive ? "Queued — sends when this turn finishes" : "Tap to send now")
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
                expanded.toggle()  // snap — see AcpPlanCard for why not animated
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
                    .acpSelectableText()
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
                    .acpSelectableText()
                if item.detail != nil {
                    Button {
                        showDetail.toggle()  // snap — see AcpPlanCard
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
            AcpCodeBlock(configuration: configuration)
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

/// A fenced code block with a hover-revealed copy button (macOS). Copying the
/// raw source is the fast path for a coding agent's output — no drag-select.
struct AcpCodeBlock: View {
    let configuration: CodeBlockConfiguration
    #if os(macOS)
    @State private var hovering = false
    #endif

    var body: some View {
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
        #if os(macOS)
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            AcpCopyButton(text: configuration.content, help: "Copy code")
                .padding(6)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.1)) { hovering = inside }
        }
        #endif
    }
}
