import ACPKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    @State private var showRawInput = false
    @State private var showRawOutput = false

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
                AcpMonoBlock(text: output)
            }

            ForEach(item.terminalIds, id: \.self) { _ in
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10.5))
                    Text("Runs in a client terminal — live view not supported yet")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            if item.diffs.isEmpty && output.isEmpty && item.terminalIds.isEmpty
                && item.rawInput == nil && item.rawOutput == nil {
                Text("No output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            rawSections
        }
    }

    /// The exact parameters sent to / returned from the tool, behind small
    /// toggles so the card stays scannable. Raw input hides once a diff
    /// already tells the story, unless asked for.
    @ViewBuilder
    private var rawSections: some View {
        let input = item.rawInput?.prettyPrinted
        let output = item.rawOutput?.prettyPrinted
        // Raw output duplicating the rendered text output is noise.
        let outputIsRedundant = output.map { $0 == item.textOutput } ?? true

        if input != nil || (output != nil && !outputIsRedundant) {
            HStack(spacing: 6) {
                if input != nil {
                    rawToggle("Input", isOn: $showRawInput)
                }
                if output != nil && !outputIsRedundant {
                    rawToggle("Output", isOn: $showRawOutput)
                }
            }
        }
        if showRawInput, let input {
            AcpMonoBlock(text: input)
        }
        if showRawOutput, let output, !outputIsRedundant {
            AcpMonoBlock(text: output)
        }
    }

    private func rawToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isOn.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 9))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                Image(systemName: isOn.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7.5, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(AcpPalette.codeBackground, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var iconName: String { Self.icon(for: item.kind) }

    static func icon(for kind: ToolKind) -> String {
        switch kind {
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

// MARK: - Mono block

/// Monospaced output block: horizontal scroll, tail-capped, selectable.
struct AcpMonoBlock: View {
    let text: String
    var maxHeight: CGFloat = 260

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text.count > 8000 ? String(text.suffix(8000)) : text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: maxHeight)
        .background(AcpPalette.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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

/// Inline permission prompt above the composer: what the agent wants — title,
/// affected files, the proposed diff when the request carries one, the exact
/// command otherwise — plus the agent-provided options. Allow options render
/// prominent; on the Mac ⌘⏎ allows and ⌘⌫ rejects.
struct AcpPermissionCard: View {
    let prompt: PermissionPrompt
    let respond: (RequestPermissionOutcome) -> Void
    @Environment(\.acpOpenFile) private var openFile
    @State private var showRawInput = false

    private var toolCall: ToolCallUpdate { prompt.request.toolCall }

    private var diffs: [(path: String, oldText: String?, newText: String)] {
        (toolCall.content ?? []).compactMap { item in
            if case .diff(let path, let old, let new) = item { return (path, old, new) }
            return nil
        }
    }

    /// Two or more distinct "proceed" paths read as a QUESTION, not a
    /// permission gate — claude-agent-acp folds AskUserQuestion and plan
    /// approval onto request_permission exactly this way.
    private var isChoiceQuestion: Bool {
        prompt.request.options.filter { isAllow($0.kind) }.count >= 2
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isChoiceQuestion ? "questionmark.bubble.fill" : "hand.raised.fill")
                    .foregroundStyle(AcpPalette.awaiting)
                Text(isChoiceQuestion ? "Agent asks" : "Permission needed")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                if let kind = toolCall.kind, !isChoiceQuestion {
                    Image(systemName: AcpToolCallCard.icon(for: kind))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }

            Text(toolCall.title ?? toolCall.toolCallId)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .lineLimit(3)

            if let locations = toolCall.locations, !locations.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(locations.prefix(3).enumerated()), id: \.offset) { _, location in
                        locationLink(location)
                    }
                    if locations.count > 3 {
                        Text("+\(locations.count - 3) more")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if !diffs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(diffs.enumerated()), id: \.offset) { _, diff in
                            VStack(alignment: .leading, spacing: 4) {
                                if diffs.count > 1 || toolCall.locations?.isEmpty != false {
                                    Text((diff.path as NSString).lastPathComponent)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                AcpDiffView(oldText: diff.oldText, newText: diff.newText)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            } else if let command = commandPreview {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .background(AcpPalette.codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // The full parameters, for when the one-line preview isn't enough
            // to decide.
            if let raw = toolCall.rawInput?.prettyPrinted, raw != commandPreview {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showRawInput.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "curlybraces")
                            .font(.system(size: 9))
                        Text("Details")
                            .font(.system(size: 10.5, weight: .medium))
                        Image(systemName: showRawInput ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7.5, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if showRawInput {
                    AcpMonoBlock(text: raw, maxHeight: 180)
                }
            }

            if isChoiceQuestion {
                // Answers as a vertical list — question options are often
                // 3-4 long labels that would crush an inline row.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(prompt.request.options.enumerated()), id: \.element.optionId) { index, option in
                        answerButton(option, isFirst: index == 0)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(prompt.request.options.enumerated()), id: \.element.optionId) { index, option in
                        optionButton(option, isFirstOfItsKind: firstIndex(allow: isAllow(option.kind)) == index)
                    }
                    Spacer()
                }
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

    @ViewBuilder
    private func optionButton(_ option: PermissionOption, isFirstOfItsKind: Bool) -> some View {
        let button = Button(option.name) {
            respond(.selected(optionId: option.optionId))
        }
        .controlSize(.small)

        if isAllow(option.kind) {
            if isFirstOfItsKind {
                button.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("⌘⏎")
            } else {
                button.buttonStyle(.borderedProminent)
            }
        } else {
            if isFirstOfItsKind {
                button.buttonStyle(.bordered)
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help("⌘⌫")
            } else {
                button.buttonStyle(.bordered)
            }
        }
    }

    private func firstIndex(allow: Bool) -> Int? {
        prompt.request.options.firstIndex { isAllow($0.kind) == allow }
    }

    /// Full-width answer row for question-shaped requests. ⌘⏎ takes the
    /// first (agent-recommended) answer.
    @ViewBuilder
    private func answerButton(_ option: PermissionOption, isFirst: Bool) -> some View {
        let button = Button {
            respond(.selected(optionId: option.optionId))
        } label: {
            Text(option.name)
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        if isFirst {
            button
                .keyboardShortcut(.return, modifiers: .command)
                .help("⌘⏎")
        } else {
            button
        }
    }

    @ViewBuilder
    private func locationLink(_ location: ToolCallLocation) -> some View {
        let label = (location.path as NSString).lastPathComponent
        if let openFile {
            Button {
                openFile(location.path, location.line)
            } label: {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .underline()
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Preview \(location.path)")
        } else {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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

// MARK: - Auth card

/// Shown when the agent answered auth_required: the agent's advertised
/// sign-in methods as buttons, the host-terminal login command when
/// in-protocol auth can't finish the job, and Retry for "I signed in
/// elsewhere". The connection stays parked underneath.
struct AcpAuthCard: View {
    @ObservedObject var session: AgentSessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key.fill")
                    .foregroundStyle(AcpPalette.awaiting)
                Text("\(session.preset.name) needs sign-in")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            if session.authMethods.isEmpty {
                Text("This agent didn't offer an in-app sign-in method.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let hint = session.preset.loginHint {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in from a terminal on the host, then retry:")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(hint)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AcpPalette.codeBackground, in: RoundedRectangle(cornerRadius: 6))
                        Button {
                            copyToPasteboard(hint)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy")
                    }
                }
            }

            HStack(spacing: 8) {
                ForEach(session.authMethods, id: \.id) { method in
                    Button(method.name) {
                        session.authenticate(methodId: method.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(method.description ?? "")
                }
                Button {
                    Task { await session.retryEstablish() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("I've signed in — try again")
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

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Composer

/// The prompt composer: growing text field, send (⏎ or ⌘⏎) / stop while a
/// turn runs. Voice arrives through the surface's right-click-hold compass
/// (host-wired), not a bar control. A capability strip above the field
/// exposes what the agent negotiated: session modes, models, usage — plus a
/// slash-command completion panel while the draft is a command prefix.
struct AcpComposerBar: View {
    @ObservedObject var session: AgentSessionViewModel
    @ObservedObject var model: AgentChatModel
    @FocusState private var focused: Bool
    @State private var slashSelection = 0

    private var draft: Binding<String> {
        Binding(get: { session.composerDraft }, set: { session.composerDraft = $0 })
    }

    var body: some View {
        VStack(spacing: 6) {
            if !slashMatches.isEmpty {
                AcpSlashCommandPanel(
                    matches: slashMatches, selection: slashSelection,
                    accept: { accept($0) })
            }

            VStack(spacing: 7) {
                if !session.queuedMessages.isEmpty {
                    AcpQueuedMessagesRow(session: session)
                }
                if !session.composerAttachments.isEmpty {
                    AcpAttachmentsRow(session: session)
                }
                if hasStrip {
                    AcpComposerStrip(session: session)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    if session.canAttachImages {
                        AcpAttachButton(session: session)
                    }
                    TextField(placeholder, text: draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .lineLimit(1...10)
                        .focused($focused)
                        .onSubmit(send)
                        .disabled(session.phase != .ready)
                        .onKeyPress(.upArrow) { moveSlashSelection(-1) }
                        .onKeyPress(.downArrow) { moveSlashSelection(1) }
                        .onKeyPress(.tab) { acceptSlashSelection() }
                        .onKeyPress(.return) { acceptSlashSelection() }
                        .onKeyPress(.escape) {
                            guard session.isTurnActive else { return .ignored }
                            session.cancelTurn()
                            return .handled
                        }
                        .modifier(AcpImagePasteModifier(session: session))

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
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(AcpPalette.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 4)
        .onAppear { focused = true }
        .onChange(of: model.composerFocusToken) { _, _ in focused = true }
        .onChange(of: session.composerDraft) { _, _ in
            slashSelection = min(slashSelection, max(0, slashMatches.count - 1))
        }
    }

    private var hasStrip: Bool {
        (session.modes?.availableModes.count ?? 0) >= 2
            || (session.models?.availableModels.count ?? 0) >= 2
            || session.usage != nil
    }

    // MARK: Slash commands

    /// Commands matching the draft while it is still a bare "/prefix" (no
    /// space yet — once arguments start the panel goes away).
    private var slashMatches: [AvailableCommand] {
        let text = session.composerDraft
        guard session.phase == .ready, text.hasPrefix("/"), !text.contains(" "),
            !text.contains("\n"), !session.availableCommands.isEmpty
        else { return [] }
        let prefix = text.dropFirst().lowercased()
        let all = session.availableCommands
        guard !prefix.isEmpty else { return all }
        let matched = all.filter { $0.name.lowercased().hasPrefix(prefix) }
        // Fully-typed unique command: completion has nothing left to add.
        if matched.count == 1, matched[0].name.lowercased() == prefix { return [] }
        return matched
    }

    private func moveSlashSelection(_ delta: Int) -> KeyPress.Result {
        let matches = slashMatches
        guard !matches.isEmpty else { return .ignored }
        slashSelection = (slashSelection + delta + matches.count) % matches.count
        return .handled
    }

    private func acceptSlashSelection() -> KeyPress.Result {
        let matches = slashMatches
        guard !matches.isEmpty else { return .ignored }
        accept(matches[min(slashSelection, matches.count - 1)])
        return .handled
    }

    private func accept(_ command: AvailableCommand) {
        // Commands that take input get a trailing space for the argument;
        // bare commands are left ready to send with ⏎.
        session.composerDraft = "/\(command.name)" + (command.input != nil ? " " : "")
        slashSelection = 0
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

/// Prompts queued while a turn runs. Chips auto-send in order when the turn
/// finishes; after a cancel they stay parked — tap sends (when idle), × drops.
struct AcpQueuedMessagesRow: View {
    @ObservedObject var session: AgentSessionViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(session.queuedMessages) { message in
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.system(size: 9.5))
                        Text(message.text)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 220, alignment: .leading)
                        Button {
                            session.removeQueuedMessage(message.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AcpPalette.codeBackground, in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture {
                        session.sendQueuedMessageNow(message.id)
                    }
                    .help(session.isTurnActive ? "Queued — sends when this turn finishes" : "Tap to send now")
                }
            }
        }
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
        .background(AcpPalette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
    }
}

/// Session-negotiated context above the text field: mode switcher, model
/// switcher (menus; only when the agent offers a real choice) and the usage
/// readout on the right.
struct AcpComposerStrip: View {
    @ObservedObject var session: AgentSessionViewModel

    var body: some View {
        HStack(spacing: 6) {
            if let modes = session.modes, modes.availableModes.count >= 2 {
                chipMenu(
                    icon: "slider.horizontal.3",
                    title: modes.availableModes.first { $0.id == modes.currentModeId }?.name
                        ?? modes.currentModeId,
                    items: modes.availableModes.map { ($0.id, $0.name, $0.description) },
                    currentId: modes.currentModeId,
                    select: { session.setMode($0) })
            }
            if let models = session.models, models.availableModels.count >= 2 {
                chipMenu(
                    icon: "cpu",
                    title: models.availableModels.first { $0.modelId == models.currentModelId }?.name
                        ?? models.currentModelId,
                    items: models.availableModels.map { ($0.modelId, $0.name, $0.description) },
                    currentId: models.currentModelId,
                    select: { session.setModel($0) })
            }
            Spacer(minLength: 8)
            if let usage = session.usage {
                AcpUsageReadout(usage: usage)
            }
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
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// Token/context/cost readout: compact text, detail on hover (macOS help).
struct AcpUsageReadout: View {
    let usage: UsageSnapshot

    var body: some View {
        HStack(spacing: 5) {
            if let used = usage.usedTokens {
                Text(compact(used) + (usage.contextSize.map { " / " + compact($0) } ?? ""))
                    .font(.system(size: 10.5).monospacedDigit())
            }
            if let cost = usage.costAmount {
                Text(costText(cost))
                    .font(.system(size: 10.5).monospacedDigit())
            }
        }
        .foregroundStyle(.tertiary)
        .help(helpText)
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
        if let used = usage.usedTokens { parts.append("\(used) tokens in context") }
        if let size = usage.contextSize { parts.append("window \(size)") }
        if let cost = usage.costAmount { parts.append("cost \(costText(cost))") }
        return parts.joined(separator: " · ")
    }
}
