import BentoFoundation
import BentoShelliOS
import BentoTmuxPane
import BentoUI
import SwiftUI

/// What the tmux control client is doing, when it is doing something the user
/// would otherwise experience as the app freezing.
///
/// Restored from the pre-merge product, where the same banner rode
/// `isReconnecting`. Its absence is why a dead link and an idle one looked
/// identical: panes simply stopped responding, with the explanation only in the
/// log. A reconnect can take as long as the network takes, so the rule is that
/// the UI never sits silent through one.
struct TmuxConnectionBanner: View {
    let host: Host
    let session: String

    @ObservedObject private var shell = TmuxShell.shared

    var body: some View {
        if let phase = shell.phase(for: host, session: session), phase != .ready {
            HStack(spacing: 8) {
                icon(for: phase)
                Text(label(for: phase))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.bentoInk)
                if phase == .ended {
                    Button("Retry") { shell.retry(host: host, session: session) }
                        .font(.system(size: 13, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.bentoEmerald)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.bentoSurface))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.bentoBorder, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func icon(for phase: TmuxSessionLink.Phase) -> some View {
        switch phase {
        case .connecting, .reconnecting:
            ProgressView().controlSize(.small)
        case .ended:
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        case .ready:
            EmptyView()
        }
    }

    private func label(for phase: TmuxSessionLink.Phase) -> String {
        switch phase {
        case .connecting:   return "Connecting to \(host.displayName)…"
        // Deliberately not "Lost connection": the loop below it retries
        // forever, so the true statement is that it is working on it.
        case .reconnecting: return "Reconnecting to \(host.displayName)…"
        case .ended:        return "Session ended."
        case .ready:        return ""
        }
    }
}
