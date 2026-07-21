import SwiftUI

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

