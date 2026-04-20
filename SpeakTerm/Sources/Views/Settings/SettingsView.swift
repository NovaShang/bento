import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("terminal_font_size") private var fontSize: Double = 12
    @AppStorage("haptics_enabled") private var hapticsEnabled = true
    @State private var llmApiKey: String = UserDefaults.standard.string(forKey: "llm_api_key") ?? ""
    @State private var llmEndpoint: String = UserDefaults.standard.string(forKey: "llm_endpoint") ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Terminal") {
                    HStack {
                        Text("Font Size")
                        Slider(value: $fontSize, in: 8...24, step: 1)
                        Text("\(Int(fontSize))")
                            .monospacedDigit()
                    }
                }

                Section("Feedback") {
                    Toggle("Haptic Feedback", isOn: $hapticsEnabled)
                }

                Section("LLM (Voice → Shell)") {
                    TextField("API Endpoint", text: $llmEndpoint)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                    SecureField("API Key", text: $llmApiKey)

                    Button("Save LLM Config") {
                        LLMService.shared.configure(apiKey: llmApiKey, endpoint: llmEndpoint)
                    }
                    .disabled(llmApiKey.isEmpty || llmEndpoint.isEmpty)
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("0.1.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
