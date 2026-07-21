import ACPKit
import Combine
import SwiftUI

// Transcript cards for the ACP chat: runs of tool calls collapsed to one
// summary line, the expandable per-call card, and the shared mono output
// block. Same rules as the rest of Chat/: system colors, PaneState accents,
// mono only for code/tool output.

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
        Group {
            // A run of one tool call isn't a fold worth hiding behind a summary
            // line — show its card directly (it carries its own collapsed header
            // + tap-to-expand + auto-expand-on-failure). Reasoning still folds,
            // and the moment a second call joins the run this reverts to the
            // grouped summary.
            if let solo = soloToolCall {
                AcpToolCallCard(item: solo)
            } else {
                groupBody
            }
        }
        .onReceive(Publishers.MergeMany(items.map { $0.objectWillChange })) { _ in
            mutationPulse += 1
        }
    }

    /// The single tool call in a run of one, or nil for a reasoning-only or
    /// multi-item run (which keep the collapsed summary line).
    private var soloToolCall: ToolCallItem? {
        guard items.count == 1 else { return nil }
        return items[0] as? ToolCallItem
    }

    private var groupBody: some View {
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

