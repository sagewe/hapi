#if !targetEnvironment(macCatalyst)
import AVFoundation
import Foundation
import HapiClient

/// Non-actor-isolated CoreAudio tap processor so `AVAudioNode.installTap` never
/// inherits `@MainActor` isolation on the realtime audio render thread.
private final class PCMTapProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let onChunk: @Sendable (Data, Float) -> Void
    private let targetChunkBytes = 3_200 // 100ms @ 16kHz 16-bit mono
    private let maxAccumulatedBytes = 16_000 * 2 * 180 // 180s cap (~5.76 MB)

    private var pendingChunk = Data()
    private var accumulatedPCM = Data()
    private var stopped = false

    init(
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter,
        onChunk: @escaping @Sendable (Data, Float) -> Void
    ) {
        self.outputFormat = outputFormat
        self.converter = converter
        self.onChunk = onChunk
        self.pendingChunk.reserveCapacity(targetChunkBytes * 2)
        self.accumulatedPCM.reserveCapacity(16_000 * 2 * 15)
    }

    func installTap(on inputNode: AVAudioInputNode) {
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
    }

    private func process(buffer: AVAudioPCMBuffer) {
        let inputFrames = buffer.frameLength
        guard inputFrames > 0 else { return }

        let ratio = outputFormat.sampleRate / max(1.0, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(max(64, Int(ceil(Double(inputFrames) * ratio)) + 32))
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        final class InputBox: @unchecked Sendable {
            var consumed = false
            let buffer: AVAudioPCMBuffer
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let box = InputBox(buffer)

        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if box.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            box.consumed = true
            outStatus.pointee = .haveData
            return box.buffer
        }
        guard status != .error, conversionError == nil else { return }

        let frameCount = Int(converted.frameLength)
        guard frameCount > 0, let int16Ptr = converted.int16ChannelData?[0] else { return }

        var sumSquares: Float = 0
        for i in 0..<frameCount {
            let sample = Float(int16Ptr[i]) / 32_768.0
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameCount))
        // Map typical speech RMS (~0.015 ... 0.25) into smooth 0...1 UI level
        let normalizedLevel = min(1.0, max(0.0, (rms - 0.008) * 5.5))

        let byteCount = frameCount * MemoryLayout<Int16>.size
        let rawBytes = Data(bytes: int16Ptr, count: byteCount)

        var readyChunks: [Data] = []
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        let remainingCap = maxAccumulatedBytes - accumulatedPCM.count
        if remainingCap > 0 {
            accumulatedPCM.append(rawBytes.prefix(remainingCap))
        }
        pendingChunk.append(rawBytes)
        while pendingChunk.count >= targetChunkBytes {
            let slice = Data(pendingChunk.prefix(targetChunkBytes))
            pendingChunk.removeFirst(targetChunkBytes)
            readyChunks.append(slice)
        }
        lock.unlock()

        for chunk in readyChunks {
            onChunk(chunk, normalizedLevel)
        }
    }

    func finishAndDrain() -> Data {
        var tailChunk: Data?
        let total: Data
        lock.lock()
        stopped = true
        if !pendingChunk.isEmpty {
            tailChunk = pendingChunk
            pendingChunk = Data()
        }
        total = accumulatedPCM
        lock.unlock()

        if let tailChunk {
            onChunk(tailChunk, 0)
        }
        return total
    }

    func discard() {
        lock.lock()
        stopped = true
        pendingChunk.removeAll(keepingCapacity: false)
        accumulatedPCM.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

/// Off-main-actor CoreAudio lifecycle coordinator so `AVAudioSession.setActive`
/// and `AVAudioEngine.start()` / `stop()` never stall `@MainActor` UI animations.
private final class AudioHardwareCoordinator: @unchecked Sendable {
    private enum Phase {
        case idle
        case starting(UInt64)
        case running(UInt64, AVAudioEngine, PCMTapProcessor)
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.sagewe.hapi.pcm-recorder", qos: .userInteractive)
    private var phase: Phase = .idle
    private var generation: UInt64 = 0

    func start(
        onChunk: @escaping @Sendable (Data, Float) -> Void,
        onError: (@Sendable (any Error) -> Void)?
    ) throws {
        lock.lock()
        switch phase {
        case .starting, .running:
            lock.unlock()
            throw PCMStreamingAudioRecorder.RecorderError.alreadyRecording
        case .idle:
            generation &+= 1
            let gen = generation
            phase = .starting(gen)
            lock.unlock()

            queue.async { [weak self] in
                self?.startOnQueue(generation: gen, onChunk: onChunk, onError: onError)
            }
        }
    }

    func stop() -> Data {
        lock.lock()
        let current = phase
        generation &+= 1
        phase = .idle
        lock.unlock()

        switch current {
        case .idle, .starting:
            return Data()
        case .running(_, let engine, let processor):
            let drained = processor.finishAndDrain()
            queue.async {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                Self.deactivateSession()
            }
            return drained
        }
    }

    func cancel() {
        lock.lock()
        let current = phase
        generation &+= 1
        phase = .idle
        lock.unlock()

        if case .running(_, let engine, let processor) = current {
            processor.discard()
            queue.async {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                Self.deactivateSession()
            }
        }
    }

    private func isStillStarting(generation gen: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .starting(let activeGen) = phase, activeGen == gen {
            return true
        }
        return false
    }

    private func startOnQueue(
        generation gen: UInt64,
        onChunk: @escaping @Sendable (Data, Float) -> Void,
        onError: (@Sendable (any Error) -> Void)?
    ) {
        guard isStillStarting(generation: gen) else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setPreferredSampleRate(16_000)
            try session.setPreferredIOBufferDuration(0.04)
            try session.setActive(true)

            guard isStillStarting(generation: gen) else {
                Self.deactivateSession()
                return
            }

            let audioEngine = AVAudioEngine()
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                Self.deactivateSession()
                throw PCMStreamingAudioRecorder.RecorderError.invalidInputFormat
            }

            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                Self.deactivateSession()
                throw PCMStreamingAudioRecorder.RecorderError.converterCreationFailed
            }

            let tapProcessor = PCMTapProcessor(
                inputFormat: inputFormat,
                outputFormat: targetFormat,
                converter: converter,
                onChunk: onChunk
            )
            tapProcessor.installTap(on: inputNode)

            do {
                audioEngine.prepare()
                try audioEngine.start()
            } catch {
                inputNode.removeTap(onBus: 0)
                tapProcessor.discard()
                Self.deactivateSession()
                throw error
            }

            lock.lock()
            if case .starting(let activeGen) = phase, activeGen == gen {
                phase = .running(gen, audioEngine, tapProcessor)
                lock.unlock()
            } else {
                lock.unlock()
                inputNode.removeTap(onBus: 0)
                audioEngine.stop()
                tapProcessor.discard()
                Self.deactivateSession()
            }
        } catch {
            lock.lock()
            let shouldNotify: Bool
            if case .starting(let activeGen) = phase, activeGen == gen {
                phase = .idle
                shouldNotify = true
            } else {
                shouldNotify = false
            }
            lock.unlock()
            if shouldNotify {
                onError?(error)
            }
        }
    }

    private static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

/// Real-time 16 kHz mono Int16 PCM capture over `AVAudioEngine` for iOS Hold-to-Dictate.
@MainActor
final class PCMStreamingAudioRecorder: HoldAudioCapturing {
    enum RecorderError: LocalizedError {
        case alreadyRecording
        case invalidInputFormat
        case converterCreationFailed

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "录音已在进行中"
            case .invalidInputFormat:
                return "无法读取麦克风音频格式"
            case .converterCreationFailed:
                return "无法初始化语音采样转换器"
            }
        }
    }

    private let hardware = AudioHardwareCoordinator()

    func start(onChunk: @escaping @Sendable (Data, Float) -> Void) throws {
        try hardware.start(onChunk: onChunk, onError: nil)
    }

    func start(
        onChunk: @escaping @Sendable (Data, Float) -> Void,
        onError: (@Sendable (any Error) -> Void)?
    ) throws {
        try hardware.start(onChunk: onChunk, onError: onError)
    }

    func stop() -> Data {
        hardware.stop()
    }

    func cancel() {
        hardware.cancel()
    }
}
#endif
