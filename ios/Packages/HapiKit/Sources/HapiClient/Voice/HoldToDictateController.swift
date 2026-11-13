import Foundation
import HapiProtocol
import Observation

/// Target action zone in the WeChat-style Hold-to-Dictate overlay.
public enum HoldActionZone: String, Equatable, Sendable {
    /// Default center / bottom dome: release sends the recognized text immediately (`松手 发送`).
    case send
    /// Left tilted pill: release discards the recording without sending (`松手 取消`).
    case cancel
    /// Right tilted pill: release opens the focused voice text editor (`松手 编辑`).
    case edit

    /// Resolves which action zone the user's thumb is currently targeting.
    public static func resolve(
        fingerX: Double,
        fingerY: Double,
        initialX: Double,
        initialY: Double,
        containerWidth: Double,
        containerHeight: Double
    ) -> HoldActionZone {
        guard containerWidth > 0, containerHeight > 0 else { return .send }

        // Keep initial touch-down anchored to `.send` until the thumb moves at
        // least 16pt (protects presses that started while a keyboard was dismissing).
        let dx = fingerX - initialX
        let dy = fingerY - initialY
        if (dx * dx + dy * dy) < (16.0 * 16.0) {
            return .send
        }

        // Bottom convex dome (`y >= H - 135`) always resolves to `.send`.
        let domeTopY = containerHeight - 135.0
        if fingerY >= domeTopY {
            return .send
        }

        if fingerX < containerWidth * 0.42 {
            return .cancel
        }
        if fingerX > containerWidth * 0.58 {
            return .edit
        }
        return .send
    }
}

/// UI state of the WeChat-style Hold-to-Dictate flow.
public enum HoldDictationPhase: Equatable, Sendable {
    case idle
    case holding(zone: HoldActionZone, partialText: String, audioLevel: Float)
    case finalizing(zone: HoldActionZone, partialText: String)

    public var isOverlayActive: Bool {
        switch self {
        case .idle:
            return false
        case .holding, .finalizing:
            return true
        }
    }
}

/// One-shot outcomes emitted by ``HoldToDictateController``.
public enum HoldDictationOutcome: Equatable, Sendable {
    /// Recognized text should be submitted immediately (`松手 发送`).
    case sendText(String)
    /// Right-slide release (`松开 编辑文字`): immediately expand & focus the main
    /// composer with the live streaming draft (`0ms`).
    case beginInlineEdit(partialText: String)
    /// Background `gpt-4o-transcribe` refinement completed for the active inline
    /// edit segment; replaces the segment if the user hasn't edited it yet.
    case refineInlineEdit(finalText: String)
    /// No provider configured on Hub.
    case noProvider
    /// Non-fatal user-facing error notice.
    case error(String)
}

/// Streaming 16 kHz mono Int16 PCM microphone seam.
@MainActor
public protocol HoldAudioCapturing: AnyObject {
    /// Starts capturing 16 kHz mono s16le PCM frames, invoking `onChunk` with
    /// ~100ms PCM chunks and normalized RMS audio level (`0...1`).
    func start(onChunk: @escaping @Sendable (Data, Float) -> Void) throws

    /// Starts capturing with an optional asynchronous hardware-startup error handler
    /// so `AVAudioSession` / `AVAudioEngine` warmup can run off `@MainActor` without
    /// delaying the overlay popup.
    func start(
        onChunk: @escaping @Sendable (Data, Float) -> Void,
        onError: (@Sendable (any Error) -> Void)?
    ) throws

    /// Stops capturing and returns the complete 16 kHz mono s16le PCM buffer.
    func stop() -> Data

    /// Immediately stops capturing and discards buffered audio.
    func cancel()
}

public extension HoldAudioCapturing {
    func start(
        onChunk: @escaping @Sendable (Data, Float) -> Void,
        onError: (@Sendable (any Error) -> Void)?
    ) throws {
        try start(onChunk: onChunk)
    }
}

/// Active WebSocket streaming ASR session handle.
public protocol HoldAsrStreamSession: Sendable {
    func sendAudioChunk(_ pcmData: Data) async
    /// Sends `{"type":"finish"}` and awaits the refined final transcript (or nil on failure/timeout).
    func finish() async -> String?
    func cancel() async
}

/// Factory seam for opening `WS /api/voice/asr-ws` streaming sessions.
public protocol HoldAsrStreaming: Sendable {
    func openSession(sampleRate: Int, context: VoiceRecognitionContext,
                     onPartial: @escaping @Sendable (String) -> Void) async throws -> any HoldAsrStreamSession
    func openSession(
        sampleRate: Int,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> any HoldAsrStreamSession
}

/// Wraps raw 16-bit little-endian mono PCM samples in a standard 44-byte RIFF WAV container.
public func encodePCM16MonoWAV(pcm: Data, sampleRate: Int = 16_000) -> Data {
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)
    let dataSize = UInt32(pcm.count)
    let chunkSize = 36 &+ dataSize

    var wav = Data(capacity: 44 + pcm.count)
    wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
    withUnsafeBytes(of: chunkSize.littleEndian) { wav.append(contentsOf: $0) }
    wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
    wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
    withUnsafeBytes(of: UInt32(16).littleEndian) { wav.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt16(1).littleEndian) { wav.append(contentsOf: $0) } // PCM = 1
    withUnsafeBytes(of: channels.littleEndian) { wav.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { wav.append(contentsOf: $0) }
    withUnsafeBytes(of: byteRate.littleEndian) { wav.append(contentsOf: $0) }
    withUnsafeBytes(of: blockAlign.littleEndian) { wav.append(contentsOf: $0) }
    withUnsafeBytes(of: bitsPerSample.littleEndian) { wav.append(contentsOf: $0) }
    wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
    withUnsafeBytes(of: dataSize.littleEndian) { wav.append(contentsOf: $0) }
    wav.append(pcm)
    return wav
}

/// Orchestrates WeChat-style Hold-to-Dictate on iOS:
/// - Streams live 16 kHz PCM over `WS /api/voice/asr-ws` for real-time partial transcripts
/// - Refines final transcript on release (`hybrid-qwen3` / `hybrid-openai`)
/// - Falls back seamlessly to `POST /api/voice/transcription` (`audio/wav`) if WebSocket fails
/// - Supports center release (`松手 发送`), left slide (`松手 取消`), and right slide (`松手 编辑`)
@MainActor @Observable
public final class HoldToDictateController {
    public static let defaultAudioLevels: [Float] = Array(repeating: 0.14, count: 22)

    public private(set) var phase: HoldDictationPhase = .idle
    public private(set) var audioLevels: [Float] = HoldToDictateController.defaultAudioLevels
    public private(set) var isRefiningEdit = false
    public private(set) var isAvailable = false

    @ObservationIgnored public var onOutcome: (@MainActor (HoldDictationOutcome) -> Void)?

    private let api: any DictationTranscribing
    private let streamer: (any HoldAsrStreaming)?
    private let recorder: any HoldAudioCapturing
    private let sampleRate: Int

    public var context = VoiceRecognitionContext()
    private var recordingContext = VoiceRecognitionContext()
    private var cachedProviderId: String?
    private var sessionGeneration: UInt64 = 0
    private var initialPoint: (x: Double, y: Double) = (0, 0)
    private var activeStreamTask: Task<Void, Never>?
    private var activeSession: (any HoldAsrStreamSession)?
    private var preOpenChunks: [Data] = []
    private var streamFailed = false

    public init(
        api: any DictationTranscribing,
        streamer: (any HoldAsrStreaming)?,
        recorder: any HoldAudioCapturing,
        sampleRate: Int = 16_000
    ) {
        self.api = api
        self.streamer = streamer
        self.recorder = recorder
        self.sampleRate = sampleRate
    }

    /// Silent preflight on chat entry.
    public func refreshAvailability() async {
        guard phase == .idle else { return }
        do {
            let providers = try await api.transcriptionProviders().providers
            guard !Task.isCancelled else { return }
            cachedProviderId = providers.first(where: { $0.modes.contains("standard") })?.id
            isAvailable = cachedProviderId != nil || streamer != nil
        } catch {
            // Keep existing availability if transient network hiccup occurs.
        }
    }

    /// Finger touched down on `可按住 转文字` (or long-pressed the mic icon).
    public func beginHold(
        fingerX: Double,
        fingerY: Double,
        containerWidth: Double,
        containerHeight: Double
    ) {
        guard phase == .idle else { return }
        recordingContext = VoiceRecognitionContext(sessionId: context.sessionId, draft: context.draft)
        sessionGeneration &+= 1
        let gen = sessionGeneration
        let recognitionContext = recordingContext
        initialPoint = (fingerX, fingerY)
        preOpenChunks.removeAll(keepingCapacity: true)
        activeSession = nil
        streamFailed = false

        // Enter `.holding` immediately (0ms visual overlay + haptic parity with MyDots)
        // before starting CoreAudio hardware.
        audioLevels = Self.defaultAudioLevels
        isRefiningEdit = false
        phase = .holding(zone: .send, partialText: "", audioLevel: 0)

        do {
            try recorder.start(
                onChunk: { [weak self] chunk, level in
                    Task { @MainActor [weak self] in
                        self?.handleCapturedChunk(chunk, level: level, generation: gen)
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionGeneration == gen else { return }
                        self.cancelActiveTake()
                        self.onOutcome?(.error(Self.errorMessage(error, fallback: "无法启动麦克风录音")))
                    }
                }
            )
        } catch {
            phase = .idle
            onOutcome?(.error(Self.errorMessage(error, fallback: "无法启动麦克风录音")))
            return
        }

        if let streamer {
            activeStreamTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.api.prepareRecognition(context: recognitionContext)
                    guard self.sessionGeneration == gen else { return }
                    let session = try await streamer.openSession(sampleRate: self.sampleRate, context: recognitionContext) { [weak self] partial in
                        Task { @MainActor [weak self] in
                            self?.applyPartial(partial, generation: gen)
                        }
                    }
                    guard self.sessionGeneration == gen else {
                        await session.cancel()
                        return
                    }
                    self.activeSession = session
                    let buffered = self.preOpenChunks
                    self.preOpenChunks.removeAll()
                    for chunk in buffered {
                        await session.sendAudioChunk(chunk)
                    }
                } catch {
                    guard self.sessionGeneration == gen else { return }
                    self.streamFailed = true
                    self.preOpenChunks.removeAll()
                }
            }
        } else {
            streamFailed = true
        }
    }

    /// Finger dragged while holding.
    public func updateFinger(
        fingerX: Double,
        fingerY: Double,
        containerWidth: Double,
        containerHeight: Double
    ) {
        guard case .holding(_, let partialText, let audioLevel) = phase else { return }
        let nextZone = HoldActionZone.resolve(
            fingerX: fingerX,
            fingerY: fingerY,
            initialX: initialPoint.x,
            initialY: initialPoint.y,
            containerWidth: containerWidth,
            containerHeight: containerHeight
        )
        phase = .holding(zone: nextZone, partialText: partialText, audioLevel: audioLevel)
    }

    /// Finger lifted at the end of the hold gesture.
    public func endHold() {
        let recognitionContext = recordingContext
        guard case .holding(let zone, let partialText, _) = phase else { return }
        let gen = sessionGeneration

        if zone == .cancel {
            cancelActiveTake()
            return
        }

        let pcmData = recorder.stop()
        // Minimum ~120ms of 16 kHz 16-bit mono PCM (3840 bytes) to avoid accidental taps.
        if pcmData.count < 3_200 && partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            teardownStream()
            phase = .idle
            onOutcome?(.error("说话时间太短"))
            return
        }

        let baselinePartial = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if zone == .edit {
            // Dismiss voice overlay immediately (0ms) and hand off to the main
            // morphing composer box, refining seamlessly in the background.
            isRefiningEdit = true
            phase = .idle
            onOutcome?(.beginInlineEdit(partialText: baselinePartial))
        } else {
            phase = .finalizing(zone: zone, partialText: partialText)
        }

        Task { [weak self] in
            guard let self else { return }
            let openTask = self.activeStreamTask
            self.activeStreamTask = nil
            await openTask?.value

            guard self.sessionGeneration == gen else { return }

            var resolvedText: String?
            if let session = self.activeSession, !self.streamFailed {
                let remaining = self.preOpenChunks
                self.preOpenChunks.removeAll()
                for chunk in remaining {
                    await session.sendAudioChunk(chunk)
                }
                self.activeSession = nil
                resolvedText = await session.finish()
            }

            guard self.sessionGeneration == gen else { return }

            let fallbackPartial: String = {
                if case .finalizing(_, let latestPartial) = self.phase {
                    return latestPartial
                }
                return baselinePartial
            }()

            if (resolvedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
               !pcmData.isEmpty {
                resolvedText = await self.transcribeFallbackWAV(pcmData: pcmData, context: recognitionContext)
            }

            guard self.sessionGeneration == gen else { return }
            self.isRefiningEdit = false

            let finalCandidate = (resolvedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? resolvedText!
                : fallbackPartial
            let cleaned = finalCandidate.trimmingCharacters(in: .whitespacesAndNewlines)

            switch zone {
            case .send:
                guard !cleaned.isEmpty else {
                    self.phase = .idle
                    self.onOutcome?(.error("未识别到语音内容"))
                    return
                }
                self.phase = .idle
                self.onOutcome?(.sendText(cleaned))
            case .edit:
                guard !cleaned.isEmpty else {
                    if baselinePartial.isEmpty {
                        self.onOutcome?(.error("未识别到语音内容"))
                    }
                    return
                }
                self.onOutcome?(.refineInlineEdit(finalText: cleaned))
            case .cancel:
                self.phase = .idle
            }
        }
    }

    /// Called if the system cancels the touch gesture (e.g. incoming call or notification shade).
    public func cancelIfHolding() {
        guard case .holding = phase else { return }
        cancelActiveTake()
    }

    /// Cancels everything (including finalizing or background inline refinement).
    public func dismissOverlay() {
        if case .holding = phase {
            cancelActiveTake()
            return
        }
        sessionGeneration &+= 1
        isRefiningEdit = false
        teardownStream()
        phase = .idle
    }

    /// Cancels any pending background refinement when the user sends or undoes the inline voice draft.
    public func clearInlineEditSession() {
        guard phase == .idle else { return }
        sessionGeneration &+= 1
        isRefiningEdit = false
        teardownStream()
    }

    // MARK: - Private

    private func handleCapturedChunk(_ chunk: Data, level: Float, generation: UInt64) {
        guard sessionGeneration == generation,
              case .holding(let zone, let partialText, _) = phase else { return }
        pushAudioLevel(level)
        phase = .holding(zone: zone, partialText: partialText, audioLevel: level)

        guard !streamFailed else { return }
        if let session = activeSession {
            Task {
                await session.sendAudioChunk(chunk)
            }
        } else if preOpenChunks.count < 1_800 {
            preOpenChunks.append(chunk)
        }
    }

    private func applyPartial(_ text: String, generation: UInt64) {
        guard sessionGeneration == generation else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch phase {
        case .holding(let zone, _, let level):
            phase = .holding(zone: zone, partialText: trimmed, audioLevel: level)
        case .finalizing(let zone, _):
            phase = .finalizing(zone: zone, partialText: trimmed)
        case .idle:
            break
        }
    }

    private func pushAudioLevel(_ next: Float) {
        var copy = audioLevels
        if !copy.isEmpty {
            copy.removeFirst()
        }
        copy.append(min(max(next, 0.10), 1.0))
        audioLevels = copy
    }

    private func cancelActiveTake() {
        sessionGeneration &+= 1
        isRefiningEdit = false
        recorder.cancel()
        teardownStream()
        phase = .idle
    }

    private func teardownStream() {
        activeStreamTask?.cancel()
        activeStreamTask = nil
        preOpenChunks.removeAll()
        if let session = activeSession {
            activeSession = nil
            Task {
                await session.cancel()
            }
        }
    }

    private func transcribeFallbackWAV(pcmData: Data, context: VoiceRecognitionContext) async -> String? {
        var provider = cachedProviderId
        if provider == nil {
            provider = try? await api.transcriptionProviders()
                .providers
                .first(where: { $0.modes.contains("standard") })?
                .id
            cachedProviderId = provider
        }
        guard let provider else {
            onOutcome?(.noProvider)
            return nil
        }
        let wav = encodePCM16MonoWAV(pcm: pcmData, sampleRate: sampleRate)
        do {
            let res = try await api.transcribe(
                audio: wav,
                filename: "speech.wav",
                mimeType: "audio/wav",
                provider: provider,
                language: nil,
                context: context
            )
            return res.text
        } catch {
            return nil
        }
    }

    private static func errorMessage(_ error: any Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }
}
