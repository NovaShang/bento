import BentoShelliOS
import BentoUI
import SwiftUI

/// Bento Term's first run.
///
/// The shared welcome teaches the pairing story — install the Bento app on a
/// Mac, come back, scan its QR — which belongs to product A. Term has no daemon
/// to pair with and installs nothing anywhere: it is a client, and the only
/// thing it needs is a machine the user can already reach. Showing them the
/// other product's setup would have them looking for software that isn't part
/// of this one.
///
/// So this screen states the three real requirements and then does the one
/// thing there is to do.
struct TermWelcomeView: View {
    /// Opens the host-add sheet the list already owns; see
    /// `ShellPaneRegistry.welcomeFlow`.
    let addHost: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                VStack(spacing: 10) {
                    BentoMarkHero(size: 72)
                        .shadow(color: Color.black.opacity(0.4), radius: 18, y: 8)
                    Text("Bento Term")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.bentoInk)
                    Text("Your tmux sessions, on every screen.\nSpeak to them.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.bentoInkDim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 32)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Connect to a machine you already use.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.bentoInkDim)

                    requirement("terminal", "It runs sshd",
                                "Your Mac, a Linux box, WSL — anything you can ssh to.")
                    requirement("rectangle.split.2x2", "It has tmux",
                                "Your sessions keep running whether or not this app is open.")
                    requirement("checkmark.seal", "Nothing to install",
                                "Bento Term is a client. It leaves no process behind.")
                }
                .padding(.horizontal, 24)

                Button(action: addHost) {
                    Text("Add a Host")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.bentoEmerald))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
        .background(Color.bentoShell)
    }

    private func requirement(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.bentoEmerald)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.bentoInk)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bentoInkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
