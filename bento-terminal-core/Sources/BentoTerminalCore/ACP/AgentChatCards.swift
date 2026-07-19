import ACPKit
import SwiftUI

// Card views for the ACP chat transcript: tool calls (+ diffs), plan,
// permission prompt, and the composer bar. Split from AgentChatView.swift
// for readability; same platform-neutral rules (system colors, PaneState
// accents, mono only for code/diff/tool output).

// MARK: - Tool call card

/// A tool invocation card: kind icon, title, live status, expandable output
/// (plain text and/or diffs). Failed calls auto-expand.
struct AcpToolCallCard: View {
    @ObservedObject var item: ToolCallItem
    @Environment(\.acpOpenFile) private var openFile
    @State private var expanded = false
    @State private var autoExpandedOnFailure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)

            if expanded {
                detail
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(AcpPalette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .onChange(of: item.status) { _, status in
            if status == .failed && !autoExpandedOnFailure {
                autoExpandedOnFailure = true
                expanded = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)

            Text(item.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let location = item.locations.first {
                pathLink(path: location.path, line: location.line,
                         label: (location.path as NSString).lastPathComponent)
            }

            Spacer(minLength: 8)

            statusBadge
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// A file path: clickable (opens the host preview) when the surface wired
    /// an open action, plain mono text otherwise.
    @ViewBuilder
    private func pathLink(path: String, line: Int?, label: String) -> some View {
        if let openFile {
            Button {
                openFile(path, line)
            } label: {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .underline()
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Preview \(path)")
        } else {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case .pending, .inProgress:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(AcpPalette.done)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(AcpPalette.failed)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(item.diffs.enumerated()), id: \.offset) { _, diff in
                VStack(alignment: .leading, spacing: 4) {
                    pathLink(path: diff.path, line: nil, label: diff.path)
                    AcpDiffView(oldText: diff.oldText, newText: diff.newText)
                }
            }

            let output = item.textOutput
            if !output.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(output.count > 8000 ? String(output.suffix(8000)) : output)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 260)
                .background(AcpPalette.codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if item.diffs.isEmpty && output.isEmpty {
                Text("No output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var iconName: String {
        switch item.kind {
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .delete: return "trash"
        case .move: return "arrow.right.doc.on.clipboard"
        case .search: return "magnifyingglass"
        case .execute: return "terminal"
        case .think: return "brain"
        case .fetch: return "globe"
        case .switchMode: return "arrow.triangle.2.circlepath"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Diff view

/// Unified line diff computed with CollectionDifference (Myers). Long
/// unchanged runs collapse to keep tool cards compact.
struct AcpDiffView: View {
    struct Line: Identifiable {
        enum Kind { case added, removed, context, ellipsis }
        let id: Int
        let kind: Kind
        let text: String
    }

    let lines: [Line]

    init(oldText: String?, newText: String) {
        self.lines = Self.compute(oldText: oldText ?? "", newText: newText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                HStack(spacing: 0) {
                    Text(prefix(for: line.kind))
                        .frame(width: 16, alignment: .center)
                    Text(line.text.isEmpty ? " " : line.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                }
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(line.kind == .ellipsis ? Color.secondary : Color.primary)
                .padding(.vertical, 1)
                .padding(.horizontal, 6)
                .background(background(for: line.kind))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
    }

    private func prefix(for kind: Line.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        case .ellipsis: return "⋯"
        }
    }

    private func background(for kind: Line.Kind) -> Color {
        switch kind {
        case .added: return AcpPalette.diffAdded
        case .removed: return AcpPalette.diffRemoved
        case .context, .ellipsis: return .clear
        }
    }

    static func compute(oldText: String, newText: String, context: Int = 2) -> [Line] {
        let oldLines = oldText.components(separatedBy: "\n")
        let newLines = newText.components(separatedBy: "\n")

        // New-file case: everything added.
        if oldText.isEmpty {
            return newLines.prefix(400).enumerated().map {
                Line(id: $0.offset, kind: .added, text: $0.element)
            }
        }

        let diff = newLines.difference(from: oldLines)
        var removedAt = Set<Int>()
        var insertedAt: [Int: [String]] = [:]
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedAt.insert(offset)
            case .insert(let offset, let element, _): insertedAt[offset, default: []].append(element)
            }
        }

        // Walk the old file, emitting removed/context lines and splicing
        // insertions at their new-file offsets.
        var raw: [Line] = []
        var id = 0
        var newIndex = 0
        func emitInsertions() {
            while let inserted = insertedAt[newIndex], !inserted.isEmpty {
                for text in inserted {
                    raw.append(Line(id: id, kind: .added, text: text))
                    id += 1
                }
                insertedAt[newIndex] = nil
                newIndex += inserted.count
            }
        }
        for (oldIndex, text) in oldLines.enumerated() {
            if removedAt.contains(oldIndex) {
                // Removals before the insertions that replace them —
                // conventional unified-diff hunk order.
                raw.append(Line(id: id, kind: .removed, text: text))
                id += 1
            } else {
                emitInsertions()
                raw.append(Line(id: id, kind: .context, text: text))
                id += 1
                newIndex += 1
            }
        }
        emitInsertions()

        // Collapse unchanged runs longer than 2*context+1.
        var result: [Line] = []
        var contextRun: [Line] = []
        var seenChange = false
        func flushRun(isEnd: Bool) {
            if contextRun.count <= 2 * context + 1 {
                result.append(contentsOf: contextRun)
            } else {
                if seenChange {
                    result.append(contentsOf: contextRun.prefix(context))
                }
                result.append(Line(id: -result.count - 1000, kind: .ellipsis, text: ""))
                if !isEnd {
                    result.append(contentsOf: contextRun.suffix(context))
                }
            }
            contextRun = []
        }
        for line in raw {
            if line.kind == .context {
                contextRun.append(line)
            } else {
                flushRun(isEnd: false)
                seenChange = true
                result.append(line)
            }
        }
        flushRun(isEnd: true)
        return Array(result.prefix(500))
    }
}

// MARK: - Plan card

/// The agent's current plan, pinned above the transcript. Collapses to a
/// progress summary line.
struct AcpPlanCard: View {
    let entries: [PlanEntry]
    @State private var expanded = false

    private var completed: Int { entries.filter { $0.status == .completed }.count }
    private var active: PlanEntry? { entries.first { $0.status == .inProgress } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                    Text(active?.content ?? "Plan")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(completed)/\(entries.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: symbol(for: entry.status))
                                .font(.system(size: 11))
                                .foregroundStyle(color(for: entry.status))
                            Text(entry.content)
                                .font(.system(size: 12))
                                .foregroundStyle(entry.status == .completed ? Color.secondary : Color.primary)
                                .strikethrough(entry.status == .completed, color: .secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 9)
            }
        }
        .background(AcpPalette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func symbol(for status: PlanEntry.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted.circle"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func color(for status: PlanEntry.Status) -> Color {
        switch status {
        case .pending: return .secondary
        case .inProgress: return AcpPalette.working
        case .completed: return AcpPalette.done
        }
    }
}

// MARK: - Permission prompt

/// Inline permission prompt above the composer: what the agent wants plus
/// the agent-provided options. Allow options render prominent.
struct AcpPermissionCard: View {
    let prompt: PermissionPrompt
    let respond: (RequestPermissionOutcome) -> Void

    private var toolCall: ToolCallUpdate { prompt.request.toolCall }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(AcpPalette.awaiting)
                Text("Permission needed")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            Text(toolCall.title ?? toolCall.toolCallId)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .lineLimit(3)

            if let command = commandPreview {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .background(AcpPalette.codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 8) {
                ForEach(prompt.request.options, id: \.optionId) { option in
                    if isAllow(option.kind) {
                        Button(option.name) {
                            respond(.selected(optionId: option.optionId))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button(option.name) {
                            respond(.selected(optionId: option.optionId))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                Spacer()
            }
        }
        .padding(12)
        .background(AcpPalette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(AcpPalette.awaiting.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func isAllow(_ kind: PermissionOption.Kind) -> Bool {
        kind == .allowOnce || kind == .allowAlways
    }

    /// Best-effort command/detail preview from the tool call's raw input.
    private var commandPreview: String? {
        guard let input = toolCall.rawInput else { return nil }
        for key in ["command", "cmd", "script", "filePath", "path", "pattern"] {
            if let value = input[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }
}

// MARK: - Composer

/// The prompt composer: growing text field, send (⏎ or ⌘⏎) / stop while a
/// turn runs. Voice arrives through the surface's right-click-hold compass
/// (host-wired), not a bar control.
struct AcpComposerBar: View {
    @ObservedObject var session: AgentSessionViewModel
    @ObservedObject var model: AgentChatModel
    @FocusState private var focused: Bool

    private var draft: Binding<String> {
        Binding(get: { session.composerDraft }, set: { session.composerDraft = $0 })
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineLimit(1...10)
                .focused($focused)
                .onSubmit(send)
                .disabled(session.phase != .ready)

            if session.isTurnActive {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AcpPalette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 4)
        .onAppear { focused = true }
        .onChange(of: model.composerFocusToken) { _, _ in focused = true }
    }

    private var canSend: Bool {
        session.phase == .ready && !session.isTurnActive
            && !session.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        switch session.phase {
        case .starting: return "Starting \(session.preset.name)…"
        case .ready: return session.isTurnActive ? "Agent is working…" : "Message \(session.preset.name)"
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
