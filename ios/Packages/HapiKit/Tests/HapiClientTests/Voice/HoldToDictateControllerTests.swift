import Foundation
import HapiClient
import HapiProtocol
import Testing

private struct HoldTestError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private actor FakeHoldDictationApi: DictationTranscribing {
    struct Call: Sendable {
        let audio: Data
        let filename: String
        let mimeType: String
        let provider: String
    }

    var providers = [
        TranscriptionProviderInfo(id: "openai-compatible", label: "Home Model Gateway", modes: ["standard"])
    ]
    var responseText = "家庭网关兜底文本"
    private(set) var calls: [Call] = []

    func transcriptionProviders() async throws -> TranscriptionProvidersResponse {
        TranscriptionProvidersResponse(providers: providers)
    }

    func transcribe(
        audio: Data,
        filename: String,
        mimeType: String,
        provider: String,
        language: String?
    ) async throws -> TranscriptionResponse {
        calls.append(Call(audio: audio, filename: filename, mimeType: mimeType, provider: provider))
        return TranscriptionResponse(text: responseText)
    }
}

private actor FakeHoldStreamSession: HoldAsrStreamSession {
    private(set) var chunks: [Data] = []
    private(set) var finishCalled = false
    private(set) var cancelCalled = false
    var finalText: String?

    init(finalText: String?) {
        self.finalText = finalText
    }

    func sendAudioChunk(_ pcmData: Data) async {
        chunks.append(pcmData)
    }

    func finish() async -> String? {
        finishCalled = true
        return finalText
    }

    func cancel() async {
        cancelCalled = true
    }
}

private actor FakeHoldStreamer: HoldAsrStreaming {
    var shouldFailOpen = false
    var finalText: String? = "这是一个测试"
    private(set) var lastSession: FakeHoldStreamSession?
    private var partialHandler: (@Sendable (String) -> Void)?

    func setShouldFailOpen(_ fail: Bool) {
        shouldFailOpen = fail
    }

    func emitPartial(_ text: String) {
        partialHandler?(text)
    }

    func openSession(
        sampleRate: Int,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> any HoldAsrStreamSession {
        if shouldFailOpen {
            throw HoldTestError(message: "WebSocket unavailable")
        }
        partialHandler = onPartial
        let session = FakeHoldStreamSession(finalText: finalText)
        lastSession = session
        return session
    }
}

@MainActor
private final class FakeHoldRecorder: HoldAudioCapturing {
    var stopPCM = Data(repeating: 0x10, count: 6_400)
    private var onChunk: (@Sendable (Data, Float) -> Void)?
    private var onError: (@Sendable (any Error) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0

    func start(onChunk: @escaping @Sendable (Data, Float) -> Void) throws {
        startCount += 1
        self.onChunk = onChunk
    }

    func start(
        onChunk: @escaping @Sendable (Data, Float) -> Void,
        onError: (@Sendable (any Error) -> Void)?
    ) throws {
        startCount += 1
        self.onChunk = onChunk
        self.onError = onError
    }

    func pushChunk(_ data: Data, level: Float = 0.45) {
        onChunk?(data, level)
    }

    func triggerAsyncError(_ error: any Error) {
        onError?(error)
    }

    func stop() -> Data {
        stopCount += 1
        return stopPCM
    }

    func cancel() {
        cancelCount += 1
    }
}

@Suite("HoldToDictateController")
struct HoldToDictateControllerTests {
    @Test("HoldActionZone resolves send, cancel, and edit targets accurately")
    func zoneGeometry() {
        let width = 393.0
        let height = 852.0
        // Initial touch down stays `.send` even if started higher on screen
        #expect(HoldActionZone.resolve(
            fingerX: 340, fingerY: 500,
            initialX: 340, initialY: 500,
            containerWidth: width, containerHeight: height
        ) == .send)

        // Sliding up-left into cancel pill -> `.cancel`
        #expect(HoldActionZone.resolve(
            fingerX: 90, fingerY: 650,
            initialX: 196, initialY: 790,
            containerWidth: width, containerHeight: height
        ) == .cancel)

        // Sliding up-right into edit pill -> `.edit`
        #expect(HoldActionZone.resolve(
            fingerX: 300, fingerY: 650,
            initialX: 196, initialY: 790,
            containerWidth: width, containerHeight: height
        ) == .edit)

        // Sliding back down onto bottom convex dome -> `.send`
        #expect(HoldActionZone.resolve(
            fingerX: 90, fingerY: 760,
            initialX: 196, initialY: 790,
            containerWidth: width, containerHeight: height
        ) == .send)
    }

    @Test("Center release streams partials and emits sendText with refined final transcript")
    @MainActor
    func holdAndReleaseSend() async throws {
        let api = FakeHoldDictationApi()
        let streamer = FakeHoldStreamer()
        let recorder = FakeHoldRecorder()
        let controller = HoldToDictateController(api: api, streamer: streamer, recorder: recorder)

        var outcomes: [HoldDictationOutcome] = []
        controller.onOutcome = { outcomes.append($0) }

        await controller.refreshAvailability()
        #expect(controller.isAvailable)

        controller.beginHold(fingerX: 196, fingerY: 790, containerWidth: 393, containerHeight: 852)
        #expect(controller.audioLevels.count == 22)
        recorder.pushChunk(Data(repeating: 0x01, count: 3_200), level: 0.6)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(controller.audioLevels.count == 22)
        #expect(abs((controller.audioLevels.last ?? 0) - 0.6) < 0.001)

        await streamer.emitPartial("这是一")
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(controller.phase == .holding(zone: .send, partialText: "这是一", audioLevel: 0.6))

        controller.endHold()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(controller.phase == .idle)
        #expect(outcomes == [.sendText("这是一个测试")])
    }

    @Test("Sliding right to edit immediately hands off draft to main composer and emits background refinement")
    @MainActor
    func holdSlideEditHandsOffToMainComposerAndRefines() async throws {
        let api = FakeHoldDictationApi()
        let streamer = FakeHoldStreamer()
        let recorder = FakeHoldRecorder()
        let controller = HoldToDictateController(api: api, streamer: streamer, recorder: recorder)

        var outcomes: [HoldDictationOutcome] = []
        controller.onOutcome = { outcomes.append($0) }

        controller.beginHold(fingerX: 196, fingerY: 790, containerWidth: 393, containerHeight: 852)
        try await Task.sleep(nanoseconds: 20_000_000)
        await streamer.emitPartial("这是一个测")
        try await Task.sleep(nanoseconds: 20_000_000)

        controller.updateFinger(fingerX: 310, fingerY: 640, containerWidth: 393, containerHeight: 852)
        #expect(controller.phase == .holding(zone: .edit, partialText: "这是一个测", audioLevel: 0))

        controller.endHold()
        // Dismisses voice overlay synchronously at 0ms and hands off streaming draft to main composer
        #expect(controller.phase == .idle)
        #expect(controller.isRefiningEdit == true)
        #expect(outcomes == [.beginInlineEdit(partialText: "这是一个测")])

        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(controller.isRefiningEdit == false)
        #expect(outcomes == [
            .beginInlineEdit(partialText: "这是一个测"),
            .refineInlineEdit(finalText: "这是一个测试")
        ])
    }

    @Test("Sliding left to cancel discards audio without sending")
    @MainActor
    func holdSlideCancel() async throws {
        let api = FakeHoldDictationApi()
        let streamer = FakeHoldStreamer()
        let recorder = FakeHoldRecorder()
        let controller = HoldToDictateController(api: api, streamer: streamer, recorder: recorder)

        var outcomes: [HoldDictationOutcome] = []
        controller.onOutcome = { outcomes.append($0) }

        controller.beginHold(fingerX: 196, fingerY: 790, containerWidth: 393, containerHeight: 852)
        try await Task.sleep(nanoseconds: 20_000_000)
        controller.updateFinger(fingerX: 80, fingerY: 640, containerWidth: 393, containerHeight: 852)
        controller.endHold()
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(controller.phase == .idle)
        #expect(recorder.cancelCount == 1)
        #expect(outcomes.isEmpty)
        let session = await streamer.lastSession
        #expect(await session?.cancelCalled == true)
    }

    @Test("Falls back to WAV multipart transcription if WebSocket stream fails")
    @MainActor
    func fallbackToWAVUploadWhenStreamFails() async throws {
        let api = FakeHoldDictationApi()
        let streamer = FakeHoldStreamer()
        await streamer.setShouldFailOpen(true)
        let recorder = FakeHoldRecorder()
        let controller = HoldToDictateController(api: api, streamer: streamer, recorder: recorder)

        var outcomes: [HoldDictationOutcome] = []
        controller.onOutcome = { outcomes.append($0) }

        controller.beginHold(fingerX: 196, fingerY: 790, containerWidth: 393, containerHeight: 852)
        try await Task.sleep(nanoseconds: 30_000_000)
        controller.endHold()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(controller.phase == .idle)
        #expect(outcomes == [.sendText("家庭网关兜底文本")])
        let calls = await api.calls
        #expect(calls.count == 1)
        #expect(calls.first?.mimeType == "audio/wav")
        #expect(calls.first?.audio.prefix(4) == Data([0x52, 0x49, 0x46, 0x46])) // "RIFF"
    }

    @Test("beginHold enters holding immediately and handles async audio hardware error cleanly")
    @MainActor
    func asyncHardwareErrorCancelsHoldingCleanly() async throws {
        let api = FakeHoldDictationApi()
        let streamer = FakeHoldStreamer()
        let recorder = FakeHoldRecorder()
        let controller = HoldToDictateController(api: api, streamer: streamer, recorder: recorder)

        var outcomes: [HoldDictationOutcome] = []
        controller.onOutcome = { outcomes.append($0) }

        controller.beginHold(fingerX: 196, fingerY: 790, containerWidth: 393, containerHeight: 852)
        // Must enter `.holding` synchronously at 0ms before async tasks settle
        #expect(controller.phase == .holding(zone: .send, partialText: "", audioLevel: 0))

        recorder.triggerAsyncError(HoldTestError(message: "麦克风硬件占用"))
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(controller.phase == .idle)
        #expect(recorder.cancelCount == 1)
        #expect(outcomes == [.error("麦克风硬件占用")])
    }
}
