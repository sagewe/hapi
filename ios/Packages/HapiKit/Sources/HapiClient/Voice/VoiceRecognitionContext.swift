import Foundation
import HapiProtocol

/// Frozen at recording start, reused for streaming and uploaded-audio fallback.
public struct VoiceRecognitionContext: Sendable {
    public var sessionId: String?
    public var draft: String
    public var recordingId: String
    public init(sessionId: String? = nil, draft: String = "", recordingId: String = UUID().uuidString) {
        self.sessionId = sessionId
        self.draft = String(draft.prefix(2000))
        self.recordingId = recordingId
    }
}

public extension DictationTranscribing {
    func prepareRecognition(context: VoiceRecognitionContext) async throws {}
    func transcribe(audio: Data, filename: String, mimeType: String, provider: String,
                    language: String?, context: VoiceRecognitionContext) async throws -> TranscriptionResponse {
        try await transcribe(audio: audio, filename: filename, mimeType: mimeType,
                             provider: provider, language: language)
    }
}

public extension HoldAsrStreaming {
    func openSession(sampleRate: Int, context: VoiceRecognitionContext,
                     onPartial: @escaping @Sendable (String) -> Void) async throws -> any HoldAsrStreamSession {
        try await openSession(sampleRate: sampleRate, onPartial: onPartial)
    }
}
