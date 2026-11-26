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
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

@Serializable
data class SessionReadState(
    val readRevision: Long = 0,
    val manualUnread: Boolean = false,
    val version: Long = 0,
) {
    companion object {
        fun merge(current: SessionReadState?, incoming: SessionReadState?): SessionReadState? {
            if (incoming == null) return current
            if (current == null) return incoming
            val newest = if (incoming.version > current.version) incoming else current
            return newest.copy(readRevision = maxOf(current.readRevision, incoming.readRevision))
        }
    }
}

@Serializable
data class SessionReadStateRequest(
    val type: String,
    val readRevision: Long? = null,
    val expectedVersion: Long,
    val manualUnread: Boolean? = null,
)

@Serializable(with = SessionReadStateResponseSerializer::class)
data class SessionReadStateResponse(val readState: SessionReadState, val contentRevision: Long)

internal object SessionReadStateResponseSerializer : KSerializer<SessionReadStateResponse> {
    override val descriptor: SerialDescriptor =
        SerialDescriptor("app.hapi.protocol.wire.SessionReadStateResponse", JsonObject.serializer().descriptor)

    override fun deserialize(decoder: Decoder): SessionReadStateResponse {
        val input = decoder as? JsonDecoder
            ?: throw SerializationException("SessionReadStateResponse supports JSON only")
        val obj = input.decodeJsonElement() as? JsonObject
            ?: throw SerializationException("SessionReadStateResponse must be a JSON object")
        val nested = obj["readState"] as? JsonObject
        val contentRevision = obj["contentRevision"].longOrNull ?: obj["content_revision"].longOrNull ?: 0L
        val readState = if (nested != null) {
            HapiJson.decodeFromJsonElement(SessionReadState.serializer(), nested)
        } else {
            SessionReadState(
                readRevision = obj["readRevision"].longOrNull ?: obj["read_revision"].longOrNull ?: 0L,
                manualUnread = obj["manualUnread"].boolOrNull ?: obj["manual_unread"].boolOrNull ?: false,
                version = obj["readStateVersion"].longOrNull
                    ?: obj["read_state_version"].longOrNull
                    ?: obj["version"].longOrNull
                    ?: 0L,
            )
        }
        return SessionReadStateResponse(readState = readState, contentRevision = contentRevision)
    }

    override fun serialize(encoder: Encoder, value: SessionReadStateResponse) {
        val output = encoder as? JsonEncoder
            ?: throw SerializationException("SessionReadStateResponse supports JSON only")
        output.encodeJsonElement(buildJsonObject {
            put("readState", HapiJson.encodeToJsonElement(SessionReadState.serializer(), value.readState))
            put("contentRevision", JsonPrimitive(value.contentRevision))
        })
    }
}
