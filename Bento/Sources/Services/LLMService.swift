import Foundation

/// Translates a natural-language utterance into a single shell command using
/// an OpenAI-compatible chat completion endpoint. Bring-your-own-key: the
/// LLM and the Qwen ASR can use independent API keys (the LLM key falls back
/// to the Qwen ASR key when empty, since DashScope accepts the same key for
/// both products — convenient default for users running everything on Qwen).
final class LLMService: @unchecked Sendable {
    static let shared = LLMService()

    private let session = URLSession(configuration: .default)

    /// Whether the LLM feature is configured and enabled — UI toggles + a
    /// non-empty key. When disabled, voice→shell falls back to inserting the
    /// raw transcript.
    var isConfigured: Bool {
        enabled && !apiKey.isEmpty
    }

    private var enabled: Bool {
        // Default to enabled when the key isn't set yet, otherwise honour
        // the user's explicit toggle.
        if UserDefaults.standard.object(forKey: "llm_enabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "llm_enabled")
    }

    /// LLM-specific BYOK with fall-back to the shared Qwen ASR key.
    private var apiKey: String {
        let dedicated = UserDefaults.standard.string(forKey: "llm_api_key") ?? ""
        if !dedicated.isEmpty { return dedicated }
        return UserDefaults.standard.string(forKey: "qwen_api_key") ?? ""
    }

    private var endpoint: URL {
        let urlStr = UserDefaults.standard.string(forKey: "llm_endpoint") ?? defaultEndpoint
        return URL(string: urlStr) ?? URL(string: defaultEndpoint)!
    }

    private var model: String {
        let m = UserDefaults.standard.string(forKey: "llm_model") ?? ""
        return m.isEmpty ? "qwen-plus" : m
    }

    private let defaultEndpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"

    /// Convert natural language to a shell command. Returns the original
    /// transcript on any failure (or when disabled) so the user still gets
    /// typed text.
    func convertToShellCommand(transcript: String, context: String) async -> String {
        guard isConfigured else { return transcript }

        let system = """
        You convert a natural-language request into a single shell command for a Unix-like system.
        Rules:
        - Output the command and only the command — no explanation, no markdown fences, no leading "$".
        - If the request implies multiple steps, chain them with && or use a one-liner.
        - Prefer common, portable tools (bash, coreutils, git). Use sudo only if explicitly asked.
        - If the request is ambiguous or unsafe, output a best-effort safe command.
        Recent terminal context (most recent at the bottom):
        \(context.isEmpty ? "(none)" : context)
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": transcript],
            ],
            "temperature": 0.2,
            "max_tokens": 256,
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return transcript }
            guard (200...299).contains(http.statusCode) else {
                let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                dlog("LLM HTTP \(http.statusCode): \(snippet)")
                return transcript
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return transcript
            }
            return cleanCommand(content)
        } catch {
            dlog("LLM error: \(error)")
            return transcript
        }
    }

    /// Strip code fences, leading shell prompts, and surrounding whitespace.
    private func cleanCommand(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip ```...``` fences if present, keeping inner content.
        if s.hasPrefix("```") {
            // Drop the opening fence (and optional language tag).
            if let firstNL = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNL)...])
            } else {
                s = String(s.dropFirst(3))
            }
            if s.hasSuffix("```") {
                s = String(s.dropLast(3))
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Drop a leading "$ " or "# " prompt marker.
        for prefix in ["$ ", "# ", "> "] {
            if s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        }
        return s
    }
}
