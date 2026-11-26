package app.hapi.protocol.wire

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonNames
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/**
 * Paging envelope of `GET /v1/sessions/:id/messages` (`MessagesResponse.page`
 * in `shared/src/apiTypes.ts`; semantics in
 * `docs/api/client-contract/pagination.md`). Every cursor is a `(seq, at)`
 * pair — both halves always travel together.
 */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class MessagesPage(
    /** `'latest' | 'before' | 'after'`. */
    val direction: String,
    val limit: Int,
    /** Server's current epoch; mismatch on `after` ⇒ [reset] latest page. */
    val epoch: Long,
    /** `true` ⇒ discard the local window, this page replaces it. */
    val reset: Boolean,
    @JsonNames("next_before_seq")
    val nextBeforeSeq: Long? = null,
    @JsonNames("next_before_at")
    val nextBeforeAt: Long? = null,
    @JsonNames("next_after_seq")
    val nextAfterSeq: Long? = null,
    @JsonNames("next_after_at")
    val nextAfterAt: Long? = null,
    @JsonNames("snapshot_head_seq")
    val snapshotHeadSeq: Long? = null,
    @JsonNames("snapshot_head_at")
    val snapshotHeadAt: Long? = null,
    @JsonNames("has_more")
    val hasMore: Boolean,
    @JsonNames("read_through_revision")
    val readThroughRevision: Long? = null,
    @JsonNames("content_revision")
    val contentRevision: Long? = null,
)
/** `GET /v1/sessions/:id/messages` — messages in ascending display order. */
@Serializable
data class MessagesResponse(
    val messages: List<DecryptedMessage>,
    val page: MessagesPage,
)

/**
 * Cursor block of `GET /v1/sessions/:id/messages/:messageId/context`
 * (`MessageContextResponse['page']` in `shared/src/apiTypes.ts`): the bounded
 * context window carries no direction/limit/reset keys.
 */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class MessageContextPage(
    val epoch: Long,
    @JsonNames("next_before_seq")
    val nextBeforeSeq: Long? = null,
    @JsonNames("next_before_at")
    val nextBeforeAt: Long? = null,
    @JsonNames("snapshot_head_seq")
    val snapshotHeadSeq: Long? = null,
    @JsonNames("snapshot_head_at")
    val snapshotHeadAt: Long? = null,
    @JsonNames("has_more")
    val hasMore: Boolean,
)

/**
 * `GET /v1/sessions/:id/messages/:messageId/context` — a bounded history
 * window centered on one message. The hub answers a bare JSON `null` when the
 * message does not resolve (web `MessageContextResponse | null`).
 */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class MessageContextResponse(
    val messages: List<DecryptedMessage>,
    @JsonNames("target_message_id")
    val targetMessageId: String,
    val page: MessageContextPage,
)

/** `GET /v1/sessions`. */
@Serializable
data class SessionsResponse(
    val sessions: List<SessionSummary>,
)

/** `GET /v1/sessions/:id`. */
@Serializable
data class SessionResponse(
    val session: Session,
)

/** `GET /v1/machines`. */
@Serializable
data class MachinesResponse(
    val machines: List<Machine>,
)

/** `POST /v1/machines/:id/restart-runner` — hub ack (`{message}`). */
@Serializable
data class RestartRunnerResponse(
    val message: String,
)

/** `POST /v1/auth/login` success body (Reins v1 `{token, namespace, is_owner}` or legacy `{token, user}`). */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class AuthResponse(
    /** The JWT — `Authorization: Bearer` on every `/v1` request. */
    val token: String,
    val namespace: String? = null,
    @JsonNames("is_owner")
    val isOwner: Boolean? = null,
    val user: AuthUser? = null,
)

@Serializable
data class AuthUser(
    val id: Long,
    val username: String? = null,
    val firstName: String? = null,
    val lastName: String? = null,
)

/**
 * `GET /health` (no auth; `hub/src/web/server.ts`). [capabilities] keys are
 * additive — unknown ones must be ignored, hence the raw-`Boolean?` shape.
 */
@Serializable
data class HubHealthResponse(
    val status: String,
    val protocolVersion: Int,
    val capabilities: HubCapabilities? = null,
)

@Serializable
data class HubCapabilities(
    val workGraph: Boolean? = null,
    val titleSuggestion: Boolean? = null,
)

/**
 * `POST /v1/sessions/:id/resume` — `{ok: true, session: {id, ...}}` (Reins v1)
 * or `{sessionId}` (legacy). The returned [sessionId] **may differ** from the id
 * the call was made on (fresh spawn superseding the old row); callers must
 * migrate drafts + navigation.
 */
@Serializable(with = ResumeSessionResponseSerializer::class)
data class ResumeSessionResponse(
    val sessionId: String,
)

internal object ResumeSessionResponseSerializer : KSerializer<ResumeSessionResponse> {
    override val descriptor: SerialDescriptor =
        SerialDescriptor("app.hapi.protocol.wire.ResumeSessionResponse", JsonObject.serializer().descriptor)

    override fun deserialize(decoder: Decoder): ResumeSessionResponse {
        val input = decoder as? JsonDecoder
            ?: throw SerializationException("ResumeSessionResponse supports JSON only")
        val obj = input.decodeJsonElement() as? JsonObject
            ?: throw SerializationException("ResumeSessionResponse must be a JSON object")
        val sessionId = obj["sessionId"].stringOrNull
            ?: obj["session_id"].stringOrNull
            ?: (obj["session"] as? JsonObject)?.get("id").stringOrNull
            ?: throw SerializationException("ResumeSessionResponse missing sessionId or session.id")
        return ResumeSessionResponse(sessionId = sessionId)
    }

    override fun serialize(encoder: Encoder, value: ResumeSessionResponse) {
        val output = encoder as? JsonEncoder
            ?: throw SerializationException("ResumeSessionResponse supports JSON only")
        output.encodeJsonElement(buildJsonObject { put("sessionId", JsonPrimitive(value.sessionId)) })
    }
}

/**
 * `POST /v1/sessions/:id/resume` (reopen path) — decodes both Reins v1
 * `{ok: true, session: {id, ...}}` and legacy `{ok, sessionId, resumed}`.
 */
@Serializable(with = ReopenSessionResponseSerializer::class)
data class ReopenSessionResponse(
    val ok: Boolean = true,
    val sessionId: String,
    val resumed: Boolean,
    /** `'acp' | 'stream-json'` (cursor only). */
    val cursorSessionProtocol: String? = null,
)

internal object ReopenSessionResponseSerializer : KSerializer<ReopenSessionResponse> {
    override val descriptor: SerialDescriptor =
        SerialDescriptor("app.hapi.protocol.wire.ReopenSessionResponse", JsonObject.serializer().descriptor)

    override fun deserialize(decoder: Decoder): ReopenSessionResponse {
        val input = decoder as? JsonDecoder
            ?: throw SerializationException("ReopenSessionResponse supports JSON only")
        val obj = input.decodeJsonElement() as? JsonObject
            ?: throw SerializationException("ReopenSessionResponse must be a JSON object")
        val sessionObj = obj["session"] as? JsonObject
        val sessionId = obj["sessionId"].stringOrNull
            ?: obj["session_id"].stringOrNull
            ?: sessionObj?.get("id").stringOrNull
            ?: throw SerializationException("ReopenSessionResponse missing sessionId or session.id")
        val ok = obj["ok"].boolOrNull ?: true
        val resumed = obj["resumed"].boolOrNull ?: (sessionObj != null)
        return ReopenSessionResponse(
            ok = ok,
            sessionId = sessionId,
            resumed = resumed,
            cursorSessionProtocol = obj["cursorSessionProtocol"].stringOrNull,
        )
    }

    override fun serialize(encoder: Encoder, value: ReopenSessionResponse) {
        val output = encoder as? JsonEncoder
            ?: throw SerializationException("ReopenSessionResponse supports JSON only")
        output.encodeJsonElement(buildJsonObject {
            put("ok", JsonPrimitive(value.ok))
            put("sessionId", JsonPrimitive(value.sessionId))
            put("resumed", JsonPrimitive(value.resumed))
            value.cursorSessionProtocol?.let { put("cursorSessionProtocol", JsonPrimitive(it)) }
        })
    }
}

/**
 * `DELETE /api/sessions/:id/messages/:messageId`
 * (`CancelMessageResponseSchema` — discriminated on [status]):
 * `'cancelled'` carries [localId]; `'invoked'` (too late) carries [message].
 */
@Serializable
data class CancelMessageResponse(
    val status: String,
    val localId: String? = null,
    val message: DecryptedMessage? = null,
)

@Serializable
data class RetryIndeterminateMessageResponse(
    val status: String,
    val localId: String? = null,
    val message: DecryptedMessage? = null,
)

/**
 * `POST /api/sessions/:id/messages/:messageId/steer`
 * (`SteerQueuedMessageResponseSchema` — discriminated on [status]):
 * `'steered'` → [localId]; `'invoked'` → [message]; `'failed'` → [error] + [localId].
 */
@Serializable
data class SteerQueuedMessageResponse(
    val status: String,
    val localId: String? = null,
    val message: DecryptedMessage? = null,
    val error: String? = null,
)

/**
 * `POST /api/sessions/:id/messages/queued-state` — resyncs optimistic sends
 * after reconnect (`QueuedStateResponse`, `shared/src/apiTypes.ts`).
 */
@Serializable
data class QueuedStateResponse(
    val queuedLocalIds: List<String>,
    val invokedLocalMessages: List<InvokedLocalMessage>,
    val indeterminateLocalIds: List<String> = emptyList(),
)

@Serializable
data class InvokedLocalMessage(
    val localId: String,
    val invokedAt: Long,
)

/**
 * `POST /v1/sessions` (Reins v1 `{session: {id, ...}}`) or legacy
 * `POST /v1/machines/:id/spawn` (`{type: 'success'|'error', sessionId, message}`).
 */
@Serializable(with = SpawnResponseSerializer::class)
data class SpawnResponse(
    /** `'success' | 'error'`. */
    val type: String,
    val sessionId: String? = null,
    val message: String? = null,
    /** `agent_unavailable | runner_upgrade_required | outside_workspace_roots`. */
    val code: String? = null,
    val agent: String? = null,
)

internal object SpawnResponseSerializer : KSerializer<SpawnResponse> {
    override val descriptor: SerialDescriptor =
        SerialDescriptor("app.hapi.protocol.wire.SpawnResponse", JsonObject.serializer().descriptor)

    override fun deserialize(decoder: Decoder): SpawnResponse {
        val input = decoder as? JsonDecoder
            ?: throw SerializationException("SpawnResponse supports JSON only")
        val obj = input.decodeJsonElement() as? JsonObject
            ?: throw SerializationException("SpawnResponse must be a JSON object")
        val sessionObj = obj["session"] as? JsonObject
        if (sessionObj != null) {
            val id = sessionObj["id"].stringOrNull
                ?: throw SerializationException("SpawnResponse.session missing id")
            return SpawnResponse(type = "success", sessionId = id)
        }
        val type = obj["type"].stringOrNull
            ?: throw SerializationException("SpawnResponse missing type or session")
        return SpawnResponse(
            type = type,
            sessionId = obj["sessionId"].stringOrNull ?: obj["session_id"].stringOrNull,
            message = obj["message"].stringOrNull ?: obj["error"].stringOrNull,
            code = obj["code"].stringOrNull,
            agent = obj["agent"].stringOrNull,
        )
    }

    override fun serialize(encoder: Encoder, value: SpawnResponse) {
        val output = encoder as? JsonEncoder
            ?: throw SerializationException("SpawnResponse supports JSON only")
        output.encodeJsonElement(buildJsonObject {
            put("type", JsonPrimitive(value.type))
            value.sessionId?.let { put("sessionId", JsonPrimitive(it)) }
            value.message?.let { put("message", JsonPrimitive(it)) }
            value.code?.let { put("code", JsonPrimitive(it)) }
            value.agent?.let { put("agent", JsonPrimitive(it)) }
        })
    }
}

/** `GET /api/sessions/:id/slash-commands` (RPC-wrapped: check [success]). */
@Serializable
data class SlashCommandsResponse(
    val success: Boolean,
    val commands: List<SlashCommand>? = null,
    val error: String? = null,
)

@Serializable
data class SlashCommand(
    val name: String,
    val description: String? = null,
    /** `'builtin' | 'user' | 'plugin' | 'project'`. */
    val source: String,
    val content: String? = null,
    val pluginName: String? = null,
)

/** `GET /api/sessions/:id/skills` (RPC-wrapped: check [success]). */
@Serializable
data class SkillsResponse(
    val success: Boolean,
    val skills: List<SkillSummary>? = null,
    val error: String? = null,
)

@Serializable
data class SkillSummary(
    val name: String,
    val description: String? = null,
)

/** `POST /api/machines/:id/list-directory` (RPC-wrapped: check [success]). */
@Serializable
data class MachineListDirectoryResponse(
    val success: Boolean,
    val entries: List<MachineDirectoryEntry>? = null,
    val error: String? = null,
)

/** `DirectoryEntry & {isGitRepo?}` (`shared/src/apiTypes.ts`). */
@Serializable
data class MachineDirectoryEntry(
    val name: String,
    /** `'file' | 'directory' | 'other'`. */
    val type: String,
    val size: Long? = null,
    /** Epoch ms (fs mtime — may arrive fractional; see [LenientEpochMs]). */
    @Serializable(with = LenientEpochMs::class)
    val modified: Long? = null,
    val isGitRepo: Boolean? = null,
)

/** `POST /api/machines/:id/paths/exists`. */
@Serializable
data class MachinePathsExistsResponse(
    val exists: Map<String, Boolean>,
    val outsideWorkspaceRoots: List<String>? = null,
)

/** `GET /api/machines/:id/agent-availability`. */
@Serializable
data class AgentAvailabilityResponse(
    val agents: List<AgentAvailabilityEntry>,
)

@Serializable
data class AgentAvailabilityEntry(
    val agent: String,
    val available: Boolean,
    /** `not_found | invalid_configuration`. */
    val reason: String? = null,
)

/**
 * `GET /api/machines/:id/codex-models` (also the session-level twin) —
 * RPC-wrapped: check [success]. A runner that does not expose the machine RPC
 * answers 503 `{success:false, code:'rpc_target_missing'}` (surfaces as
 * [app.hapi.data.api] ApiError, not this body). Added for B-M3d (new-session
 * codex model picker); `CodexModelsResponse` in `shared/src/apiTypes.ts`.
 */
@Serializable
data class CodexModelsResponse(
    val success: Boolean,
    val models: List<CodexModelSummary>? = null,
    val error: String? = null,
)

/** `CodexModelSummary` (`shared/src/apiTypes.ts`). */
@Serializable
data class CodexModelSummary(
    val id: String,
    val displayName: String,
    val isDefault: Boolean,
    val defaultReasoningEffort: String? = null,
    val defaultServiceTier: String? = null,
    val supportedReasoningEfforts: List<String>? = null,
    /** Service tier ids advertised for this model in the current auth/plan context (e.g. `fast`). */
    val serviceTiers: List<String>? = null,
)

/**
 * `GET /api/machines/:id/grok-models?cwd=` (RPC-wrapped: check [success]) —
 * the directory-scoped Grok probe; `GrokModelsResponse` in
 * `shared/src/apiTypes.ts`. This slice consumes only
 * [autoPermissionModeSupported] (the create-form Auto gate); model discovery
 * stays deferred and unknown fields are ignored by [HapiJson].
 */
@Serializable
data class GrokModelsResponse(
    val success: Boolean,
    val availableModels: List<GrokModelSummary>? = null,
    val currentModelId: String? = null,
    /**
     * Nullable on purpose: the server may omit it, and the gate fires only on
     * a literal `false` (web guards with `=== false`).
     */
    val autoPermissionModeSupported: Boolean? = null,
    val error: String? = null,
)

/** `GrokModelSummary` (`shared/src/apiTypes.ts`). */
@Serializable
data class GrokModelSummary(
    val modelId: String,
    val name: String? = null,
)

/** `POST /api/sessions/:id/upload` (RPC-wrapped: check [success]). */
@Serializable
data class UploadFileResponse(
    val success: Boolean,
    /** Pass through as `AttachmentMetadata.path` when sending the message. */
    val path: String? = null,
    val error: String? = null,
)

/** `POST /api/sessions/:id/upload/delete` (RPC-wrapped: check [success]). */
@Serializable
data class DeleteUploadResponse(
    val success: Boolean,
    val error: String? = null,
)

/** `POST /api/voice/transcription` (the one multipart endpoint). */
@Serializable
data class TranscriptionResponse(
    val text: String,
    val language: String? = null,
)

/**
 * `GET /api/voice/transcription/providers` — only providers whose keys are
 * configured on the hub (`listConfiguredTranscriptionProviders`,
 * `shared/src/voice.ts`). Empty ⇒ dictation is unavailable. Added in B-M3ce.
 */
@Serializable
data class TranscriptionProvidersResponse(
    val providers: List<TranscriptionProviderInfo>,
)

/** `TranscriptionProviderInfo` (`shared/src/voice.ts`). */
@Serializable
data class TranscriptionProviderInfo(
    /** `openai | elevenlabs | deepgram | groq | openai-compatible | browser-local`. */
    val id: String,
    val label: String,
    /** Subset of `standard` / `realtime`; native dictation uses `standard`. */
    val modes: List<String>,
)
