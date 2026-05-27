import SwiftUI

/// RelayPairView is the sheet shown when the user taps "Pair via Bento Relay".
///
/// Default mode is the camera QR scanner — the Mac pairing window renders a
/// QR encoding `bento://pair?d=…&c=…`, and a single scan auto-fills both
/// fields and kicks off the pair request. The user can fall back to manual
/// entry via the "Enter manually" button (the only path when scanning isn't
/// supported, e.g. on the simulator or after the user denied camera access).
struct RelayPairView: View {
    @EnvironmentObject private var store: RelayDaemonStore
    @Environment(\.dismiss) private var dismiss

    /// Values delivered by the `bento://pair?d=&c=&l=` deep link. Applied
    /// on appear (alongside the UserDefaults test hook). Nil when the user
    /// opened the sheet manually from the + menu.
    let prefill: PendingRelayPair?

    private enum Mode { case scan, manual }

    @State private var mode: Mode
    @State private var daemonID: String = ""
    @State private var code: String = ""
    @State private var label: String = ""
    @State private var error: String?
    @State private var working: Bool = false
    @State private var scanHint: String?

    init(prefill: PendingRelayPair? = nil) {
        self.prefill = prefill
        // If we already have prefill (deep link) or scanning isn't supported
        // (simulator, no camera), open straight to manual entry.
        let canScan = QRScannerView.isSupported
        _mode = State(initialValue: (prefill != nil || !canScan) ? .manual : .scan)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .scan: scannerSurface
                case .manual: manualForm
                }
            }
            .navigationTitle("Pair Mac via Relay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                if mode == .manual {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Pair") {
                            Task { await pair() }
                        }
                        .disabled(!canSubmit || working)
                    }
                }
            }
            .overlay {
                if working {
                    ProgressView("Pairing…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .onAppear { applyPrefill() }
        }
    }

    // MARK: - Scanner surface

    private var scannerSurface: some View {
        ZStack(alignment: .bottom) {
            QRScannerView { payload in
                handleScan(payload)
            }
            .ignoresSafeArea()

            VStack(spacing: 12) {
                if let scanHint {
                    Text(scanHint)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }
                Text("Point at the QR code in Bento on your Mac")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())

                Button {
                    mode = .manual
                } label: {
                    Label("Enter manually", systemImage: "keyboard")
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 36)
        }
    }

    private func handleScan(_ payload: String) {
        guard let url = URL(string: payload),
              url.scheme == "bento",
              url.host == "pair",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            scanHint = "Not a Bento pairing code"
            return
        }
        let items = comps.queryItems ?? []
        let d = items.first(where: { $0.name == "d" })?.value ?? ""
        let raw = items.first(where: { $0.name == "c" })?.value ?? ""
        let c = String(raw.filter(\.isNumber).prefix(6))
        guard !d.isEmpty, c.count == 6 else {
            scanHint = "QR is missing daemon ID or code"
            return
        }
        daemonID = d
        code = c
        if label.isEmpty, let l = items.first(where: { $0.name == "l" })?.value {
            label = l
        }
        Task { await pair() }
    }

    // MARK: - Manual form

    private var manualForm: some View {
        Form {
            Section {
                HStack {
                    TextField("daemon-id (paste from Mac)", text: $daemonID)
                        .font(.system(.callout, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("pair_daemon_id")
                    Button {
                        if let s = UIPasteboard.general.string {
                            daemonID = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                }
            } footer: {
                Text("Open Bento on your Mac, click the menubar icon, look under the connection status — that's the daemon ID.")
            }

            Section("6-digit code") {
                TextField("------", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(.title, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("pair_code")
                    .onChange(of: code) { _, new in
                        let filtered = new.filter(\.isNumber)
                        code = String(filtered.prefix(6))
                    }
            }

            Section("Label (optional)") {
                TextField("e.g. Office Mac mini", text: $label)
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if QRScannerView.isSupported {
                Section {
                    Button {
                        error = nil
                        mode = .scan
                    } label: {
                        Label("Scan QR instead", systemImage: "qrcode.viewfinder")
                    }
                }
            }

            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("End-to-end encrypted")
                            .font(.callout.weight(.medium))
                        Text("Your iPhone and Mac generate fresh Ed25519 keys at pairing time. All terminal traffic is encrypted under SSH between the two devices — the Bento relay only forwards encrypted bytes and cannot read or modify them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Prefill

    /// Apply prefill from either the deep-link argument or the
    /// UserDefaults test hook (Maestro / smoke flows seed
    /// `pair_prefill_*` so the flow can be exercised without driving the
    /// on-screen keyboard).
    private func applyPrefill() {
        if let p = prefill {
            if daemonID.isEmpty { daemonID = p.daemonID }
            if code.isEmpty { code = String(p.code.filter(\.isNumber).prefix(6)) }
            if label.isEmpty, let l = p.label { label = l }
        }
        let d = UserDefaults.standard
        if daemonID.isEmpty, let s = d.string(forKey: "pair_prefill_daemon") {
            daemonID = s
        }
        if code.isEmpty, let s = d.string(forKey: "pair_prefill_code") {
            code = String(s.filter(\.isNumber).prefix(6))
        }
        if label.isEmpty, let s = d.string(forKey: "pair_prefill_label") {
            label = s
        }
    }

    // MARK: - Pair

    private var canSubmit: Bool {
        !daemonID.isEmpty && code.count == 6
    }

    private func pair() async {
        working = true
        error = nil
        defer { working = false }
        do {
            let daemon = try await RelayPairingService.shared.pair(
                daemonID: daemonID,
                code: code,
                label: label
            )
            store.add(daemon)
            dismiss()
        } catch {
            // Surface the failure in the manual form; flip mode so the user
            // can adjust the values they just entered (or re-scan).
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            mode = .manual
        }
    }
}
