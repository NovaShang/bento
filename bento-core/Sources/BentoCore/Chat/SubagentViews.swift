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

// MARK: - Floating HUD

/// A floating overview of the subagents running RIGHT NOW — draggable,
/// collapsible, and absent entirely (EmptyView) whenever nothing runs, so it
/// costs zero when idle. Each row expands to that subagent's live tool stream;
/// the transcript chip below stays as the settled record. Mounted as an overlay
/// on the transcript.
struct AcpSubagentHUD: View {
    @ObservedObject var session: AgentSessionViewModel
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    @State private var collapsed = false

    private var live: [SubagentGroupItem] {
        session.items.compactMap { $0 as? SubagentGroupItem }.filter(\.isRunning)
    }

    var body: some View {
        let groups = live
        if !groups.isEmpty {
            panel(groups)
                .frame(width: 300, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                .gesture(
                    DragGesture()
                        .updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            offset.width += value.translation.width
                            offset.height += value.translation.height
                        }
                )
                .padding(.top, 10)
                .padding(.trailing, 12)
        }
    }

    private func panel(_ groups: [SubagentGroupItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(AcpPalette.working)
                Text(collapsed
                    ? "\(groups.count) subagent\(groups.count == 1 ? "" : "s") running"
                    : "Subagents")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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

            if !collapsed {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        AcpSubagentHUDRow(item: group)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// One live subagent in the HUD: status, title, and its current step; taps to
/// reveal the full tool stream.
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
                        Text(currentStep)
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
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(item.children) { child in
                        AcpToolCallCard(item: child)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var currentStep: String {
        if let last = item.children.last {
            return "\(last.title) · \(stepLabel(item.stepCount))"
        }
        return "starting…"
    }
}
