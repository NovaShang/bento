import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// PairingWindow exposes the two values the iPhone needs to type to pair:
/// the daemon ID (long, copy-only) and the 6-digit code (short, copy or
/// type). The layout is two stacked "card" rows so the user has a clear
/// 1-2-3 mental model: copy the ID, copy or type the code, encrypt.
struct PairingWindow: View {
    @EnvironmentObject var bento: BentoCLI
    @State private var code: String?
    @State private var error: String?
    @State private var remainingSec: Int = 60
    @State private var daemonID: String = ""
    @State private var copiedID: Bool = false
    @State private var copiedCode: Bool = false
    @Environment(\.dismiss) private var dismiss

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Spacer(minLength: 0)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 440, height: 600)
        .task { await fetch() }
        .onReceive(timer) { _ in
            guard code != nil else { return }
            if remainingSec > 1 {
                remainingSec -= 1
            } else {
                Task { await fetch() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan the code with your iPhone Camera, or open Bento → **+** → **Pair Mac via relay…** and enter the values below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let err = error {
                errorCard(err)
            } else if code == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                qrCard
                daemonIDCard
                codeCard
            }

            footnote
        }
    }

    private var pairURL: URL? {
        guard let code, !daemonID.isEmpty else { return nil }
        var comps = URLComponents()
        comps.scheme = "bento"
        comps.host = "pair"
        comps.queryItems = [
            URLQueryItem(name: "d", value: daemonID),
            URLQueryItem(name: "c", value: code),
        ]
        return comps.url
    }

    private var qrCard: some View {
        Card(title: "Scan with iPhone Camera") {
            HStack {
                Spacer()
                if let url = pairURL, let img = qrImage(for: url.absoluteString, size: 180) {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .padding(8)
                        .background(Color.white)
                        .cornerRadius(8)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 180, height: 180)
                        .overlay(ProgressView())
                }
                Spacer()
            }
        }
    }

    private var daemonIDCard: some View {
        Card(title: "Daemon ID") {
            HStack(spacing: 8) {
                Text(daemonID.isEmpty ? "—" : daemonID)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(copied: copiedID) {
                    copy(daemonID) { copiedID = $0 }
                }
                .disabled(daemonID.isEmpty)
            }
        }
    }

    private var codeCard: some View {
        Card(title: "Pairing code", trailing: AnyView(
            Text("Expires in \(remainingSec)s")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        )) {
            HStack(spacing: 8) {
                Text(code ?? "")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .tracking(8)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .center)
                CopyButton(copied: copiedCode) {
                    if let c = code { copy(c) { copiedCode = $0 } }
                }
                .disabled(code == nil)
            }
        }
    }

    private var footnote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock.shield").foregroundStyle(.green)
            Text("End-to-end encrypted. The relay only forwards encrypted SSH bytes — it cannot read or modify your terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorCard(_ msg: String) -> some View {
        GroupBox {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(msg).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { Task { await fetch() } }
            }
        }
    }

    private func fetch() async {
        do {
            code = nil
            error = nil
            remainingSec = 60
            daemonID = bento.currentDaemonID()
            code = try await bento.pair()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func copy(_ s: String, setFlag: @escaping (Bool) -> Void) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        setFlag(true)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            setFlag(false)
        }
    }

    private func qrImage(for string: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage else { return nil }
        let scale = size / max(ci.extent.width, 1)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - Building blocks

/// Card is a lightweight bordered container with a small title label and an
/// optional trailing accessory in the header row. Matches Apple's "labeled
/// content cell" style without depending on a list.
private struct Card<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    init(title: String, trailing: AnyView? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

private struct CopyButton: View {
    let copied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? .green : .accentColor)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(copied ? "Copied" : "Copy to clipboard")
    }
}
