package app.hapi.protocol.wire

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/**
 * Full session row. Decodes both Reins Native v1 `Session` JSON (snake_case)
 * and legacy HAPI `SessionSchema` JSON.
 */
@Serializable(with = SessionSerializer::class)
data class Session(
    /** Hub: the session has conversation content (first-field parity with `SessionSchema`). */
    val hasConversationContent: Boolean = false,
    val id: String,
    val namespace: String,
    val seq: Long,
    val createdAt: Long,
    val updatedAt: Long,
    val lastUserMessageAt: Long? = null,
    val pinned: Boolean? = null,
    val globalPinned: Boolean? = null,
    val active: Boolean,
    val activeAt: Long = 0,
    val metadata: SessionMetadata? = null,
    val metadataVersion: Long,
    val agentState: AgentState? = null,
    val agentStateVersion: Long,
    val thinking: Boolean,
    val thinkingAt: Long,
    val activeTurnStartedAt: Long? = null,
    val backgroundTaskCount: Int? = null,
    val todos: List<TodoItem>? = null,
    val teamState: JsonElement? = null,
    val todosUpdatedAt: Long? = null,
    val teamStateUpdatedAt: Long? = null,
    val model: String? = null,
    val modelReasoningEffort: String? = null,
    val effort: String? = null,
    val serviceTier: String? = null,
    val permissionMode: String? = null,
    val collaborationMode: String? = null,
    val copilotAgentMode: String? = null,
    val contentRevision: Long? = null,
    val readState: SessionReadState? = null,
)

@Serializable
private data class LegacySessionSurrogate(
    val hasConversationContent: Boolean = false,
    val id: String,
    val namespace: String,
    val seq: Long,
    val createdAt: Long,
    val updatedAt: Long,
    val lastUserMessageAt: Long? = null,
    val pinned: Boolean? = null,
    val globalPinned: Boolean? = null,
    val active: Boolean,
    val activeAt: Long = 0,
    val metadata: SessionMetadata? = null,
    val metadataVersion: Long,
    val agentState: AgentState? = null,
    val agentStateVersion: Long,
    val thinking: Boolean,
    val thinkingAt: Long,
    val activeTurnStartedAt: Long? = null,
    val backgroundTaskCount: Int? = null,
    val todos: List<TodoItem>? = null,
    val teamState: JsonElement? = null,
    val todosUpdatedAt: Long? = null,
    val teamStateUpdatedAt: Long? = null,
    val model: String? = null,
    val modelReasoningEffort: String? = null,
    val effort: String? = null,
    val serviceTier: String? = null,
    val permissionMode: String? = null,
    val collaborationMode: String? = null,
    val copilotAgentMode: String? = null,
    val contentRevision: Long? = null,
    val readState: SessionReadState? = null,
) {
    fun toSession() = Session(
        hasConversationContent = hasConversationContent,
        id = id,
        namespace = namespace,
        seq = seq,
        createdAt = createdAt,
        updatedAt = updatedAt,
        lastUserMessageAt = lastUserMessageAt,
        pinned = pinned,
        globalPinned = globalPinned,
        active = active,
        activeAt = activeAt,
        metadata = metadata,
        metadataVersion = metadataVersion,
        agentState = agentState,
        agentStateVersion = agentStateVersion,
        thinking = thinking,
        thinkingAt = thinkingAt,
        activeTurnStartedAt = activeTurnStartedAt,
        backgroundTaskCount = backgroundTaskCount,
        todos = todos,
        teamState = teamState,
        todosUpdatedAt = todosUpdatedAt,
        teamStateUpdatedAt = teamStateUpdatedAt,
        model = model,
        modelReasoningEffort = modelReasoningEffort,
        effort = effort,
        serviceTier = serviceTier,
        permissionMode = permissionMode,
        collaborationMode = collaborationMode,
        copilotAgentMode = copilotAgentMode,
        contentRevision = contentRevision,
        readState = readState,
    )
}

internal fun isV1SessionJson(obj: JsonObject): Boolean =
    obj.containsKey("created_at") || obj.containsKey("machine_id") || obj.containsKey("meta_rev")

internal fun decodeV1Session(obj: JsonObject): Session {
    val id = obj["id"].stringOrNull
        ?: throw SerializationException("Session.id must be a string")
    val namespace = obj["namespace"].stringOrNull ?: "default"
    val createdAt = obj["created_at"].longOrNull ?: obj["createdAt"].longOrNull ?: 0L
    val updatedAt = obj["updated_at"].longOrNull ?: obj["updatedAt"].longOrNull ?: createdAt
    val status = obj["status"].stringOrNull ?: "idle"
    val archived = obj["archived"].boolOrNull ?: (status == "archived")
    val active = !archived && status != "archived"
    val thinking = status == "thinking"
    val pinMode = obj["pin_mode"].stringOrNull ?: "none"
    val pinned = (pinMode == "project") || (pinMode != "global" && obj["pinned"].boolOrNull == true)
    val globalPinned = pinMode == "global"
    val contentRev = obj["content_rev"].longOrNull ?: 0L
    val readRev = obj["read_rev"].longOrNull ?: 0L
    val readStateVer = obj["read_state_ver"].longOrNull ?: 0L
    val manualUnread = obj["manual_unread"].boolOrNull ?: false
    val messageCount = obj["message_count"].longOrNull ?: 0L
    val lastPreview = obj["last_preview"].stringOrNull
    val hasConversationContent = messageCount > 0L || !lastPreview.isNullOrBlank() || contentRev > 0L

    val rawMeta = obj["metadata"] as? JsonObject
    val directory = obj["directory"].stringOrNull ?: rawMeta?.get("path").stringOrNull ?: ""
    val machineId = obj["machine_id"].stringOrNull ?: rawMeta?.get("machineId").stringOrNull
    val agent = obj["agent"].stringOrNull ?: rawMeta?.get("flavor").stringOrNull
    val title = obj["title"].stringOrNull?.takeIf { it.isNotBlank() }
        ?: rawMeta?.get("name").stringOrNull
    val host = rawMeta?.get("host").stringOrNull ?: machineId ?: "reins"
    val lifecycleState = if (archived || status == "archived") {
        "archived"
    } else {
        rawMeta?.get("lifecycleState").stringOrNull ?: "running"
    }

    val mergedMetaJson = buildJsonObject {
        rawMeta?.forEach { (k, v) -> put(k, v) }
        put("path", JsonPrimitive(directory))
        put("host", JsonPrimitive(host))
        title?.let { put("name", JsonPrimitive(it)) }
        machineId?.let { put("machineId", JsonPrimitive(it)) }
        agent?.let { put("flavor", JsonPrimitive(it)) }
        put("lifecycleState", JsonPrimitive(lifecycleState))
        val rawSummary = rawMeta?.get("summary")
        if (rawSummary is JsonPrimitive && rawSummary.isString) {
            put("summary", buildJsonObject {
                put("text", rawSummary)
                put("updatedAt", JsonPrimitive(updatedAt))
            })
        } else if (rawSummary is JsonObject && !rawSummary.containsKey("updatedAt")) {
            put("summary", buildJsonObject {
                rawSummary.forEach { (k, v) -> put(k, v) }
                put("updatedAt", JsonPrimitive(updatedAt))
            })
        }
    }
    val metadata = runCatching {
        HapiJson.decodeFromJsonElement(SessionMetadata.serializer(), mergedMetaJson)
    }.getOrNull() ?: SessionMetadata(
        path = directory,
        host = host,
        name = title,
        machineId = machineId,
        flavor = agent,
        lifecycleState = lifecycleState,
    )

    val agentState = (obj["pending_requests"] as? JsonObject)?.let { pr ->
        if (pr.isEmpty()) null
        else runCatching { HapiJson.decodeFromJsonElement(AgentState.serializer(), pr) }.getOrNull()
    }

    return Session(
        hasConversationContent = hasConversationContent,
        id = id,
        namespace = namespace,
        seq = obj["seq"].longOrNull ?: 0L,
        createdAt = createdAt,
        updatedAt = updatedAt,
        lastUserMessageAt = rawMeta?.get("lastUserMessageAt").longOrNull ?: updatedAt.takeIf { hasConversationContent },
        pinned = pinned,
        globalPinned = globalPinned,
        active = active,
        activeAt = updatedAt,
        metadata = metadata,
        metadataVersion = obj["meta_rev"].longOrNull ?: 0L,
        agentState = agentState,
        agentStateVersion = obj["state_rev"].longOrNull ?: 0L,
        thinking = thinking,
        thinkingAt = updatedAt,
        backgroundTaskCount = 0,
        model = obj["model"].stringOrNull?.takeIf { it.isNotEmpty() },
        modelReasoningEffort = obj["effort"].stringOrNull,
        effort = obj["effort"].stringOrNull,
        permissionMode = obj["permission_mode"].stringOrNull,
        contentRevision = contentRev,
        readState = SessionReadState(
            readRevision = readRev,
            manualUnread = manualUnread,
            version = readStateVer,
        ),
    )
}

internal object SessionSerializer : KSerializer<Session> {
    override val descriptor: SerialDescriptor =
        SerialDescriptor("app.hapi.protocol.wire.Session", JsonObject.serializer().descriptor)

    override fun deserialize(decoder: Decoder): Session {
        val input = decoder as? JsonDecoder
            ?: throw SerializationException("Session supports JSON only")
        val obj = input.decodeJsonElement() as? JsonObject
            ?: throw SerializationException("Session must be a JSON object")
        if (isV1SessionJson(obj)) {
            return decodeV1Session(obj)
        }
        return HapiJson.decodeFromJsonElement(LegacySessionSurrogate.serializer(), obj).toSession()
    }

    override fun serialize(encoder: Encoder, value: Session) {
        val output = encoder as? JsonEncoder
            ?: throw SerializationException("Session supports JSON only")
        val surrogate = LegacySessionSurrogate(
            hasConversationContent = value.hasConversationContent,
            id = value.id,
            namespace = value.namespace,
            seq = value.seq,
            createdAt = value.createdAt,
            updatedAt = value.updatedAt,
            lastUserMessageAt = value.lastUserMessageAt,
            pinned = value.pinned,
            globalPinned = value.globalPinned,
            active = value.active,
            activeAt = value.activeAt,
            metadata = value.metadata,
            metadataVersion = value.metadataVersion,
            agentState = value.agentState,
            agentStateVersion = value.agentStateVersion,
            thinking = value.thinking,
            thinkingAt = value.thinkingAt,
            activeTurnStartedAt = value.activeTurnStartedAt,
            backgroundTaskCount = value.backgroundTaskCount,
            todos = value.todos,
            teamState = value.teamState,
            todosUpdatedAt = value.todosUpdatedAt,
            teamStateUpdatedAt = value.teamStateUpdatedAt,
            model = value.model,
            modelReasoningEffort = value.modelReasoningEffort,
            effort = value.effort,
            serviceTier = value.serviceTier,
            permissionMode = value.permissionMode,
            collaborationMode = value.collaborationMode,
            copilotAgentMode = value.copilotAgentMode,
            contentRevision = value.contentRevision,
            readState = value.readState,
        )
        output.encodeJsonElement(HapiJson.encodeToJsonElement(LegacySessionSurrogate.serializer(), surrogate))
    }
}

/**
 * One TodoWrite item (`TodoItemSchema`). zod defaults `priority` to
 * `'medium'` and `id` to `''`; replicated as Kotlin defaults.
 */
@Serializable
data class TodoItem(
    val content: String,
    /** `'pending' | 'in_progress' | 'completed'`. */
    val status: String,
    val priority: String = "medium",
    val id: String = "",
    val activeForm: String? = null,
)
