#if canImport(Darwin)
import Foundation
import HapiProtocol

/// Native `URLSessionWebSocketTask` client for `WS /api/voice/asr-ws`.
public final class HubStreamingAsrClient: HoldAsrStreaming, Sendable {
    private let api: APIClient
    private let model: String?

    public init(api: APIClient, model: String? = nil) {
        self.api = api
        self.model = model
    }

    public func openSession(
        sampleRate: Int,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> any HoldAsrStreamSession {
        guard let wsURL = api.voiceAsrWebSocketURL(sampleRate: sampleRate, model: model) else {
            throw APIError(status: 400, code: "invalid_asr_ws_url")
        }
        let token = try await api.authManager.validToken()
        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45

        let task = URLSession.shared.webSocketTask(with: request)
        let session = WebSocketAsrStreamSession(task: task, onPartial: onPartial)
        await session.start()
        return session
    }
}

actor WebSocketAsrStreamSession: HoldAsrStreamSession {
    private let task: URLSessionWebSocketTask
    private let onPartial: @Sendable (String) -> Void
    private var receiveLoopTask: Task<Void, Never>?
    private var latestPartial: String = ""
    private var finalResult: String?
    private var sentPCMBytes: Int = 0
    private var finished = false
    private var closed = false
    private var finishContinuation: CheckedContinuation<String?, Never>?

    init(task: URLSessionWebSocketTask, onPartial: @escaping @Sendable (String) -> Void) {
        self.task = task
        self.onPartial = onPartial
    }

    func start() {
        task.resume()
        receiveLoopTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    func sendAudioChunk(_ pcmData: Data) async {
        guard !closed, !finished, !pcmData.isEmpty else { return }
        sentPCMBytes += pcmData.count
        try? await task.send(.data(pcmData))
    }

    func finish() async -> String? {
        if let finalResult {
            return finalResult
        }
        if closed {
            return latestPartial.isEmpty ? nil : latestPartial
        }
        finished = true
        do {
            try await task.send(.string(#"{"type":"finish"}"#))
        } catch {
            closeSocket()
            return latestPartial.isEmpty ? nil : latestPartial
        }

        if let finalResult {
            closeSocket()
            return finalResult
        }

        let audioSecs = Double(sentPCMBytes) / 32_000.0
        let timeoutNs = min(
            max(6_500_000_000, UInt64((5.0 + audioSecs * 0.40) * 1_000_000_000)),
            22_000_000_000
        )

        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                return await self.awaitFinalContinuation()
            }
            group.addTask { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNs)
                await self?.resumeContinuationOnTimeout()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        closeSocket()
        if let result, !result.isEmpty {
            return result
        }
        return latestPartial.isEmpty ? nil : latestPartial
    }

    func cancel() async {
        closed = true
        finished = true
        resumeFinish(with: nil)
        closeSocket()
    }

    // MARK: - Internal receive loop

    private func awaitFinalContinuation() async -> String? {
        if let finalResult {
            return finalResult
        }
        if closed {
            return latestPartial.isEmpty ? nil : latestPartial
        }
        return await withCheckedContinuation { continuation in
            self.finishContinuation = continuation
        }
    }

    private func resumeContinuationOnTimeout() {
        guard finishContinuation != nil else { return }
        let fallback = latestPartial.isEmpty ? nil : latestPartial
        resumeFinish(with: fallback)
    }

    private func resumeFinish(with text: String?) {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        continuation.resume(returning: text)
    }

    private func closeSocket() {
        closed = true
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func runReceiveLoop() async {
        while !Task.isCancelled && !closed {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                closed = true
                resumeFinish(with: latestPartial.isEmpty ? nil : latestPartial)
                return
            }

            let rawData: Data?
            switch message {
            case .string(let text):
                rawData = Data(text.utf8)
            case .data(let data):
                rawData = data
            @unknown default:
                rawData = nil
            }

            guard let rawData,
                  let event = try? HapiJSON.decoder.decode(VoiceAsrStreamEvent.self, from: rawData) else {
                continue
            }

            switch event.type {
            case "partial":
                if let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    latestPartial = text
                    onPartial(text)
                }
            case "final":
                let text = (event.text ?? latestPartial).trimmingCharacters(in: .whitespacesAndNewlines)
                finalResult = text
                resumeFinish(with: text.isEmpty ? nil : text)
                return
            case "error":
                closed = true
                resumeFinish(with: latestPartial.isEmpty ? nil : latestPartial)
                return
            default:
                break
            }
        }
    }
}
#endif
