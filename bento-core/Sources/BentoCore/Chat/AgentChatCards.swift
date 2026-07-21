import ACPKit
import Combine
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

// MARK: - Tool group row

/// A run of consecutive tool calls and thoughts collapsed to one subdued
/// gray line — a lone item shows its title, several aggregate per kind
/// ("Thought, edited a.swift, b.swift, ran 2 commands"). Edited files list
/// their basenames as links rather than a count. Tapping (off a link)
/// expands the full cards. Tool traffic is a footnote to the prose, so the
/// line sits below body-text prominence.
struct AcpToolGroupRow: View {
    let items: [TranscriptItem]
    @Environment(\.acpOpenFile) private var openFile
    @State private var expanded = false
    /// Bumped whenever any item in the run mutates (status flips, merges,
    /// streaming text) so the summary re-renders — the row itself can't
    /// @ObservedObject a list.
    @State private var mutationPulse = 0

    /// At most this many edited-file links before spilling to "+N more",
    /// so a big refactor doesn't blow past the one-line budget.
    private static let maxEditLinks = 4

    private var toolItems: [ToolCallItem] { items.compactMap { $0 as? ToolCallItem } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryLine

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        if let tool = item as? ToolCallItem {
                            AcpToolCallCard(item: tool)
                        } else if let message = item as? MessageItem {
                            AcpGroupedThought(item: message)
                        }
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 4)
            }
        }
        .onReceive(Publishers.MergeMany(items.map { $0.objectWillChange })) { _ in
            mutationPulse += 1
        }
    }

    private var summaryLine: some View {
        HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8.5, weight: .semibold))
                .frame(width: 10)
            Text(summary)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            if failedCount > 0 {
                Text(items.count == 1 ? "failed" : "\(failedCount) failed")
                    .font(.system(size: 12))
                    .foregroundStyle(AcpPalette.failed)
            }
            if hasRunning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        // Filename runs open the preview; taps anywhere else toggle the group.
        .environment(\.openURL, OpenURLAction { url in
            if let path = Self.path(from: url) {
                openFile?(path, nil)
                return .handled
            }
            return .systemAction
        })
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
    }

    private var hasRunning: Bool {
        toolItems.contains { $0.status == .pending || $0.status == .inProgress }
            || items.contains { ($0 as? MessageItem)?.isStreaming == true }
    }

    private var failedCount: Int {
        toolItems.filter { $0.status == .failed }.count
    }

    // MARK: Summary

    private enum SummaryKind: Hashable {
        case think
        case tool(ToolKind)
    }

    /// The collapsed one-liner. A lone item keeps its own informative label;
    /// several aggregate per kind, with edits spelling out filenames.
    private var summary: AttributedString {
        if items.count == 1 {
            if let tool = items[0] as? ToolCallItem {
                if tool.kind == .edit, let files = editRuns(for: [tool]) {
                    return capitalizingFirst(AttributedString("edited ") + files)
                }
                return AttributedString(tool.title)  // verbatim — already cased
            }
            if let message = items[0] as? MessageItem {
                return AttributedString(message.isStreaming ? "Thinking…" : "Thought")
            }
            return AttributedString("")
        }

        // Aggregate per kind in first-appearance order; file-shaped kinds
        // count distinct paths so three edits to one file read "1 file".
        var order: [SummaryKind] = []
        var seen: Set<SummaryKind> = []
        var toolsByKind: [ToolKind: [ToolCallItem]] = [:]
        var thoughtCount = 0
        for item in items {
            if let tool = item as? ToolCallItem {
                let key = SummaryKind.tool(tool.kind)
                if seen.insert(key).inserted { order.append(key) }
                toolsByKind[tool.kind, default: []].append(tool)
            } else if item is MessageItem {
                if seen.insert(.think).inserted { order.append(.think) }
                thoughtCount += 1
            }
        }

        var out = AttributedString()
        for key in order {
            if !out.characters.isEmpty { out += AttributedString(", ") }
            switch key {
            case .think:
                out += AttributedString(counted(thoughtCount, "thought"))
            case .tool(.edit):
                let tools = toolsByKind[.edit] ?? []
                if let files = editRuns(for: tools) {
                    out += AttributedString("edited ") + files
                } else {
                    out += AttributedString(phrase(for: .edit, callCount: tools.count, fileCount: 0))
                }
            case .tool(let kind):
                let tools = toolsByKind[kind] ?? []
                let fileCount = Set(tools.compactMap { $0.locations.first?.path }).count
                out += AttributedString(phrase(for: kind, callCount: tools.count, fileCount: fileCount))
            }
        }
        return capitalizingFirst(out)
    }

    /// Distinct edited-file basenames as links (capped, "+N more" beyond).
    /// nil when no edit carries a path — caller falls back to a count.
    private func editRuns(for tools: [ToolCallItem]) -> AttributedString? {
        var seen: Set<String> = []
        var paths: [String] = []
        for tool in tools {
            guard let path = tool.locations.first?.path ?? tool.diffs.first?.path else { continue }
            if seen.insert(path).inserted { paths.append(path) }
        }
        guard !paths.isEmpty else { return nil }

        var out = AttributedString()
        let shown = paths.prefix(Self.maxEditLinks)
        for (index, path) in shown.enumerated() {
            if index > 0 { out += AttributedString(", ") }
            out += fileRun(path)
        }
        let extra = paths.count - shown.count
        if extra > 0 { out += AttributedString(", +\(extra) more") }
        return out
    }

    /// One filename run: a tappable link when the surface wired an open
    /// action, plain accented text otherwise.
    private func fileRun(_ path: String) -> AttributedString {
        var run = AttributedString((path as NSString).lastPathComponent)
        if openFile != nil, let url = Self.fileURL(path) {
            run.link = url
            run.foregroundColor = .accentColor
            run.underlineStyle = .single
        }
        return run
    }

    private func phrase(for kind: ToolKind, callCount: Int, fileCount: Int) -> String {
        let files = counted(fileCount > 0 ? fileCount : callCount, "file")
        switch kind {
        case .read: return "read \(files)"
        case .edit: return "edited \(files)"
        case .delete: return "deleted \(files)"
        case .move: return "moved \(files)"
        case .search: return counted(callCount, "search", "searches")
        case .execute: return "ran \(counted(callCount, "command"))"
        case .think: return counted(callCount, "thought")
        case .fetch: return "fetched \(counted(callCount, "URL"))"
        case .switchMode: return counted(callCount, "mode switch", "mode switches")
        case .other: return counted(callCount, "tool call")
        }
    }

    private func counted(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    private func capitalizingFirst(_ s: AttributedString) -> AttributedString {
        guard let first = s.characters.first, first.isLowercase else { return s }
        var copy = s
        let second = copy.characters.index(after: copy.startIndex)
        copy.replaceSubrange(copy.startIndex..<second, with: AttributedString(String(first).uppercased()))
        return copy
    }

    /// Filenames ride a private URL scheme so a Text link run carries the
    /// full path; the openURL handler above unpacks it back to a preview.
    private static func fileURL(_ path: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "bentoacpfile"
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "p", value: path)]
        return comps.url
    }

    private static func path(from url: URL) -> String? {
        guard url.scheme == "bentoacpfile" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "p" }?.value
    }
}

/// A thought inside an expanded tool group: reasoning text shown directly
/// (the group's own chevron already controls visibility, so no second toggle).
struct AcpGroupedThought: View {
    @ObservedObject var item: MessageItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(item.text.isEmpty ? "…" : item.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .acpSelectableText()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

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
        // Cards live inside a collapsed group; one that failed before the
        // group was expanded gets its first render already failed.
        .onAppear {
            if item.status == .failed && !autoExpandedOnFailure {
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

            let images = item.imageOutputs
            if !images.isEmpty {
                AcpMessageImages(images: images)
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

            if item.diffs.isEmpty && output.isEmpty && images.isEmpty && item.terminalIds.isEmpty
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
                .acpSelectableText()
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

// MARK: - Stopped card

/// Shown when a pane's agent is gone — the daemon dropped it (crash, restart,
/// GC) or it never started — while the pane is still on screen. One tap
/// re-establishes the SAME session in place and resumes the recorded
/// conversation. Mirrors `AcpAuthCard`: an inline actionable state, not a
/// modal.
struct AcpStoppedCard: View {
    @ObservedObject var session: AgentSessionViewModel

    private var neverStarted: Bool {
        if case .failed = session.phase { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.slash.fill")
                .foregroundStyle(AcpPalette.failed)
            VStack(alignment: .leading, spacing: 2) {
                Text(neverStarted
                     ? "\(session.preset.name) didn't start"
                     : "\(session.preset.name) stopped")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Restart to bring it back and resume this conversation.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                session.requestRestart()
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(AcpPalette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(AcpPalette.failed.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
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
    @State private var slashSelection = 0
    /// The platform text editor's measured content height (0 until first
    /// layout); clamped into [oneLine, maxEditorHeight] for the field frame.
    @State private var editorHeight: CGFloat = 0

    /// One line's worth of composer height — the field's floor before content
    /// (and the frame while `editorHeight` is still 0).
    private static let oneLineHeight: CGFloat = 24
    /// The field grows to here, then scrolls internally.
    private static let maxEditorHeight: CGFloat = 200

    private var draft: Binding<String> {
        Binding(get: { session.composerDraft }, set: { session.composerDraft = $0 })
    }

    var body: some View {
        VStack(spacing: 6) {
            if !slashMatches.isEmpty {
                AcpSlashCommandPanel(
                    matches: slashMatches, selection: slashSelection,
                    accept: { accept($0) })
                    .padding(.horizontal, 12)
            }

            VStack(spacing: 6) {
                if !session.queuedMessages.isEmpty {
                    AcpQueuedMessagesRow(session: session)
                }
                if !session.composerAttachments.isEmpty {
                    AcpAttachmentsRow(session: session)
                }
                // Config strip is always shown. It used to collapse when the
                // reader scrolled up — that coupled composer height to scroll
                // position and yanked the viewport (strip-toggle jump). Manual
                // folding can come back later, decoupled from scrolling.
                if hasStrip {
                    AcpComposerStrip(session: session)
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
            // transcript, set off only by a hairline and a restrained upward
            // shadow. Edge-to-edge so the divider spans the full pane width;
            // the field's own affordance is the send glyph, not a border.
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(composerCanvas)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(AcpPalette.panelBorder)
                    .frame(height: 1)
            }
            .compositingGroup()
            // Black reads as lift on light themes and fades to nothing on dark
            // canvases, where the hairline carries the separation instead.
            .shadow(color: .black.opacity(0.10), radius: 5, y: -1.5)
        }
        .animation(.easeInOut(duration: 0.18), value: hasStrip)
        .onChange(of: session.composerDraft) { _, _ in
            slashSelection = min(slashSelection, max(0, slashMatches.count - 1))
        }
    }

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
        recognizedCommandToken.map { ($0 as NSString).length } ?? 0
        #else
        0
        #endif
    }

    /// Plain Return in the editor: accept an open slash completion, else send.
    /// (Shift+Return inserts a newline — handled in the editor itself.)
    private func handleReturnKey() {
        if !slashMatches.isEmpty {
            accept(slashMatches[min(slashSelection, slashMatches.count - 1)])
        } else {
            send()
        }
    }

    /// ↑/↓ move the slash selection when the panel is open; otherwise let the
    /// caret move (return false = not consumed).
    private func handleArrowKey(_ delta: Int) -> Bool {
        guard !slashMatches.isEmpty else { return false }
        slashSelection = (slashSelection + delta + slashMatches.count) % slashMatches.count
        return true
    }

    private func handleTabKey() -> Bool {
        guard !slashMatches.isEmpty else { return false }
        accept(slashMatches[min(slashSelection, slashMatches.count - 1)])
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

    // MARK: Slash commands

    /// The draft's leading "/command" token when it names an available
    /// command exactly — the visual confirmation that the command is real,
    /// shown whether or not arguments follow.
    private var recognizedCommandToken: String? {
        let text = session.composerDraft
        guard text.hasPrefix("/") else { return nil }
        let name = text.dropFirst().prefix { !$0.isWhitespace }
        guard !name.isEmpty,
            session.availableCommands.contains(where: { $0.name.lowercased() == name.lowercased() })
        else { return nil }
        return "/" + name
    }

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

    private var options: [ConfigOption] {
        session.configOptions.filter(\.isRenderableSelect)
    }

    var body: some View {
        HStack(spacing: 6) {
            if options.isEmpty {
                legacyChips
            } else {
                overflowingChips
            }
            Spacer(minLength: 8)
            if let usage = session.usage {
                AcpUsageReadout(usage: usage)
            }
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

#if os(macOS)
// MARK: - Composer text editor (macOS)

/// A plain-text composer input backed by NSTextView. Grows with content up to
/// `maxHeight`, then scrolls internally. Unlike SwiftUI's
/// `TextField(axis: .vertical)` — which re-lays out the entire string on every
/// SwiftUI render and hangs on large pastes — NSTextView owns its text storage
/// and lays out once per edit, so big drafts stay smooth. Return submits;
/// Shift+Return inserts a newline; ↑/↓/⇥/⎋ are forwarded so the slash-command
/// panel and turn-cancel keep working. Image ⌘V is caught upstream by the pane
/// surface's event monitor, so it never reaches here as pasted text.
struct AcpComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    var isEditable: Bool
    var maxHeight: CGFloat
    /// Bumped by the host to pull first-responder into the field.
    var focusToken: Int
    /// UTF-16 length of the leading "/command" token to accent-highlight (0 =
    /// none).
    var highlightLength: Int
    var onReturn: () -> Void
    var onArrow: (Int) -> Bool
    var onTab: () -> Bool
    var onEscape: () -> Bool

    private static let font = NSFont.systemFont(ofSize: 13.5)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text

        scroll.documentView = textView
        context.coordinator.textView = textView
        // Initial layout pass so the field opens at the right height.
        DispatchQueue.main.async { context.coordinator.recomputeHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text { textView.string = text }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        context.coordinator.applyHighlight()
        context.coordinator.recomputeHeight()
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AcpComposerTextEditor
        weak var textView: NSTextView?
        var lastFocusToken: Int

        init(_ parent: AcpComposerTextEditor) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            applyHighlight()
            recomputeHeight()
        }

        /// Paint (or clear) the accent background behind the leading command
        /// token via a temporary attribute — doesn't touch text storage or
        /// undo, and follows the glyphs through wrapping and scrolling.
        func applyHighlight() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            let length = min(parent.highlightLength, full.length)
            guard length > 0 else { return }
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor.controlAccentColor.withAlphaComponent(0.18),
                forCharacterRange: NSRange(location: 0, length: length))
        }

        /// Report the content height (clamped to maxHeight) back to SwiftUI so
        /// the field frame grows with the draft, then caps and scrolls.
        func recomputeHeight() {
            guard let textView, let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let content = layoutManager.usedRect(for: container).height
                + textView.textContainerInset.height * 2
            let clamped = min(max(content, 0), parent.maxHeight)
            guard abs(clamped - parent.measuredHeight) > 0.5 else { return }
            DispatchQueue.main.async { self.parent.measuredHeight = clamped }
        }

        /// Intercept the keys the composer owns; everything else is stock text
        /// editing. Returning true consumes the command.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift+Return → real newline; plain Return → submit / accept.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    return false
                }
                parent.onReturn()
                return true
            case #selector(NSResponder.moveUp(_:)):
                return parent.onArrow(-1)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onArrow(1)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onTab()
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape()
            default:
                return false
            }
        }
    }
}
#else
// MARK: - Composer text editor (iOS)

/// The iOS counterpart to the macOS composer editor: a UITextView-backed input
/// that grows to `maxHeight` then scrolls, and — unlike SwiftUI's
/// `TextField(axis:.vertical)` — doesn't re-lay out the whole draft on every
/// render, so big pastes stay smooth. Return submits (or accepts an open slash
/// completion); the ↑/↓/⇥/⎋ hardware-keyboard affordances are macOS-only for
/// now (the slash panel is tappable and the Stop button cancels a turn).
struct AcpComposerTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    var isEditable: Bool
    var maxHeight: CGFloat
    var focusToken: Int
    var highlightLength: Int
    var onReturn: () -> Void
    var onArrow: (Int) -> Bool
    var onTab: () -> Bool
    var onEscape: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 13.5)
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        textView.textContainer.lineFragmentPadding = 5
        textView.isScrollEnabled = true
        textView.keyboardDismissMode = .interactive
        textView.text = text
        context.coordinator.textView = textView
        DispatchQueue.main.async {
            context.coordinator.recomputeHeight()
            // Match the old field's auto-focus on appear.
            textView.becomeFirstResponder()
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        var recompute = false
        if textView.text != text { textView.text = text; recompute = true }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        // A width change (rotation, layout) re-wraps the text → new height.
        if abs(textView.bounds.width - context.coordinator.lastWidth) > 0.5 {
            context.coordinator.lastWidth = textView.bounds.width
            recompute = true
        }
        if recompute { context.coordinator.recomputeHeight() }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { textView.becomeFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AcpComposerTextEditor
        weak var textView: UITextView?
        var lastFocusToken: Int
        var lastWidth: CGFloat = 0

        init(_ parent: AcpComposerTextEditor) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            recomputeHeight()
        }

        /// Return submits instead of inserting a newline (parity with the old
        /// field's onSubmit). Everything else types normally.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            if text == "\n" {
                parent.onReturn()
                return false
            }
            return true
        }

        /// Grow the field with the draft up to maxHeight, then let it scroll.
        /// Measured only on real edits / width changes — never per render — so
        /// a huge paste doesn't re-measure on every SwiftUI pass.
        func recomputeHeight() {
            guard let textView else { return }
            let width = textView.bounds.width > 0
                ? textView.bounds.width : UIScreen.main.bounds.width
            let fit = textView.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude))
            // The SwiftUI frame caps the height; scrolling stays on so content
            // past the cap is reachable (below the cap it simply fits exactly).
            let clamped = min(max(fit.height, 0), parent.maxHeight)
            guard abs(clamped - parent.measuredHeight) > 0.5 else { return }
            DispatchQueue.main.async { self.parent.measuredHeight = clamped }
        }
    }
}
#endif
