import Foundation

/// Streaming ASR client for OpenAI's Realtime API in transcription-only mode
/// (`gpt-realtime-whisper`). Pure Foundation — shared by iOS + macOS.
///
/// Auth: a token-mint proxy (default `defaultProxyURL`, works zero-config) or
/// direct BYOK `apiKey`. Wire protocol: WSS to `/v1/realtime`, configure
/// `type=transcription` PCM@24kHz, manual commit on stop (no turn_detection).
public final class OpenAIRealtimeASRService: NSObject, @unchecked Sendable {
    public enum ASRError: LocalizedError {
        case missingCredentials
        case mintFailed(String)
        case unexpectedInitialMessage(String)
        case server(String)

        public var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "OpenAI API key or proxy URL not set. Add one in Settings → Speech."
            case .mintFailed(let s):
                return "Failed to mint ephemeral token: \(s)"
            case .unexpectedInitialMessage(let s):
                return "OpenAI Realtime handshake failed: \(s)"
            case .server(let s):
                return s
            }
        }
    }

    /// Sample rate the audio capture layer must produce.
    public static let requiredSampleRate: Double = 24000

    /// Bundled relay mint endpoint — works out-of-the-box without user config.
    public static let defaultProxyURL = URL(string: "https://bento-relay.styleshang.workers.dev/v1/asr/mint")!

    private let apiKey: String
    private let proxyURL: URL?
    private let model: String
    private let language: String
    private let endpoint: URL

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var readerTask: Task<Void, Never>?
    private var isOpen = false
    private var accumulatedDelta = ""
    private var currentItemId: String?

    public var onInterim: (@Sendable (String) -> Void)?
    public var onFinal: (@Sendable (String) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?

    public init(
        apiKey: String = "",
        proxyURL: URL? = nil,
        language: String = "",
        model: String = "gpt-realtime-whisper",
        endpoint: URL = URL(string: "wss://api.openai.com/v1/realtime")!
    ) {
        self.apiKey = apiKey
        self.proxyURL = proxyURL
        self.language = language
        self.model = model
        self.endpoint = endpoint
    }

    public func start() async throws {
        let bearer: String
        if let proxyURL {
            bearer = try await mintEphemeralToken(proxyURL: proxyURL)
        } else if !apiKey.isEmpty {
            bearer = apiKey
        } else {
            throw ASRError.missingCredentials
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        let urlSession = URLSession(configuration: .default)
        let wsTask = urlSession.webSocketTask(with: request)
        self.session = urlSession
        self.task = wsTask
        wsTask.resume()

        let firstMsg = try await receiveText(task: wsTask)
        guard let json = parseJSON(firstMsg),
              json["type"] as? String == "session.created" else {
            throw ASRError.unexpectedInitialMessage(firstMsg)
        }

        var transcription: [String: Any] = ["model": model]
        if !language.isEmpty { transcription["language"] = language }

        let config: [String: Any] = [
            "event_id": "evt_\(UUID().uuidString.prefix(8))",
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Int(Self.requiredSampleRate),
                        ] as [String: Any],
                        "transcription": transcription,
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
        try await sendJSON(config, on: wsTask)
        isOpen = true

        readerTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    public func sendAudio(_ pcm: Data) async {
        guard isOpen, let task, !pcm.isEmpty else { return }
        let b64 = pcm.base64EncodedString()
        let payload: [String: Any] = [
            "event_id": "evt_\(UUID().uuidString.prefix(8))",
            "type": "input_audio_buffer.append",
            "audio": b64,
        ]
        try? await sendJSON(payload, on: task)
    }

    public func stop() async {
        guard isOpen else { return }
        isOpen = false
        if let task {
            try? await sendJSON([
                "event_id": "evt_\(UUID().uuidString.prefix(8))",
                "type": "input_audio_buffer.commit",
            ], on: task)
            try? await Task.sleep(for: .milliseconds(700))
            task.cancel(with: .normalClosure, reason: nil)
        }
        task = nil
        readerTask?.cancel()
        readerTask = nil
        session?.invalidateAndCancel()
        session = nil
        accumulatedDelta = ""
        currentItemId = nil
    }

    private func mintEphemeralToken(proxyURL: URL) async throws -> String {
        var req = URLRequest(url: proxyURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "language": language]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "non-2xx"
            throw ASRError.mintFailed(msg)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ASRError.mintFailed("invalid JSON")
        }
        if let v = obj["value"] as? String, !v.isEmpty { return v }
        if let cs = obj["client_secret"] as? [String: Any],
           let v = cs["value"] as? String, !v.isEmpty { return v }
        throw ASRError.mintFailed("missing client_secret in response")
    }

    private func sendJSON(_ obj: [String: Any], on task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(text))
    }

    private func parseJSON(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func receiveText(task: URLSessionWebSocketTask) async throws -> String {
        let msg = try await task.receive()
        switch msg {
        case .string(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8) ?? ""
        @unknown default: return ""
        }
    }

    private func readLoop() async {
        while isOpen, let task {
            do {
                let s = try await receiveText(task: task)
                guard let json = parseJSON(s),
                      let type = json["type"] as? String else { continue }
                switch type {
                case "conversation.item.input_audio_transcription.delta":
                    if let itemId = json["item_id"] as? String, itemId != currentItemId {
                        currentItemId = itemId
                        accumulatedDelta = ""
                    }
                    if let delta = json["delta"] as? String, !delta.isEmpty {
                        accumulatedDelta += delta
                        onInterim?(accumulatedDelta)
                    }
                case "conversation.item.input_audio_transcription.completed":
                    if let text = json["transcript"] as? String, !text.isEmpty {
                        onFinal?(text)
                    }
                    accumulatedDelta = ""
                case "error":
                    let info = (json["error"] as? [String: Any])?["message"] as? String
                        ?? "OpenAI Realtime error"
                    onError?(ASRError.server(info))
                    return
                default:
                    break
                }
            } catch {
                if isOpen { onError?(error) }
                return
            }
        }
    }
}
