import ACPKit
import MarkdownUI
import SwiftUI

// Subagent UI: a Task/Agent call and the tool calls it made, kept OFF the main
// transcript line. The transcript shows one compact chip (title, rolled-up
// status, step count, and the subagent's final answer inline once it settles);
// a floating HUD lists whichever subagents are running right now, each
// expandable to its live tool stream.
//
// House rules from the rest of Chat/: PaneState accents, and NO continuous
// animation — a spinner per running step is exactly the per-frame compositor
// cost that pinned turn-time CPU (see AcpWorkingIndicator). Status is a static
// dot; the HUD renders nothing at all when no subagent is live.

// MARK: - Shared status glyph

/// The one status-dot family shared by the chip and the HUD, matching
/// AcpToolCallCard's badge: dotted = running, check = done, x = failed.
private func subagentStatusGlyph(_ status: ToolCallStatus) -> (name: String, color: Color) {
    switch status {
    case .pending, .inProgress: return ("circle.dotted", AcpPalette.working)
    case .completed: return ("checkmark.circle.fill", AcpPalette.done)
    case .failed: return ("xmark.circle.fill", AcpPalette.failed)
    }
}

private struct AcpSubagentStatusDot: View {
    let status: ToolCallStatus
    var body: some View {
        let glyph = subagentStatusGlyph(status)
        Image(systemName: glyph.name)
            .font(.system(size: 12))
            .foregroundStyle(glyph.color)
    }
}

private func stepLabel(_ count: Int) -> String {
    "\(count) step\(count == 1 ? "" : "s")"
}

// MARK: - Inline chip (transcript row)

/// A whole subagent as one transcript row: a header (glyph, status, title,
/// step count), the subagent's final answer inline once it finishes, and — on
/// tap — its full tool stream. Its inner calls never interleave with the main
/// agent's prose; this chip is all that stands in the linear transcript.
struct AcpSubagentChipRow: View {
    @ObservedObject var item: SubagentGroupItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: { header }
                .buttonStyle(.plain)

            if expanded && !item.children.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(item.children) { child in
                        AcpToolCallCard(item: child)
                    }
                }
                .padding(.top, 2)
            }

            if !item.finalResult.isEmpty {
                Markdown(item.finalResult)
                    .markdownTheme(.acpChat)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
            }
        }
        .background(AcpPalette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            AcpSubagentStatusDot(status: item.status)
            Text(item.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if item.stepCount > 0 {
                Text("· \(stepLabel(item.stepCount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !item.children.isEmpty {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

// MARK: - Floating panel (task-list of subagents)

/// A floating, draggable, collapsible task-list of THIS session's subagents —
/// running AND finished — pinned top-right over the transcript (mounted on the
/// same proven floating layer as the plan card, in AcpSessionContentView).
/// Absent entirely (EmptyView) only when there are no subagents at all, so a
/// plain conversation pays nothing. Each row expands to that subagent's tool
/// stream and final answer. Drag by the title bar; the rows scroll internally.
struct AcpSubagentHUD: View {
    @ObservedObject var session: AgentSessionViewModel
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    @State private var collapsed = false

    /// Every subagent this session has spawned, in the order they appeared —
    /// like a task list, finished ones stay (dimmed by their done status dot).
    private var groups: [SubagentGroupItem] {
        session.items.compactMap { $0 as? SubagentGroupItem }
    }

    var body: some View {
        let all = groups
        if !all.isEmpty {
            panel(all)
                .frame(width: 300, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                .padding(.top, 10)
                .padding(.trailing, 10)
        }
    }

    private func panel(_ all: [SubagentGroupItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar — also the drag handle (keeps the drag off the row
            // buttons and the internal scroll).
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(AcpPalette.working)
                Text("Subagents")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(all.count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                Spacer(minLength: 12)
                Button { collapsed.toggle() } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        offset.width += value.translation.width
                        offset.height += value.translation.height
                    }
            )

            if !collapsed {
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(all) { group in
                            AcpSubagentHUDRow(item: group)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 320)
            }
        }
    }
}

/// One subagent in the panel: status dot, title, and either its current step
/// (while running) or a done/failed summary; taps to reveal the full tool
/// stream and the subagent's final answer.
private struct AcpSubagentHUDRow: View {
    @ObservedObject var item: SubagentGroupItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    AcpSubagentStatusDot(status: item.status)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(item.children) { child in
                        AcpToolCallCard(item: child)
                    }
                    if !item.finalResult.isEmpty {
                        Markdown(item.finalResult)
                            .markdownTheme(.acpChat)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var subtitle: String {
        switch item.status {
        case .completed: return "done · \(stepLabel(item.stepCount))"
        case .failed: return "failed · \(stepLabel(item.stepCount))"
        case .pending, .inProgress:
            if let last = item.children.last {
                return "\(last.title) · \(stepLabel(item.stepCount))"
            }
            return "starting…"
        }
    }
}
