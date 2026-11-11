import Foundation

// Wire types of the hub's voice surface (`hub/src/web/routes/voice.ts`),
// added for A-M3f dictation in lockstep with the Android port
// (`app.hapi.protocol.wire` — ApiResponses.kt). Only the standard
// (uploaded-file) transcription path is modeled; realtime tokens are out of
// scope for native v1.

/// Body of `POST /api/voice/transcription` (the one multipart endpoint).
public struct TranscriptionResponse: Codable, Equatable, Sendable {
    public var text: String
    public var language: String?

    public init(text: String, language: String? = nil) {
        self.text = text
        self.language = language
    }
}

/// Body of `GET /api/voice/transcription/providers` — only providers whose
/// keys are configured on the hub (`listConfiguredTranscriptionProviders`,
/// `shared/src/voice.ts`). Empty ⇒ dictation is unavailable.
public struct TranscriptionProvidersResponse: Codable, Equatable, Sendable {
    public var providers: [TranscriptionProviderInfo]

    public init(providers: [TranscriptionProviderInfo]) {
        self.providers = providers
    }
}

/// `TranscriptionProviderInfo` (`shared/src/voice.ts`).
public struct TranscriptionProviderInfo: Codable, Equatable, Sendable {
    /// `openai | elevenlabs | deepgram | groq | openai-compatible | browser-local`.
    public var id: String
    public var label: String
    /// Subset of `standard` / `realtime`; native dictation uses `standard`.
    public var modes: [String]

    public init(id: String, label: String, modes: [String]) {
        self.id = id
        self.label = label
        self.modes = modes
    }
}

/// Body of `GET /api/voice/asr-config` — streaming ASR capability backed by
/// Home Model Gateway (`WS /api/voice/asr-ws`).
public struct VoiceAsrConfigResponse: Codable, Equatable, Sendable {
    public var available: Bool
    public var wsUrl: String?
    public var sampleRate: Int?
    public var model: String?

    public init(
        available: Bool,
        wsUrl: String? = nil,
        sampleRate: Int? = nil,
        model: String? = nil
    ) {
        self.available = available
        self.wsUrl = wsUrl
        self.sampleRate = sampleRate
        self.model = model
    }
}

/// Server-to-client JSON frame over `WS /api/voice/asr-ws`.
public struct VoiceAsrStreamEvent: Codable, Equatable, Sendable {
    /// `ready | partial | final | error`
    public var type: String
    public var text: String?
    public var rawText: String?
    public var sentenceEnd: Bool?
    public var model: String?
    public var message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case rawText = "raw_text"
        case sentenceEnd = "sentence_end"
        case model
        case message
    }

    public init(
        type: String,
        text: String? = nil,
        rawText: String? = nil,
        sentenceEnd: Bool? = nil,
        model: String? = nil,
        message: String? = nil
    ) {
        self.type = type
        self.text = text
        self.rawText = rawText
        self.sentenceEnd = sentenceEnd
        self.model = model
        self.message = message
    }
}
