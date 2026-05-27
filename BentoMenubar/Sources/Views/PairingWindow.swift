import SwiftUI
import AppKit

/// PairingWindow shows the 6-digit code the user types on iOS. The visual
/// language mirrors AirDrop / "Connect to nearby device" — large numerals
/// over a hairline divider, no decorative card.
struct PairingWindow: View {
    @EnvironmentObject var bento: BentoCLI
    @State private var code: String?
    @State private var error: String?
    @State private var remainingSec: Int = 60
    @Environment(\.dismiss) private var dismiss

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Copy code") { copyCode() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(code == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 380, height: 260)
        .task { await fetch() }
        .onReceive(timer) { _ in
            if remainingSec > 0 { remainingSec -= 1 }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pair iPhone")
                    .font(.title2).bold()
                Text("Open Bento on your iPhone and enter this code.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let code {
                Text(code)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .tracking(6)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                Text("Expires in \(remainingSec)s")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let error {
                GroupBox {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(error).font(.callout)
                        Spacer()
                        Button("Retry") { Task { await fetch() } }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func fetch() async {
        do {
            code = nil
            error = nil
            remainingSec = 60
            code = try await bento.pair()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func copyCode() {
        guard let code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}
