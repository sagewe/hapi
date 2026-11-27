package app.hapi.protocol.wire

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject

/**
 * One stored chat message as returned by `GET /api/sessions/:id/messages` and
 * the `message-received` SSE event. Mirrors `DecryptedMessageSchema`
 * (`shared/src/schemas.ts`).
 *
 * [content] is the raw role-wrapped envelope — decoding it into renderable
 * blocks is the chat-pipeline milestone (`docs/api/client-contract/messages.md`),
 * not a wire concern.
 *
 * [invokedAt] is tri-state on purpose (`docs/api/client-contract/pagination.md`):
 * explicit `null` = the message is still queued; a number = when the agent
 * consumed it; **absent** = already invoked (pre-V8 hubs omit the field). A
 * plain `Long?` would silently merge "queued" with "legacy invoked", so this
 * class carries a hand-written serializer.
 */
@Serializable(with = DecryptedMessageSerializer::class)
data class DecryptedMessage(
    val id: String,
    val seq: Long? = null,
    val localId: String? = null,
    val content: JsonElement = JsonNull,
    val createdAt: Long,
    val invokedAt: OptionalField<Long?> = OptionalField.Absent,
    val scheduledAt: Long? = null,
    val deliveryState: String? = null,
    val contentRevision: Long? = null,
) {
    /** `invokedAt` collapsed to a plain value (both absent and `null` → null). */
    val invokedAtOrNull: Long? get() = invokedAt.valueOrNull()

    /** Display position: `invokedAt ?? createdAt` (see pagination.md "Position key"). */
    val positionAt: Long get() = invokedAtOrNull ?: createdAt

    /** Phase A/B streaming metadata on the wire envelope, if present. */
    private val envelopeMeta: JsonObject?
        get() = (content as? JsonObject)?.get("meta") as? JsonObject

    /** `true` when this stored message is an in-progress Phase A streaming upsert. */
    val isStreaming: Boolean
        get() = envelopeMeta?.get("streaming")?.boolOrNull == true

    /** Segment id (`meta.segmentId` / `meta.segment_id`) used to reconcile `/stream` overlays. */
    val streamSegmentId: String?
        get() = envelopeMeta?.let { it["segmentId"].stringOrNull ?: it["segment_id"].stringOrNull }

    /** Turn id (`meta.turnId` / `meta.turn_id`) if attached to message metadata. */
    val streamTurnId: String?
        get() = envelopeMeta?.let { it["turnId"].stringOrNull ?: it["turn_id"].stringOrNull }
}

internal object DecryptedMessageSerializer : KSerializer<DecryptedMessage> {
    override val descriptor: SerialDescriptor =
        SerialDescriptor("app.hapi.protocol.wire.DecryptedMessage", JsonObject.serializer().descriptor)

    override fun deserialize(decoder: Decoder): DecryptedMessage {
        val input = decoder as? JsonDecoder
            ?: throw SerializationException("DecryptedMessage supports JSON only")
        val obj = input.decodeJsonElement() as? JsonObject
            ?: throw SerializationException("DecryptedMessage must be a JSON object")
        val isV1 = obj.containsKey("created_at") ||
            (obj.containsKey("role") && obj.containsKey("blocks") && !obj.containsKey("content"))
        if (isV1) {
            return decodeV1Message(obj)
        }
        return DecryptedMessage(
            contentRevision = obj["contentRevision"]?.longOrNull,
            id = obj["id"].stringOrNull
                ?: throw SerializationException("DecryptedMessage.id must be a string"),
            seq = obj["seq"].longOrNull,
            localId = obj["localId"].stringOrNull,
            content = obj["content"] ?: JsonNull,
            createdAt = obj["createdAt"].longOrNull
                ?: throw SerializationException("DecryptedMessage.createdAt must be a number"),
            invokedAt = if (obj.containsKey("invokedAt")) {
                OptionalField.Present(obj["invokedAt"].longOrNull)
            } else {
                OptionalField.Absent
            },
            scheduledAt = obj["scheduledAt"].longOrNull,
            deliveryState = obj["deliveryState"].stringOrNull,
        )
    }

    private fun decodeV1Message(obj: JsonObject): DecryptedMessage {
        val id = obj["id"].stringOrNull
            ?: throw SerializationException("DecryptedMessage.id must be a string")
        val createdAt = obj["created_at"].longOrNull
            ?: obj["createdAt"].longOrNull
            ?: throw SerializationException("DecryptedMessage.created_at must be a number")
        val role = obj["role"].stringOrNull ?: "user"
        val deliveryState = obj["delivery_state"].stringOrNull ?: obj["deliveryState"].stringOrNull
        val rawInvokedAt = obj["invoked_at"].longOrNull ?: obj["invokedAt"].longOrNull
        val invokedAt = when {
            rawInvokedAt != null -> OptionalField.Present(rawInvokedAt)
            role == "user" && deliveryState in setOf("queued", "dispatching", "indeterminate") ->
                OptionalField.Present(null)
            else -> OptionalField.Present(createdAt)
        }
        val blocks = (obj["blocks"] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()
        val meta = obj["meta"] as? JsonObject
        val content = obj["content"] ?: buildCompatEnvelope(id, role, blocks, meta)
        return DecryptedMessage(
            contentRevision = obj["content_rev"].longOrNull ?: obj["contentRevision"].longOrNull,
            id = id,
            seq = obj["seq"].longOrNull,
            localId = obj["local_id"].stringOrNull ?: obj["localId"].stringOrNull,
            content = content,
            createdAt = createdAt,
            invokedAt = invokedAt,
            scheduledAt = obj["scheduled_at"].longOrNull ?: obj["scheduledAt"].longOrNull,
            deliveryState = deliveryState,
        )
    }

    /** Convert Reins Native v1 `StoredMessage` (role + blocks + meta) into the HAPI role-wrapped content envelope. */
    private fun buildCompatEnvelope(
        msgId: String,
        role: String,
        blocks: List<JsonObject>,
        meta: JsonObject?,
    ): JsonObject = when (role) {
        "user" -> {
            val texts = mutableListOf<String>()
            val attachments = mutableListOf<JsonObject>()
            for (blk in blocks) {
                when (blk["type"].stringOrNull) {
                    "text" -> blk["text"].stringOrNull?.let(texts::add)
                    "attachment" -> {
                        val filename = blk["filename"].stringOrNull ?: ""
                        val previewUrl = blk["previewUrl"].stringOrNull ?: blk["preview_url"].stringOrNull
                        attachments.add(buildJsonObject {
                            blk["id"]?.let { put("id", it) }
                            put("filename", JsonPrimitive(filename))
                            put("mimeType", JsonPrimitive(blk["mimeType"].stringOrNull ?: blk["mime_type"].stringOrNull ?: "application/octet-stream"))
                            put("size", JsonPrimitive(blk["size"].longOrNull ?: 0L))
                            put("path", JsonPrimitive(previewUrl ?: filename))
                            if (!previewUrl.isNullOrBlank()) {
                                put("previewUrl", JsonPrimitive(previewUrl))
                            }
                        })
                    }
                }
            }
            val inner = buildJsonObject {
                put("type", JsonPrimitive("text"))
                put("text", JsonPrimitive(texts.joinToString("\n")))
                if (attachments.isNotEmpty()) {
                    put("attachments", JsonArray(attachments))
                }
            }
            buildJsonObject {
                put("role", JsonPrimitive("user"))
                put("content", inner)
                if (meta != null && meta.isNotEmpty()) put("meta", meta)
            }
        }
        "assistant" -> {
            val singleGenMedia = blocks.singleOrNull()?.takeIf { it["type"].stringOrNull == "generated_media" }
            if (singleGenMedia != null) {
                buildJsonObject {
                    put("role", JsonPrimitive("agent"))
                    put("content", buildJsonObject {
                        put("type", JsonPrimitive("codex"))
                        put("data", buildJsonObject {
                            put("type", JsonPrimitive("generated-image"))
                            put("id", JsonPrimitive(msgId))
                            put("imageId", JsonPrimitive(singleGenMedia["id"].stringOrNull ?: msgId))
                            put("fileName", JsonPrimitive(singleGenMedia["filename"].stringOrNull ?: "media"))
                            put("mimeType", JsonPrimitive(singleGenMedia["mime_type"].stringOrNull ?: singleGenMedia["mimeType"].stringOrNull ?: "image/png"))
                        })
                    })
                    if (meta != null && meta.isNotEmpty()) put("meta", meta)
                }
            } else {
                val contentBlocks = buildJsonArray {
                    for (blk in blocks) {
                        when (blk["type"].stringOrNull) {
                            "text" -> add(buildJsonObject {
                                put("type", JsonPrimitive("text"))
                                put("text", JsonPrimitive(blk["text"].stringOrNull ?: ""))
                            })
                            "thinking" -> add(buildJsonObject {
                                put("type", JsonPrimitive("thinking"))
                                put("thinking", JsonPrimitive(blk["thinking"].stringOrNull ?: ""))
                            })
                            "tool_use" -> add(buildJsonObject {
                                put("type", JsonPrimitive("tool_use"))
                                put("id", JsonPrimitive(blk["id"].stringOrNull ?: ""))
                                put("name", JsonPrimitive(blk["name"].stringOrNull ?: ""))
                                put("input", blk["input"] ?: JsonObject(emptyMap()))
                            })
                            "generated_media" -> add(buildJsonObject {
                                put("type", JsonPrimitive("generated_media"))
                                put("id", JsonPrimitive(blk["id"].stringOrNull ?: msgId))
                                put("filename", JsonPrimitive(blk["filename"].stringOrNull ?: "media"))
                                put("mime_type", JsonPrimitive(blk["mime_type"].stringOrNull ?: blk["mimeType"].stringOrNull ?: "image/png"))
                            })
                        }
                    }
                }
                buildJsonObject {
                    put("role", JsonPrimitive("agent"))
                    put("content", buildJsonObject {
                        put("type", JsonPrimitive("output"))
                        put("data", buildJsonObject {
                            put("type", JsonPrimitive("assistant"))
                            put("message", buildJsonObject {
                                put("role", JsonPrimitive("assistant"))
                                put("content", contentBlocks)
                                meta?.get("model")?.takeIf { it !is JsonNull }?.let { put("model", it) }
                                meta?.get("usage")?.takeIf { it !is JsonNull }?.let { put("usage", it) }
                            })
                        })
                    })
                    if (meta != null && meta.isNotEmpty()) put("meta", meta)
                }
            }
        }
        "tool" -> {
            var firstToolName: String? = null
            var firstReceipt: JsonElement? = null
            val contentBlocks = buildJsonArray {
                for (blk in blocks) {
                    if (blk["type"].stringOrNull == "tool_result") {
                        val name = blk["name"].stringOrNull
                        val receipt = blk["receipt"]
                        if (firstToolName == null && name != null) firstToolName = name
                        if (firstReceipt == null && receipt != null && receipt !is JsonNull) firstReceipt = receipt
                        add(buildJsonObject {
                            put("type", JsonPrimitive("tool_result"))
                            put("tool_use_id", JsonPrimitive(blk["tool_use_id"].stringOrNull ?: ""))
                            put("content", JsonPrimitive(blk["content"].stringOrNull ?: ""))
                            put("is_error", JsonPrimitive(blk["is_error"].boolOrNull ?: false))
                            if (receipt != null && receipt !is JsonNull) put("tool_receipt", receipt)
                        })
                    }
                }
            }
            val mergedMeta = buildJsonObject {
                meta?.forEach { (k, v) -> put(k, v) }
                if (firstToolName != null && (meta == null || !meta.containsKey("toolName"))) {
                    put("toolName", JsonPrimitive(firstToolName))
                }
                if (firstReceipt != null && (meta == null || !meta.containsKey("toolReceipt"))) {
                    put("toolReceipt", firstReceipt)
                }
            }
            buildJsonObject {
                put("role", JsonPrimitive("agent"))
                put("content", buildJsonObject {
                    put("type", JsonPrimitive("output"))
                    put("data", buildJsonObject {
                        put("type", JsonPrimitive("user"))
                        put("message", buildJsonObject {
                            put("role", JsonPrimitive("user"))
                            put("content", contentBlocks)
                        })
                    })
                })
                if (mergedMeta.isNotEmpty()) put("meta", mergedMeta)
            }
        }
        "system" -> {
            val text = blocks.mapNotNull { blk ->
                if (blk["type"].stringOrNull == "text") blk["text"].stringOrNull else null
            }.joinToString("\n")
            buildJsonObject {
                put("role", JsonPrimitive("system"))
                put("content", buildJsonObject {
                    put("type", JsonPrimitive("text"))
                    put("text", JsonPrimitive(text))
                })
            }
        }
        else -> buildJsonObject {
            put("role", JsonPrimitive(role))
            put("content", JsonArray(blocks))
        }
    }

    override fun serialize(encoder: Encoder, value: DecryptedMessage) {
        val output = encoder as? JsonEncoder
            ?: throw SerializationException("DecryptedMessage supports JSON only")
        output.encodeJsonElement(buildJsonObject {
            value.contentRevision?.let { put("contentRevision", JsonPrimitive(it)) }
            put("id", JsonPrimitive(value.id))
            put("seq", value.seq?.let(::JsonPrimitive) ?: JsonNull)
            put("localId", value.localId?.let(::JsonPrimitive) ?: JsonNull)
            put("content", value.content)
            put("createdAt", JsonPrimitive(value.createdAt))
            if (value.invokedAt is OptionalField.Present) {
                put("invokedAt", value.invokedAt.value?.let(::JsonPrimitive) ?: JsonNull)
            }
            value.scheduledAt?.let { put("scheduledAt", JsonPrimitive(it)) }
            value.deliveryState?.let { put("deliveryState", JsonPrimitive(it)) }
        })
    }
}

/**
 * User-message attachment descriptor (`AttachmentMetadataSchema`). Also the
 * shape sent back in `POST /sessions/:id/messages` bodies.
 */
@Serializable
data class AttachmentMetadata(
    val id: String,
    val filename: String,
    val mimeType: String,
    val size: Long,
    val path: String,
    val previewUrl: String? = null,
)
