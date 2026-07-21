import Foundation

/// One-shot (non-realtime) transcription of a COMPLETE utterance via Qwen
/// (`qwen3-asr-flash` on DashScope) — higher accuracy than the streaming
/// realtime model because it sees the whole clip at once. Backs the
/// right-swipe "transcribe → preview → edit → send" flow.
///
/// Zero-config by default: posts the clip to the bundled relay, which injects
/// the key. If the user set their own `dashscope_api_key`, posts straight to
/// DashScope (BYOK).
public final class BatchTranscriptionService: @unchecked Sendable {
    public static let shared = BatchTranscriptionService()
    private let session = URLSession(configuration: .default)

    // Qwen batch (DashScope multimodal). Relay normalizes the response to
    // `{ text }` (zero-config, key injected server-side); direct is BYOK.
    private static let qwenRelayURL = URL(string: "https://bento-relay-acp.styleshang.workers.dev/v1/asr/qwen/transcribe")!
    private static let qwenDirectURL = URL(string: "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!

    public init() {}

    /// Transcribe 16-bit mono PCM at `sampleRate` via Qwen. `language` is an
    /// optional ISO-639-1 hint ("" = auto); `corpus` is Qwen context-biasing
    /// text. Returns the text, or nil on empty/failure.
    public func transcribe(pcm: Data, sampleRate: Double, language: String = "", corpus: String = "") async -> String? {
        guard !pcm.isEmpty else { return nil }
        let wav = Self.wav(pcm: pcm, sampleRate: sampleRate)
        return await transcribeQwen(wav: wav, language: language, corpus: corpus)
    }

    /// Qwen `qwen3-asr-flash` batch via DashScope multimodal ASR. Zero-config posts
    /// `{ audio, language?, corpus? }` to the relay (which injects the key and
    /// returns `{ text }`); BYOK posts the native DashScope request directly.
    private func transcribeQwen(wav: Data, language: String, corpus: String) async -> String? {
        let b64 = wav.base64EncodedString()
        let key = (UserDefaults.standard.string(forKey: "dashscope_api_key") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let direct = !key.isEmpty

        var request: URLRequest
        if direct {
            request = URLRequest(url: Self.qwenDirectURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var asrOptions: [String: Any] = ["enable_lid": true, "enable_itn": false]
            if !language.isEmpty { asrOptions["language"] = language }
            let payload: [String: Any] = [
                "model": "qwen3-asr-flash",
                "input": ["messages": [
                    ["role": "system", "content": [["text": corpus]]],
                    ["role": "user", "content": [["audio": "data:audio/wav;base64,\(b64)"]]],
                ]],
                "parameters": ["asr_options": asrOptions],
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        } else {
            request = URLRequest(url: Self.qwenRelayURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var payload: [String: Any] = ["audio": b64]
            if !language.isEmpty { payload["language"] = language }
            if !corpus.isEmpty { payload["corpus"] = corpus }
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                dlog("[batch-asr] qwen HTTP \(code): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            // Relay returns { text }; direct returns the native DashScope shape.
            let text = direct ? Self.parseDashScope(json) : (json["text"] as? String)
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            dlog("[batch-asr] qwen error: \(error)")
            return nil
        }
    }

    /// Pull the transcript from a native DashScope multimodal response:
    /// `output.choices[0].message.content[<text part>].text`.
    private static func parseDashScope(_ json: [String: Any]) -> String? {
        guard let output = json["output"] as? [String: Any],
              let choices = output["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        for part in content { if let t = part["text"] as? String { return t } }
        return nil
    }

    /// Wrap raw little-endian 16-bit mono PCM in a 44-byte WAV header.
    static func wav(pcm: Data, sampleRate: Double) -> Data {
        let rate = UInt32(sampleRate)
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let byteRate = rate * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * (bits / 8)
        let dataLen = UInt32(pcm.count)
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        var h = Data()
        h.append("RIFF".data(using: .ascii)!)
        h.append(u32(36 + dataLen))
        h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!)
        h.append(u32(16))            // PCM fmt-chunk size
        h.append(u16(1))             // format = PCM
        h.append(u16(channels))
        h.append(u32(rate))
        h.append(u32(byteRate))
        h.append(u16(blockAlign))
        h.append(u16(bits))
        h.append("data".data(using: .ascii)!)
        h.append(u32(dataLen))
        h.append(pcm)
        return h
    }

}
