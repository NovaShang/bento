import SwiftUI

/// RelayPairView is the sheet shown when the user taps "Pair via Bento Relay".
/// They enter the daemon_id displayed on the Mac menubar plus the 6-digit
/// pairing code; on success a new RelayDaemon row appears in the host list.
struct RelayPairView: View {
    @EnvironmentObject private var store: RelayDaemonStore
    @Environment(\.dismiss) private var dismiss

    @State private var daemonID: String = ""
    @State private var code: String = ""
    @State private var label: String = ""
    @State private var error: String?
    @State private var working: Bool = false

    /// Test hook: when UserDefaults keys "pair_prefill_*" are set we
    /// pre-populate the fields on appear. Maestro / smoke flows seed these
    /// via `xcrun simctl spawn booted defaults write com.bento.app …` so the
    /// pair flow can be exercised without driving the on-screen keyboard.
    private func applyTestPrefill() {
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

    var body: some View {
        NavigationStack {
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
                            // Numeric only, max 6 digits.
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
            .navigationTitle("Pair Mac via Relay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Pair") {
                        Task { await pair() }
                    }
                    .disabled(!canSubmit || working)
                }
            }
            .overlay {
                if working {
                    ProgressView("Pairing…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .onAppear { applyTestPrefill() }
        }
    }

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
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
