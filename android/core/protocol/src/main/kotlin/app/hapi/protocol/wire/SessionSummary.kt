package app.hapi.protocol.wire

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject

/**
 * Session-list row returned by `GET /v1/sessions` (Reins Native v1 full `Session`
 * projected via [SummaryPatching.toSessionSummary]) or legacy `SessionSummary`.
 */
@Serializable(with = SessionSummarySerializer::class)
data class SessionSummary(
    val id: String,
    val active: Boolean,
    val thinking: Boolean = false,
    val activeAt: Long = 0,
    val updatedAt: Long = 0,
    val createdAt: Long? = null,
    val lastUserMessageAt: Long? = null,
    /** Hub: this session has conversation content (list hides fresh "new session" stubs). */
    val hasConversationContent: Boolean = false,
    val pinned: Boolean? = null,
    val globalPinned: Boolean? = null,
    val metadata: SessionSummaryMetadata? = null,
    val metadataVersion: Long = 0,
    val agentStateVersion: Long = 0,
    val todosUpdatedAt: Long = 0,
    val todoProgress: TodoProgress? = null,
    /** Authoritative total — may exceed `pendingRequests.size` (capped at 5). */
    val pendingRequestsCount: Int = 0,
    /** `'permission'` / `'input'`, deduplicated. */
    val pendingRequestKinds: List<String> = emptyList(),
    /** Capped (≤ 5), oldest-first slice for per-row hover copy. */
    val pendingRequests: List<PendingRequest> = emptyList(),
    val backgroundTaskCount: Int = 0,
    val futureScheduledMessageCount: Int = 0,
    /** Epoch ms of the soonest uninvoked future scheduled message, or null. */
    val nextScheduledAt: Long? = null,
    val model: String? = null,
    val modelReasoningEffort: String? = null,
    val effort: String? = null,
    val contentRevision: Long? = null,
    val readState: SessionReadState? = null,
)

@Serializable
private data class LegacySessionSummarySurrogate(
    val id: String,
    val active: Boolean,
    val thinking: Boolean = false,
    val activeAt: Long = 0,
    val updatedAt: Long = 0,
    val createdAt: Long? = null,
    val lastUserMessageAt: Long? = null,
    val hasConversationContent: Boolean = false,
    val pinned: Boolean? = null,
    val globalPinned: Boolean? = null,
    val metadata: SessionSummaryMetadata? = null,
    val metadataVersion: Long = 0,
    val agentStateVersion: Long = 0,
    val todosUpdatedAt: Long = 0,
    val todoProgress: TodoProgress? = null,
    val pendingRequestsCount: Int = 0,
    val pendingRequestKinds: List<String> = emptyList(),
    val pendingRequests: List<PendingRequest> = emptyList(),
    val backgroundTaskCount: Int = 0,
    val futureScheduledMessageCount: Int = 0,
    val nextScheduledAt: Long? = null,
    val model: String? = null,
    val modelReasoningEffort: String? = null,
    val effort: String? = null,
    val contentRevision: Long? = null,
    val readState: SessionReadState? = null,
) {
    fun toSessionSummary() = SessionSummary(
        id = id,
        active = active,
        thinking = thinking,
        activeAt = activeAt,
        updatedAt = updatedAt,
        createdAt = createdAt,
        lastUserMessageAt = lastUserMessageAt,
        hasConversationContent = hasConversationContent,
        pinned = pinned,
        globalPinned = globalPinned,
        metadata = metadata,
        metadataVersion = metadataVersion,
        agentStateVersion = agentStateVersion,
        todosUpdatedAt = todosUpdatedAt,
        todoProgress = todoProgress,
        pendingRequestsCount = pendingRequestsCount,
        pendingRequestKinds = pendingRequestKinds,
        pendingRequests = pendingRequests,
        backgroundTaskCount = backgroundTaskCount,
        futureScheduledMessageCount = futureScheduledMessageCount,
        nextScheduledAt = nextScheduledAt,
        model = model,
        modelReasoningEffort = modelReasoningEffort,
        effort = effort,
        contentRevision = contentRevision,
        readState = readState,
    )
}

internal object SessionSummarySerializer : KSerializer<SessionSummary> {
    override val descriptor: SerialDescriptor =
        SerialDescriptor("app.hapi.protocol.wire.SessionSummary", JsonObject.serializer().descriptor)

    override fun deserialize(decoder: Decoder): SessionSummary {
        val input = decoder as? JsonDecoder
            ?: throw SerializationException("SessionSummary supports JSON only")
        val obj = input.decodeJsonElement() as? JsonObject
            ?: throw SerializationException("SessionSummary must be a JSON object")
        if (isV1SessionJson(obj)) {
            return SummaryPatching.toSessionSummary(decodeV1Session(obj))
        }
        return HapiJson.decodeFromJsonElement(LegacySessionSummarySurrogate.serializer(), obj).toSessionSummary()
    }

    override fun serialize(encoder: Encoder, value: SessionSummary) {
        val output = encoder as? JsonEncoder
            ?: throw SerializationException("SessionSummary supports JSON only")
        val surrogate = LegacySessionSummarySurrogate(
            id = value.id,
            active = value.active,
            thinking = value.thinking,
            activeAt = value.activeAt,
            updatedAt = value.updatedAt,
            createdAt = value.createdAt,
            lastUserMessageAt = value.lastUserMessageAt,
            hasConversationContent = value.hasConversationContent,
            pinned = value.pinned,
            globalPinned = value.globalPinned,
            metadata = value.metadata,
            metadataVersion = value.metadataVersion,
            agentStateVersion = value.agentStateVersion,
            todosUpdatedAt = value.todosUpdatedAt,
            todoProgress = value.todoProgress,
            pendingRequestsCount = value.pendingRequestsCount,
            pendingRequestKinds = value.pendingRequestKinds,
            pendingRequests = value.pendingRequests,
            backgroundTaskCount = value.backgroundTaskCount,
            futureScheduledMessageCount = value.futureScheduledMessageCount,
            nextScheduledAt = value.nextScheduledAt,
            model = value.model,
            modelReasoningEffort = value.modelReasoningEffort,
            effort = value.effort,
            contentRevision = value.contentRevision,
            readState = value.readState,
        )
        output.encodeJsonElement(HapiJson.encodeToJsonElement(LegacySessionSummarySurrogate.serializer(), surrogate))
    }
}

/** `SessionSummaryMetadata` — list-sized metadata projection. */
@Serializable
data class SessionSummaryMetadata(
    val tags: List<String> = emptyList(),
    val name: String? = null,
    val path: String,
    val machineId: String? = null,
    /** Summary text only — no `updatedAt` in the list projection. */
    val summary: SummaryText? = null,
    val flavor: String? = null,
    val worktree: WorktreeMetadata? = null,
    val agentSessionId: String? = null,
    val lifecycleState: String? = null,
    val hapiMcpUrl: String? = null,
)

@Serializable
data class SummaryText(
    val text: String,
)

@Serializable
data class TodoProgress(
    val completed: Int,
    val total: Int,
)

/**
 * One pending request in the capped summary slice (`PendingRequest`,
 * `shared/src/sessionSummary.ts`).
 */
@Serializable
data class PendingRequest(
    val id: String,
    /** `'permission' | 'input'`. */
    val kind: String,
    val tool: String,
    /** Epoch ms when raised (hub falls back to `session.updatedAt`). */
    val since: Long,
)
