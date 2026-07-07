import SwiftUI
import BentoTerminalCore

/// "How Bento works" — the concept map (design doc §2), permanently
/// re-readable. Every coach mark the user may have dismissed lives here in
/// long form: host vs. remote, agents, persistent workspaces, pairing, state
/// colors, the two views, and the voice gestures. Reached from the welcome
/// screen and Settings → Help.
struct HowBentoWorksView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HowBentoWorksContent()
                .navigationTitle("How Bento works")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Pushed variant for Settings → Help (already inside a NavigationStack).
struct HowBentoWorksSettingsPage: View {
    var body: some View {
        HowBentoWorksContent()
            .navigationTitle("How Bento works")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HowBentoWorksContent: View {
    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ArchitectureDiagramView(accent: .bentoEmerald)
                        .padding(.top, 8)

                    concept(
                        symbol: "desktopcomputer",
                        title: "Your host",
                        body: "The computer where agents actually work — your Mac or a server. Your phone is just the remote control: close it, and the work continues."
                    )
                    concept(
                        symbol: "sparkles",
                        title: "Agents",
                        body: "AI workers (like Claude Code) installed on the host. Each signs into its own account. Give one a folder and an instruction and it works on its own."
                    )
                    concept(
                        symbol: "clock.arrow.circlepath",
                        title: "Workspaces persist",
                        body: "A workspace is a living project site. Disconnect, lock your phone, switch devices — everything is exactly where you left it until you close the workspace yourself."
                    )
                    concept(
                        symbol: "qrcode",
                        title: "Pairing",
                        body: "A one-time introduction between phone and host. After pairing they reach each other from any network, end-to-end encrypted — the relay only forwards bytes it cannot read."
                    )

                    StateLegendCard()
                        .frame(maxWidth: .infinity)

                    concept(
                        symbol: "rectangle.split.2x2",
                        title: "Two views, one truth",
                        body: "Parallel shows every agent at once, like a bento box. Focus shows one at a time — better on a phone. Switch freely with the toggle up top; nothing is ever lost."
                    )
                    concept(
                        symbol: "mic",
                        title: "Voice gestures",
                        body: "Hold anywhere and speak; release to send. While holding: slide up to send instantly, down to cancel, right to review the text before sending, left to turn plain words into a shell command. Double-tap for the keyboard."
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
        .background(Color.bentoShell)
    }

    private func concept(symbol: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.bentoEmerald)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.bentoInk)
                Text(body)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.bentoInkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.bentoSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.bentoBorder, lineWidth: 1)
        )
    }
}
