import ACPKit
import MarkdownUI
import SwiftUI

// Subagent + task-list UI. A subagent (Task/Agent call) and the tool calls it
// made are kept OFF the main transcript line: the transcript shows one compact
// chip, and a floating panel at the TOP-RIGHT lists the session's subagents.
// A matching floating panel at the TOP-LEFT shows the agent's task list (the
// ACP plan). The two panels share one "which is expanded" state so only one is
// ever open — opening one collapses the other.
//
// House rules from the rest of Chat/: PaneState accents, and NO continuous
// animation — a spinner per running step is exactly the per-frame compositor
// cost that pinned turn-time CPU (see AcpWorkingIndicator). Status is a static
// dot; each panel renders nothing at all when it has no items.

// MARK: - Shared status glyph

/// The one status-dot family shared by the chip and the panels, matching
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

// MARK: - Shared floating panel

/// Which corner panel is expanded. Held once by AcpSessionContentView and bound
/// into both panels, so opening one collapses the other (only one ever open).
enum AcpFloatingPanelKind: Equatable {
    case tasks
    case subagents
}

/// The shared chrome for both corner panels: a frosted card whose header is the
/// whole tap target — collapsed it fits its content (icon, title, a stat badge)
/// and a tap expands it; expanded it's a fixed-width list of rows that scrolls
/// internally past a few. Expansion is a shared binding, so opening this panel
/// collapses its sibling.
private struct AcpFloatingListPanel<Rows: View>: View {
    let kind: AcpFloatingPanelKind
    let icon: String
    let title: String
    /// The collapsed stat (e.g. "3" or "1/4") — the only detail shown folded.
    let badge: String
    let tint: Color
    @Binding var expandedPanel: AcpFloatingPanelKind?
    @ViewBuilder var rows: () -> Rows

    private var isExpanded: Bool { expandedPanel == kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // One transaction flips THIS panel and (via the shared binding)
                // collapses its sibling, so both animate together.
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedPanel = isExpanded ? nil : kind
                }
            } label: {
                header
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { rows() }
                        .padding(.vertical, 2)
                }
                .frame(maxHeight: 320)
                .transition(.opacity)
            }
        }
        // Content-width when collapsed (folded panels hug their stats); a fixed
        // reading width once opened.
        .frame(width: isExpanded ? 300 : nil, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.top, 10)
        .padding(.horizontal, 10)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(badge)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
            if isExpanded { Spacer(minLength: 12) }
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Subagents panel (top-right)

/// A task-list of THIS session's subagents (running + finished), pinned
/// top-right. Absent entirely when there are no subagents, so a plain
/// conversation pays nothing.
struct AcpSubagentHUD: View {
    @ObservedObject var session: AgentSessionViewModel
    @Binding var expandedPanel: AcpFloatingPanelKind?
    @State private var showCompleted = false

    private var groups: [SubagentGroupItem] {
        session.items.compactMap { $0 as? SubagentGroupItem }
    }

    var body: some View {
        let all = groups
        let running = all.filter(\.isRunning)
        let doneCount = all.count - running.count
        if !all.isEmpty {
            // Finished subagents are hidden by default — the panel is for
            // watching what's live. A footer reveals them; the badge shows the
            // live count while any run, else the total.
            let visible = showCompleted ? all : running
            AcpFloatingListPanel(
                kind: .subagents,
                icon: "sparkles",
                title: "Subagents",
                badge: running.isEmpty ? "\(all.count)" : "\(running.count)",
                tint: AcpPalette.working,
                expandedPanel: $expandedPanel
            ) {
                ForEach(visible) { group in
                    AcpSubagentHUDRow(item: group)
                }
                if doneCount > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showCompleted.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showCompleted ? "eye.slash" : "eye")
                                .font(.system(size: 10))
                            Text(showCompleted ? "Hide \(doneCount) done" : "Show \(doneCount) done")
                                .font(.caption2)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
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

// MARK: - Task list panel (top-left)

/// The agent's task list (ACP plan) as a floating panel matching the subagents
/// panel, pinned top-left. Collapsed it shows only the done/total stat; opened
/// it lists every task. Absent when the plan is empty.
struct AcpTaskListPanel: View {
    let entries: [PlanEntry]
    @Binding var expandedPanel: AcpFloatingPanelKind?

    private var completed: Int { entries.filter { $0.status == .completed }.count }

    var body: some View {
        if !entries.isEmpty {
            AcpFloatingListPanel(
                kind: .tasks,
                icon: "list.bullet.rectangle",
                title: "Tasks",
                badge: "\(completed)/\(entries.count)",
                tint: .accentColor,
                expandedPanel: $expandedPanel
            ) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    AcpTaskRow(entry: entry)
                }
            }
        }
    }
}

private struct AcpTaskRow: View {
    let entry: PlanEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: glyph.name)
                .font(.system(size: 11))
                .foregroundStyle(glyph.color)
            Text(entry.content)
                .font(.caption)
                .foregroundStyle(entry.status == .completed ? Color.secondary : Color.primary)
                .strikethrough(entry.status == .completed, color: .secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var glyph: (name: String, color: Color) {
        switch entry.status {
        case .pending: return ("circle", .secondary)
        case .inProgress: return ("circle.dotted", AcpPalette.working)
        case .completed: return ("checkmark.circle.fill", AcpPalette.done)
        }
    }
}
