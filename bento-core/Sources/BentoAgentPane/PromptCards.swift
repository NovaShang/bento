import BentoFoundation
import BentoUI
import BentoVoiceKit
import BentoFilePreviewKit
import BentoWorkbench
import ACPKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The chat's status cards: the agent's plan, the permission / question
// prompt, the sign-in card, and the stopped-agent card. All inline,
// non-modal, docked above the composer.

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
            // Safe to animate again: the plan card FLOATS over the transcript
            // now (AcpSessionContentView overlay), so its height change is no
            // longer coupled to the transcript viewport / keep-bottom ledger.
            // (In-transcript disclosures — tool group, thought, notice — still
            // snap; those DO resize the document.)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
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
                    // Floating card — safe to animate (see AcpPlanCard).
                    withAnimation(.easeInOut(duration: 0.18)) { showRawInput.toggle() }
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

