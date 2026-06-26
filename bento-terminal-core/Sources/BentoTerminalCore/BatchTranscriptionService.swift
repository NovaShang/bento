import Foundation

/// One-shot (non-realtime) transcription of a COMPLETE utterance via OpenAI's
/// `/v1/audio/transcriptions` (`gpt-4o-transcribe`) — higher accuracy than the
/// streaming realtime model because it sees the whole clip at once. Backs the
/// right-swipe "transcribe → preview → edit → send" flow.
///
/// Zero-config by default: posts raw WAV to the bundled relay, which injects the
/// key and forces the model (same pattern as the ASR mint). If the user set their
/// own `openai_api_key`, posts the multipart form straight to OpenAI (BYOK).
public final class BatchTranscriptionService: @unchecked Sendable {
    public static let shared = BatchTranscriptionService()
    private let session = URLSession(configuration: .default)

    private static let relayURL = URL(string: "https://bento-relay.styleshang.workers.dev/v1/audio/transcriptions")!
    private static let directURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private static let model = "gpt-4o-transcribe"

    public init() {}

    /// Transcribe 16-bit mono PCM at `sampleRate`. `language` is an optional
    /// ISO-639-1 hint ("" = auto). Returns the text, or nil on empty/failure.
    public func transcribe(pcm: Data, sampleRate: Double, language: String = "") async -> String? {
        guard !pcm.isEmpty else { return nil }
        let wav = Self.wav(pcm: pcm, sampleRate: sampleRate)

        let key = (UserDefaults.standard.string(forKey: "openai_api_key") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var request: URLRequest
        if key.isEmpty {
            // Zero-config: raw WAV to the relay; it builds the multipart + injects key.
            var comps = URLComponents(url: Self.relayURL, resolvingAgainstBaseURL: false)!
            if !language.isEmpty { comps.queryItems = [URLQueryItem(name: "language", value: language)] }
            request = URLRequest(url: comps.url!)
            request.httpMethod = "POST"
            request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
            request.httpBody = wav
        } else {
            // BYOK: multipart form straight to OpenAI.
            let boundary = "bento-\(UUID().uuidString)"
            request = URLRequest(url: Self.directURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.multipart(wav: wav, language: language, boundary: boundary)
        }
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                dlog("[batch-asr] HTTP \(code): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            dlog("[batch-asr] error: \(error)")
            return nil
        }
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

    private static func multipart(wav: Data, language: String, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        field("model", Self.model)
        field("response_format", "json")
        if !language.isEmpty { field("language", language) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
