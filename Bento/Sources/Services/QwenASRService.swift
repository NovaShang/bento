import Foundation

/// Streaming ASR client for Alibaba DashScope's Qwen-ASR-Realtime endpoint.
///
/// Mirrors the protocol used by load-survey/backend/services/asr.py but talks
/// to DashScope directly from the device. Audio frames are sent as base64
/// PCM 16-bit / 16 kHz mono wrapped in `input_audio_buffer.append` events;
/// transcripts come back as `conversation.item.input_audio_transcription.{text,completed}`.
final class QwenASRService: NSObject, @unchecked Sendable {
    enum ASRError: LocalizedError {
        case missingAPIKey
        case unexpectedInitialMessage(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Qwen API key not set. Add one in Settings → Voice."
            case .unexpectedInitialMessage(let s):
                return "ASR handshake failed: \(s)"
            case .server(let s):
                return s
            }
        }
    }

    private let apiKey: String
    private let model: String
    private let language: String
    private let endpoint: URL

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var readerTask: Task<Void, Never>?
    private var isOpen = false

    /// Streaming partial transcript.
    var onInterim: (@Sendable (String) -> Void)?
    /// Final transcript for a turn (after server-side VAD detects sentence end).
    var onFinal: (@Sendable (String) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    init(
        apiKey: String,
        language: String = "zh",
        model: String = "qwen3-asr-flash-realtime",
        endpoint: URL = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime")!
    ) {
        self.apiKey = apiKey
        self.language = language
        self.model = model
        self.endpoint = endpoint
    }

    func start() async throws {
        guard !apiKey.isEmpty else { throw ASRError.missingAPIKey }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let urlSession = URLSession(configuration: .default)
        let wsTask = urlSession.webSocketTask(with: request)
        self.session = urlSession
        self.task = wsTask
        wsTask.resume()

        // Wait for session.created.
        let firstMsg = try await receiveText(task: wsTask)
        guard let json = parseJSON(firstMsg),
              json["type"] as? String == "session.created" else {
            throw ASRError.unexpectedInitialMessage(firstMsg)
        }

        // Configure session — pcm/16kHz, server VAD with a long silence window
        // so natural pauses don't end the turn.
        let config: [String: Any] = [
            "event_id": "evt_\(UUID().uuidString.prefix(8))",
            "type": "session.update",
            "session": [
                "input_audio_format": "pcm",
                "sample_rate": 16000,
                "input_audio_transcription": ["language": language],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.0,
                    "silence_duration_ms": 1500,
                ] as [String: Any],
            ] as [String: Any],
        ]
        try await sendJSON(config, on: wsTask)
        isOpen = true

        readerTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    func sendAudio(_ pcm: Data) async {
        guard isOpen, let task else { return }
        let b64 = pcm.base64EncodedString()
        let payload: [String: Any] = [
            "event_id": "evt_\(UUID().uuidString.prefix(8))",
            "type": "input_audio_buffer.append",
            "audio": b64,
        ]
        try? await sendJSON(payload, on: task)
    }

    func stop() async {
        guard isOpen else { return }
        isOpen = false
        if let task {
            try? await sendJSON([
                "event_id": "evt_\(UUID().uuidString.prefix(8))",
                "type": "session.finish",
            ], on: task)
            try? await Task.sleep(for: .milliseconds(500))
            task.cancel(with: .normalClosure, reason: nil)
        }
        task = nil
        readerTask?.cancel()
        readerTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Internal

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
                case "conversation.item.input_audio_transcription.text":
                    if let stash = json["stash"] as? String, !stash.isEmpty {
                        onInterim?(stash)
                    }
                case "conversation.item.input_audio_transcription.completed":
                    if let text = json["transcript"] as? String, !text.isEmpty {
                        onFinal?(text)
                    }
                case "error":
                    let info = (json["error"] as? [String: Any])?["message"] as? String
                        ?? "ASR error"
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
