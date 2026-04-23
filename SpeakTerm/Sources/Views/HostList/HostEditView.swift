import SwiftUI
import UniformTypeIdentifiers

enum HostEditMode {
    case add
    case edit(Host)
}

struct HostEditView: View {
    @Environment(\.dismiss) private var dismiss

    let mode: HostEditMode
    let onSave: (Host) -> Void

    @State private var name: String = ""
    @State private var hostname: String = ""
    @State private var port: String = "22"
    @State private var username: String = "root"
    @State private var authType: Int = 0 // 0 = password, 1 = key
    @State private var password: String = ""
    @State private var importedKeyLabel: String?
    @State private var showKeyImporter = false
    @State private var unlockMacKeychain = false
    @State private var keychainPassword: String = ""
    @State private var useTmux = true
    @State private var tmuxSessionName: String = ""
    @State private var showError = false
    @State private var errorMessage = ""

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    init(mode: HostEditMode, onSave: @escaping (Host) -> Void) {
        self.mode = mode
        self.onSave = onSave
        if case .edit(let host) = mode {
            _name = State(initialValue: host.name)
            _hostname = State(initialValue: host.hostname)
            _port = State(initialValue: String(host.port))
            _username = State(initialValue: host.username)
            switch host.authMethod {
            case .password:
                _authType = State(initialValue: 0)
            case .privateKey(let label):
                _authType = State(initialValue: 1)
                _importedKeyLabel = State(initialValue: label)
            }
            _unlockMacKeychain = State(initialValue: host.unlockMacKeychain)
            _useTmux = State(initialValue: host.useTmux)
            _tmuxSessionName = State(initialValue: host.tmuxSessionName)
        }
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Display Name (optional)", text: $name)
                    .textContentType(.nickname)
                    .autocorrectionDisabled()

                TextField("Hostname or IP", text: $hostname)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()

                TextField("Port", text: $port)
                    .keyboardType(.numberPad)

                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            }

            Section("Authentication") {
                Picker("Method", selection: $authType) {
                    Text("Password").tag(0)
                    Text("Private Key").tag(1)
                }
                .pickerStyle(.segmented)

                if authType == 0 {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } else {
                    if let label = importedKeyLabel {
                        HStack {
                            Label(label, systemImage: "key.fill")
                                .lineLimit(1)
                            Spacer()
                            Button("Change") {
                                showKeyImporter = true
                            }
                            .font(.caption)
                        }
                    } else {
                        Button("Import Private Key File") {
                            showKeyImporter = true
                        }
                    }
                }
            }

            Section {
                Toggle("Use tmux", isOn: $useTmux)
                if useTmux {
                    TextField("Session Name (optional)", text: $tmuxSessionName)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Terminal Multiplexer")
            } footer: {
                if useTmux {
                    Text("""
                    tmux enables split panes, session persistence, and sharing with desktop. \
                    Set a session name to attach to an existing tmux session on the server \
                    (e.g. "main"). Leave empty for a standalone session.
                    """)
                } else {
                    Text("""
                    Without tmux you get a single terminal pane with no split or session persistence. \
                    tmux must be installed on the server — install via: \
                    brew install tmux (macOS), apt install tmux (Linux).
                    """)
                }
            }

            Section {
                Toggle("Unlock Mac Keychain", isOn: $unlockMacKeychain)
                if unlockMacKeychain {
                    SecureField("Mac Login Password", text: $keychainPassword)
                        .textContentType(.password)
                }
            } header: {
                Text("macOS")
            } footer: {
                if unlockMacKeychain {
                    Text("Runs `security unlock-keychain` after connecting. Password is stored in the app's keychain.")
                }
            }
        }
        .navigationTitle(isEditing ? "Edit Host" : "Add Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!isValid)
            }
        }
        .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.data, .text]) { result in
            handleKeyImport(result)
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    private var isValid: Bool {
        !hostname.isEmpty && !username.isEmpty &&
        (authType == 0 ? !password.isEmpty : importedKeyLabel != nil)
    }

    private func save() {
        let portNum = UInt16(port) ?? 22

        var host: Host
        if case .edit(let existing) = mode {
            host = existing
        } else {
            host = Host()
        }

        host.name = name
        host.hostname = hostname
        host.port = portNum
        host.username = username

        if authType == 0 {
            host.authMethod = .password
            do {
                try KeychainService.shared.savePassword(password, for: host.id.uuidString)
            } catch {
                errorMessage = "Failed to save password: \(error.localizedDescription)"
                showError = true
                return
            }
        } else if let keyLabel = importedKeyLabel {
            host.authMethod = .privateKey(keyLabel: keyLabel)
        }

        host.useTmux = useTmux
        host.tmuxSessionName = useTmux ? tmuxSessionName : ""
        host.unlockMacKeychain = unlockMacKeychain
        if unlockMacKeychain && !keychainPassword.isEmpty {
            do {
                try KeychainService.shared.savePassword(keychainPassword, for: "macKeychain:\(host.id.uuidString)")
            } catch {
                errorMessage = "Failed to save keychain password: \(error.localizedDescription)"
                showError = true
                return
            }
        }

        onSave(host)
        dismiss()
    }

    private func handleKeyImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Cannot access the selected file."
                showError = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let keyData = try Data(contentsOf: url)
                let label = url.lastPathComponent
                try KeychainService.shared.savePrivateKey(keyData, label: label)
                importedKeyLabel = label
            } catch {
                errorMessage = "Failed to import key: \(error.localizedDescription)"
                showError = true
            }

        case .failure(let error):
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
