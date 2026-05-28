import Foundation
import AVFoundation

/// Captures microphone audio and emits chunks of 16-bit mono PCM at a
/// caller-specified sample rate. Uses AVAudioEngine + AVAudioConverter so the
/// output is independent of the hardware's native sample rate.
///
/// Qwen ASR expects 16 kHz; OpenAI gpt-realtime-whisper expects 24 kHz.
final class AudioCaptureService: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case converterUnavailable
        var errorDescription: String? { "Could not create audio converter." }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat!
    private var targetRate: Double = 16000
    private(set) var isRunning = false

    /// Called on the audio queue with each PCM chunk as it arrives.
    var onPCM: (@Sendable (Data) -> Void)?

    func start(targetSampleRate: Double = 16000) throws {
        self.targetRate = targetSampleRate
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

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

    func stop() {
        guard isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false
        converter = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
                status.pointee = .endOfStream
                return nil
            }
            didProvide = true
            status.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, error == nil else { return }
        guard let int16Ptr = outBuf.int16ChannelData?[0] else { return }

        let frames = Int(outBuf.frameLength)
        let byteCount = frames * MemoryLayout<Int16>.stride
        let data = Data(bytes: int16Ptr, count: byteCount)
        onPCM?(data)
    }
}
