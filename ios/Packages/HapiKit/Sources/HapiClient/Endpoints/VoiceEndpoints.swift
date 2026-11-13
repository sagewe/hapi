import Foundation
import HapiProtocol

/// Voice transcription (`docs/api/client-contract/rest.md`), added for A-M3f
/// dictation — mirrors the Android `HapiApi` voice methods.
extension APIClient {
    /// `GET /api/voice/transcription/providers` — providers whose keys are
    /// configured on the hub. Dictation picks the first entry supporting
    /// `standard`; an empty list means no transcription provider is
    /// configured.
    public func transcriptionProviders() async throws -> TranscriptionProvidersResponse {
        try await request(.get, "/api/voice/transcription/providers")
    }

    /// `GET /api/voice/asr-config` — checks whether Home Model Gateway
    /// streaming ASR (`WS /api/voice/asr-ws`) is configured on the hub.
    public func voiceAsrConfig() async throws -> VoiceAsrConfigResponse {
        try await request(.get, "/api/voice/asr-config")
    }

    /// Builds `wss://.../api/voice/asr-ws?sample_rate=...` from `baseURL`
    /// so TLS is preserved behind reverse proxies / `tunwg` relays.
    public func voiceAsrWebSocketURL(sampleRate: Int = 16_000, model: String? = nil, context: VoiceRecognitionContext? = nil) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = (components.scheme?.lowercased() == "https") ? "wss" : "ws"
        let trimmedBasePath = components.path.replacingOccurrences(
            of: #"/+$"#,
            with: "",
            options: .regularExpression
        )
        components.path = "\(trimmedBasePath)/api/voice/asr-ws"
        var items = [URLQueryItem(name: "sample_rate", value: String(sampleRate))]
        if let model, !model.isEmpty {
            items.append(URLQueryItem(name: "model", value: model))
        }
        if let context {
            if let sessionId = context.sessionId { items.append(URLQueryItem(name: "sessionId", value: sessionId)) }
            items.append(URLQueryItem(name: "recordingId", value: context.recordingId))
        }
        components.queryItems = items
        return components.url
    }

    /// `POST /api/voice/transcription` — the one `multipart/form-data`
    /// endpoint: `file` (≤ 25 MB audio), `provider`, `mode`, optional
    /// `language` (BCP-47-ish). Field order mirrors the Android client
    /// (file, provider, mode, language).
    public func transcribeVoice(
        audio: Data,
        filename: String,
        mimeType: String,
        provider: String,
        mode: String = "standard",
        language: String? = nil,
        context: VoiceRecognitionContext? = nil
    ) async throws -> TranscriptionResponse {
        var form = MultipartFormData()
        form.appendFile(fieldName: "file", filename: filename, mimeType: mimeType, data: audio)
        form.appendField(name: "provider", value: provider)
        form.appendField(name: "mode", value: mode)
        if let context {
            if let sessionId = context.sessionId { form.appendField(name: "sessionId", value: sessionId) }
            form.appendField(name: "draft", value: context.draft)
            form.appendField(name: "recordingId", value: context.recordingId)
        }
        if let language {
            form.appendField(name: "language", value: language)
        }
        return try await request(
            .post,
            "/api/voice/transcription",
            rawBody: form.encodedBody(),
            contentType: form.contentType
        )
    }
}

/// `DictationController` transport seam (the Android `HapiDictationApi`
/// adapter collapses to a conformance here).
extension APIClient: DictationTranscribing {
    public func transcribe(
        audio: Data,
        filename: String,
        mimeType: String,
        provider: String,
        language: String?
    ) async throws -> TranscriptionResponse {
        try await transcribeVoice(
            audio: audio,
            filename: filename,
            mimeType: mimeType,
            provider: provider,
            mode: "standard",
            language: language
        )
    }
}

extension APIClient {
    public func transcribe(audio: Data, filename: String, mimeType: String, provider: String,
                           language: String?, context: VoiceRecognitionContext) async throws -> TranscriptionResponse {
        try await transcribeVoice(audio: audio, filename: filename, mimeType: mimeType,
                                   provider: provider, language: language, context: context)
    }
}

extension APIClient {
    public func prepareRecognition(context: VoiceRecognitionContext) async throws {
        guard context.sessionId != nil else { return }
        struct Body: Encodable { let sessionId: String?; let draft: String; let recordingId: String }
        struct Result: Decodable { let ok: Bool }
        let _: Result = try await request(.post, "/api/voice/asr-context",
            body: Body(sessionId: context.sessionId, draft: context.draft, recordingId: context.recordingId))
    }
}
