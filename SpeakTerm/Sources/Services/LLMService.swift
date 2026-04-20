import Foundation

/// Converts natural language to shell commands using a user-provided LLM API.
///
/// Phase 6: full implementation with OpenAI/Anthropic API.
/// Currently a stub that returns the input text as-is.
final class LLMService: @unchecked Sendable {
    static let shared = LLMService()

    private(set) var isConfigured = false
    private var apiKey: String?
    private var endpoint: String?

    private init() {
        loadConfig()
    }

    /// Configure the LLM service with an API key and endpoint
    func configure(apiKey: String, endpoint: String) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.isConfigured = true
        saveConfig()
    }

    /// Convert natural language to a shell command
    /// - Parameters:
    ///   - transcript: The voice transcript
    ///   - context: Last N lines of pane output for context
    /// - Returns: The generated shell command
    func convertToShellCommand(transcript: String, context: String) async -> String {
        guard isConfigured, let apiKey, let endpoint else {
            // Not configured — return transcript as-is
            return transcript
        }

        // TODO: Phase 6 — actual API call to OpenAI/Anthropic
        // For now, return the transcript
        _ = apiKey
        _ = endpoint
        _ = context
        return transcript
    }

    // MARK: - Persistence

    private func loadConfig() {
        apiKey = UserDefaults.standard.string(forKey: "llm_api_key")
        endpoint = UserDefaults.standard.string(forKey: "llm_endpoint")
        isConfigured = apiKey != nil && endpoint != nil
    }

    private func saveConfig() {
        UserDefaults.standard.set(apiKey, forKey: "llm_api_key")
        UserDefaults.standard.set(endpoint, forKey: "llm_endpoint")
    }
}
