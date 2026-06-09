import Foundation
import AVFoundation

/// Captures microphone audio and emits 16-bit mono PCM chunks at a target rate
/// (OpenAI gpt-realtime-whisper wants 24 kHz). AVAudioEngine + AVAudioConverter
/// so output is independent of the hardware rate. Cross-platform — only the
/// AVAudioSession setup is iOS-specific (macOS has no session model).
public final class AudioCaptureService: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case converterUnavailable
        var errorDescription: String? { "Could not create audio converter." }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat!
    private var targetRate: Double = 16000
    public private(set) var isRunning = false

    /// Called on the audio queue with each PCM chunk as it arrives.
    public var onPCM: (@Sendable (Data) -> Void)?

    public init() {}

    public func start(targetSampleRate: Double = 16000) throws {
        // Never stack a second engine/tap on top of a running one: installing two
        // taps on the same input bus corrupts CoreAudio and hangs the main thread.
        // A prior session that failed without a clean stop must be torn down first.
        if isRunning { stop() }
        engine.inputNode.removeTap(onBus: 0)   // belt-and-suspenders: drop any stale tap
        self.targetRate = targetSampleRate
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            // macOS can hand back a 0Hz/0ch format if the mic isn't ready yet.
            throw CaptureError.converterUnavailable
        }

        guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = conv

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false
        converter = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func handleBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter, let outputFormat else { return }
        let inputRate = inputBuffer.format.sampleRate
        let estFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * targetRate / inputRate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: estFrames) else {
            return
        }

        var error: NSError?
        var didProvide = false
        let status = converter.convert(to: outBuf, error: &error) { _, status in
            if didProvide {
                // `.noDataNow` (not `.endOfStream`): we've handed over this tap
                // buffer; the converter consumes it and stays usable for the next
                // buffer. `.endOfStream` would permanently end the (reused)
                // converter, so only the first 100ms ever converted.
                status.pointee = .noDataNow
                return nil
            }
            didProvide = true
            status.pointee = .haveData
            return inputBuffer
        }

        guard error == nil, status != .error else { return }
        guard let int16Ptr = outBuf.int16ChannelData?[0] else { return }

        let frames = Int(outBuf.frameLength)
        let byteCount = frames * MemoryLayout<Int16>.stride
        guard byteCount > 0 else { return }   // never emit an empty chunk (→ "invalid audio")
        let data = Data(bytes: int16Ptr, count: byteCount)
        onPCM?(data)
    }
}
