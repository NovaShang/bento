import ACPKit
import SwiftUI

// The prompt composer: growing text field, send / stop, queued-message
// chips, the slash-command completion panel, and the capability strip
// (modes / models / usage) the agent negotiated.

// MARK: - Composer

/// The prompt composer: growing text field, send (⏎ or ⌘⏎) / stop while a
/// turn runs. Voice arrives through the surface's right-click-hold compass
/// (host-wired), not a bar control. A capability strip above the field
/// exposes what the agent negotiated: session modes, models, usage — plus a
/// slash-command completion panel while the draft is a command prefix.
struct AcpComposerBar: View {
    @ObservedObject var session: AgentSessionViewModel
    @ObservedObject var model: AgentChatModel
    /// The platform text editor's measured content height (0 until first
    /// layout); clamped into [oneLine, maxEditorHeight] for the field frame.
    @State private var editorHeight: CGFloat = 0
    /// The options strip's natural height, measured from a hidden copy so the
    /// accordion frame can animate between 0 and it. Seeded with a sensible
    /// default so a launch at the tail doesn't flash an empty slot.
    @State private var stripHeight: CGFloat = 28

    /// One line's worth of composer height — the field's floor before content
    /// (and the frame while `editorHeight` is still 0).
    private static let oneLineHeight: CGFloat = 24
    /// Each additional wrapped/entered line of the 13.5-pt body font.
    private static let lineHeight: CGFloat = 17
    /// The field grows to three lines, then scrolls internally.
    private static let maxEditorHeight: CGFloat = oneLineHeight + lineHeight * 2

    private var draft: Binding<String> {
        Binding(get: { session.composerDraft }, set: { session.composerDraft = $0 })
    }

    var body: some View {
        VStack(spacing: 6) {
            // Queued prompts render at the transcript BOTTOM (as pending user
            // bubbles), not here — see AcpQueuedRow in AgentChatView.
            if !session.composerAttachments.isEmpty {
                AcpAttachmentsRow(session: session)
            }
            // The options strip folds away while the reader is up in history
            // (that vertical space goes back to the transcript) and returns at
            // the live tail. Gated on `transcriptAtBottom` (the pin flag), NOT
            // raw scroll position, which used to yank the viewport.
            //
            // ACCORDION, not a pop: the strip's HEIGHT animates 0 <-> full
            // (with a fade), so the composer smoothly grows/shrinks. That's
            // what lets the whole fold move as ONE motion — the floating
            // transcript's safeAreaInset only animates if the inset content's
            // HEIGHT animates (a conditional insert's opacity transition
            // reserves the height instantly → the jump). The driving
            // `.animation(.smooth)` lives OUTSIDE this view, in AgentChatView
            // wrapping the safeAreaInset — inside the inset content it does
            // NOT reach the inset (measured: it jumps). A hidden fixed-size
            // copy measures the natural height so the frame can animate to it.
            if hasStrip {
                AcpComposerStrip(session: session)
                    .frame(height: showStrip ? stripHeight : 0, alignment: .top)
                    .opacity(showStrip ? 1 : 0)
                    .clipped()
                    .background {
                        AcpComposerStrip(session: session)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .allowsHitTesting(false)
                            .background {
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: AcpStripHeightKey.self, value: geo.size.height)
                                }
                            }
                    }
                    .onPreferenceChange(AcpStripHeightKey.self) { h in
                        if h > 0 { stripHeight = h }
                    }
            }
            HStack(alignment: .bottom, spacing: 8) {
                if session.canAttachImages {
                    AcpAttachButton(session: session)
                }
                composerInput

                if session.isTurnActive {
                    if canSend {
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle")
                                .font(.system(size: 20))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Queue for when this turn finishes")
                    }
                    Button(action: session.cancelTurn) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(AcpPalette.awaiting)
                    }
                    .buttonStyle(.plain)
                    .help("Stop the current turn")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        // No box: the composer is a docked bar on the same canvas as the
        // transcript, set off by a single hairline. Edge-to-edge so the
        // divider spans the full pane width; the field's own affordance is
        // the send glyph, not a border.
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
            // Opaque canvas fill, no drop shadow: the shadow's soft blur
            // extended UP into the transcript's live tail (where the Working
            // indicator and each streaming line land), so every repaint of
            // that region forced the WindowServer to re-blur the shadow —
            // wasted compositor work for a purely decorative lift. The
            // hairline carries the separation on its own, on every theme.
        .background(composerCanvas)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AcpPalette.panelBorder)
                .frame(height: 1)
        }
        // The completion panel floats OUTSIDE the composer view so it can't
        // reflow the transcript or get clipped by the pane. On macOS the pane
        // host (`AgentChatSurface`) renders it above the tiled panes, anchored
        // to this field, keeping the composer's keyboard focus. iOS keeps the
        // in-view overlay for now (a follow-up moves it to the pane container).
        #if os(iOS)
        .overlay(alignment: .top) {
            if !slashMatches.isEmpty {
                AcpSlashCommandPanel(
                    matches: slashMatches, selection: model.slashSelection,
                    accept: { accept($0) })
                    .padding(.horizontal, 12)
                    // Sit the panel's bottom 6 pt above the bar's top edge.
                    .alignmentGuide(.top) { $0[.bottom] + 6 }
            }
        }
        #endif
        // NB: the fold's `.animation(.smooth)` is applied by AgentChatView,
        // OUTSIDE the safeAreaInset — placed here (inside the inset content)
        // it animates the strip but the transcript's inset jumps (measured).
        .onChange(of: session.composerDraft) { _, _ in
            model.slashSelection = min(model.slashSelection, max(0, slashMatches.count - 1))
        }
    }

    /// The options strip shows at the live tail (and only when the agent gave
    /// us something to put in it). Folded away while reading history.
    private var showStrip: Bool { hasStrip && model.transcriptAtBottom }

    /// The chat's canvas color (terminal theme background, else system) so the
    /// bar reads as part of the same surface — only the hairline + shadow set
    /// it apart.
    private var composerCanvas: Color {
        model.themeBackground.map(AcpPalette.stateColor) ?? AcpPalette.background
    }

    /// The text input, backed by a platform text view (NSTextView / UITextView)
    /// so big pastes and long drafts stay smooth and scroll internally —
    /// SwiftUI's `TextField(axis:.vertical)` re-lays out the whole string on
    /// every render, which hangs on large text.
    private var composerInput: some View {
        AcpComposerTextEditor(
            text: draft,
            measuredHeight: $editorHeight,
            isEditable: session.phase == .ready,
            maxHeight: Self.maxEditorHeight,
            focusToken: model.composerFocusToken,
            highlightLength: commandHighlightLength,
            onReturn: handleReturnKey,
            onArrow: handleArrowKey,
            onTab: handleTabKey,
            onEscape: handleEscapeKey)
        .frame(height: min(max(editorHeight, Self.oneLineHeight), Self.maxEditorHeight))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if session.composerDraft.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 5)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
            }
        }
    }

    /// UTF-16 length of the leading "/command" token to accent-highlight.
    /// macOS paints it via layout-manager temporary attributes; iOS skips it
    /// for now (the slash panel still shows the completion).
    private var commandHighlightLength: Int {
        #if os(macOS)
        session.recognizedCommandToken.map { ($0 as NSString).length } ?? 0
        #else
        0
        #endif
    }

    /// Plain Return in the editor: accept an open slash completion, else send.
    /// (Shift+Return inserts a newline — handled in the editor itself.)
    private func handleReturnKey() {
        if !slashMatches.isEmpty {
            accept(slashMatches[min(model.slashSelection, slashMatches.count - 1)])
        } else {
            send()
        }
    }

    /// ↑/↓ move the slash selection when the panel is open; otherwise let the
    /// caret move (return false = not consumed).
    private func handleArrowKey(_ delta: Int) -> Bool {
        let count = slashMatches.count
        guard count > 0 else { return false }
        model.slashSelection = (model.slashSelection + delta + count) % count
        return true
    }

    private func handleTabKey() -> Bool {
        guard !slashMatches.isEmpty else { return false }
        accept(slashMatches[min(model.slashSelection, slashMatches.count - 1)])
        return true
    }

    private func handleEscapeKey() -> Bool {
        guard session.isTurnActive else { return false }
        session.cancelTurn()
        return true
    }

    private var hasStrip: Bool {
        session.configOptions.contains(where: \.isRenderableSelect)
            || (session.modes?.availableModes.count ?? 0) >= 2
            || (session.models?.availableModels.count ?? 0) >= 2
            || session.usage != nil
    }

    // MARK: Slash commands (logic lives on the session; shared with the host)

    private var slashMatches: [AvailableCommand] { session.slashCommandMatches }

    private func accept(_ command: AvailableCommand) {
        session.acceptSlashCommand(command)
        model.slashSelection = 0
    }

    // MARK: Send

    private var canSend: Bool {
        session.phase == .ready
            && (!session.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !session.composerAttachments.isEmpty)
    }

    private var placeholder: String {
        switch session.phase {
        case .starting: return "Starting \(session.preset.name)…"
        case .ready:
            return session.isTurnActive
                ? "Agent is working — ⏎ queues" : "Message \(session.preset.name)"
        case .authRequired: return "Sign in to \(session.preset.name) to continue"
        case .failed: return "Agent failed to start"
        case .ended: return "Agent exited"
        }
    }

    private func send() {
        guard canSend else { return }
        session.send(session.composerDraft)
        session.composerDraft = ""
    }
}

/// The options strip's natural height, measured from a hidden fixed-size copy
/// so the visible strip's frame can animate between 0 and it (an accordion).
private struct AcpStripHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The completion panel shown while the draft is a "/prefix": command name,
/// argument hint, description. ↑↓ move, tab/⏎ accept, click accepts.
struct AcpSlashCommandPanel: View {
    let matches: [AvailableCommand]
    let selection: Int
    let accept: (AvailableCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.name) { index, command in
                        Button {
                            accept(command)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("/\(command.name)")
                                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.primary)
                                if let hint = command.input?.hint, !hint.isEmpty {
                                    Text(hint)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 12)
                                Text(command.description)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .background(
                                index == selection ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(4)
            }
            .frame(height: min(CGFloat(matches.count) * 27 + 8, 210))
            .onChange(of: selection) { _, index in
                proxy.scrollTo(index)
            }
        }
        // Self-contained floating chrome: it renders in a plain view (the iOS
        // in-bar overlay, or the macOS pane-host layer above the panes), so
        // it draws its own opaque card, border, and elevation shadow. Width
        // comes from the container (bar width on iOS, an explicit frame on
        // macOS).
        .background(AcpPalette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 3)
    }
}

/// Session-negotiated context above the text field: mode switcher, model
/// switcher (menus; only when the agent offers a real choice) and the usage
/// readout on the right.
struct AcpComposerStrip: View {
    @ObservedObject var session: AgentSessionViewModel

    var body: some View {
        HStack(spacing: 6) {
            AcpConfigChips(
                session: session,
                options: session.configOptions.filter(\.isRenderableSelect),
                modes: session.modes,
                models: session.models)
            .equatable()
            Spacer(minLength: 8)
            if let usage = session.usage {
                AcpUsageReadout(usage: usage)
            }
        }
    }
}

/// The chip row proper, split out of the strip and gated by Equatable. The
/// strip observes the whole session, so during a turn it re-evaluates on
/// every @Published change (streaming appends, usage ticks, every composer
/// keystroke) — and each evaluation used to push a fresh value tree into
/// ViewThatFits, which measures options.count+1 candidate rows of full
/// Menus per layout pass (a sampled hot spot). `==` over the negotiated
/// data lets SwiftUI skip all of it until the options actually change.
private struct AcpConfigChips: View, Equatable {
    /// Unobserved — actions only (setMode / setModel / setConfigOption).
    let session: AgentSessionViewModel
    let options: [ConfigOption]
    let modes: SessionModeState?
    let models: SessionModelState?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session === rhs.session && lhs.options == rhs.options
            && lhs.modes == rhs.modes && lhs.models == rhs.models
    }

    var body: some View {
        if options.isEmpty {
            HStack(spacing: 6) { legacyChips }
        } else {
            overflowingChips
        }
    }

    /// Chips that fit stay inline; the rest fold into a trailing "…" menu.
    /// ViewThatFits picks the first candidate (most-visible → least) whose
    /// width fits the strip, so the split follows the real pane width.
    private var overflowingChips: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(0...options.count, id: \.self) { hidden in
                chipRow(hidden: hidden)
            }
        }
    }

    private func chipRow(hidden: Int) -> some View {
        let visible = options.count - hidden
        return HStack(spacing: 6) {
            ForEach(options.prefix(visible), id: \.id) { option in
                configChipMenu(option)
            }
            if hidden > 0 {
                overflowChip(Array(options.suffix(hidden)))
            }
        }
    }

    /// The folded-away options, each a submenu of its choices.
    private func overflowChip(_ hidden: [ConfigOption]) -> some View {
        Menu {
            ForEach(hidden, id: \.id) { option in
                Menu(option.name) {
                    choicesContent(for: option)
                }
            }
        } label: {
            chipLabel(icon: "ellipsis", title: "\(hidden.count)")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("\(hidden.count) more \(hidden.count == 1 ? "option" : "options")")
    }

    /// Dedicated modes/models state — the fallback for agents that don't
    /// speak configOptions.
    @ViewBuilder
    private var legacyChips: some View {
        if let modes, modes.availableModes.count >= 2 {
            chipMenu(
                icon: "slider.horizontal.3",
                title: modes.availableModes.first { $0.id == modes.currentModeId }?.name
                    ?? modes.currentModeId,
                items: modes.availableModes.map { ($0.id, $0.name, $0.description) },
                currentId: modes.currentModeId,
                select: { session.setMode($0) })
        }
        if let models, models.availableModels.count >= 2 {
            chipMenu(
                icon: "cpu",
                title: models.availableModels.first { $0.modelId == models.currentModelId }?.name
                    ?? models.currentModelId,
                items: models.availableModels.map { ($0.modelId, $0.name, $0.description) },
                currentId: models.currentModelId,
                select: { session.setModel($0) })
        }
    }

    /// One generic config option as a chip menu; grouped choices render as
    /// menu sections.
    private func configChipMenu(_ option: ConfigOption) -> some View {
        let current = option.currentStringValue
        let title =
            option.flattenedChoices.first { $0.value == current }?.name
            ?? current ?? option.name
        return Menu {
            choicesContent(for: option)
        } label: {
            chipLabel(icon: Self.iconName(for: option), title: title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help(option.description ?? option.name)
    }

    /// The choice buttons for one option — shared by the inline chip menu and
    /// the overflow submenu. Grouped choices become menu sections.
    @ViewBuilder
    private func choicesContent(for option: ConfigOption) -> some View {
        let current = option.currentStringValue
        ForEach(Array((option.options ?? []).enumerated()), id: \.offset) { _, entry in
            if let nested = entry.options {
                Section(entry.name) {
                    ForEach(Array(nested.enumerated()), id: \.offset) { _, choice in
                        configChoiceButton(option: option, choice: choice, current: current)
                    }
                }
            } else {
                configChoiceButton(option: option, choice: entry, current: current)
            }
        }
    }

    private func configChoiceButton(
        option: ConfigOption, choice: ConfigOptionChoice, current: String?
    ) -> some View {
        Button {
            if let value = choice.value {
                session.setConfigOption(id: option.id, value: value)
            }
        } label: {
            if choice.value == current {
                Label(choice.name, systemImage: "checkmark")
            } else {
                Text(choice.name)
            }
        }
        .help(choice.description ?? "")
    }

    private static func iconName(for option: ConfigOption) -> String {
        switch option.category {
        case "mode": return "slider.horizontal.3"
        case "model": return "cpu"
        case "thought_level": return "brain"
        case "model_config": return "bolt"
        default: return "gearshape"
        }
    }

    private func chipMenu(
        icon: String, title: String, items: [(id: String, name: String, description: String?)],
        currentId: String, select: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(items, id: \.id) { item in
                Button {
                    select(item.id)
                } label: {
                    if item.id == currentId {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
                .help(item.description ?? "")
            }
        } label: {
            chipLabel(icon: icon, title: title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func chipLabel(icon: String, title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .medium))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 7.5, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AcpPalette.codeBackground, in: Capsule())
        .contentShape(Capsule())
    }
}

extension ConfigOption {
    /// Worth a picker chip: a select with a real choice to make. Boolean
    /// options never occur here — the client doesn't opt into them.
    var isRenderableSelect: Bool {
        (type ?? "select") == "select" && flattenedChoices.count >= 2
    }
}

/// Context-window fill as a small donut; the full token/cost breakdown floats
/// in on hover. Falls back to a gauge glyph when no window size is known
/// (can't compute a fraction).
struct AcpUsageReadout: View {
    let usage: UsageSnapshot
    @State private var hovering = false

    /// Match the composer's send-button glyph so the donut sits in the same
    /// trailing column (both are flush to the panel's right inset).
    private static let columnWidth: CGFloat = 20

    /// Context occupancy 0…1, or nil when the window size is unknown.
    private var fraction: Double? {
        guard let used = usage.usedTokens, let size = usage.contextSize, size > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(size)))
    }

    var body: some View {
        Group {
            if let fraction {
                donut(fraction)
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.columnWidth)
        // A thin ring with a hollow centre — fill the frame so the whole
        // column is hoverable, not just the stroke pixels.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay(alignment: .bottomTrailing) {
            if hovering {
                Text(helpText)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(AcpPalette.panel, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
                    .offset(y: -24)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// Ring: faint full track + accent arc trimmed to the fill fraction,
    /// warming to amber past 75% and red past 90%.
    private func donut(_ fraction: Double) -> some View {
        ZStack {
            Circle()
                .stroke(AcpPalette.panelBorder, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(ringColor(fraction), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }

    private func ringColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: return .accentColor
        case ..<0.9: return AcpPalette.awaiting
        default: return AcpPalette.failed
        }
    }

    private func compact(_ tokens: Int) -> String {
        switch tokens {
        case ..<1000: return "\(tokens)"
        case ..<1_000_000: return String(format: "%.1fk", Double(tokens) / 1000)
        default: return String(format: "%.2fM", Double(tokens) / 1_000_000)
        }
    }

    private func costText(_ amount: Double) -> String {
        let symbol = usage.costCurrency == "USD" || usage.costCurrency == nil ? "$" : (usage.costCurrency! + " ")
        return symbol + String(format: amount < 10 ? "%.2f" : "%.0f", amount)
    }

    private var helpText: String {
        var parts: [String] = []
        if let used = usage.usedTokens, let size = usage.contextSize {
            let pct = Int((Double(used) / Double(size) * 100).rounded())
            parts.append("\(compact(used)) / \(compact(size)) tokens (\(pct)%)")
        } else if let used = usage.usedTokens {
            parts.append("\(compact(used)) tokens in context")
        }
        if let cost = usage.costAmount { parts.append("cost \(costText(cost))") }
        return parts.joined(separator: " · ")
    }
}

