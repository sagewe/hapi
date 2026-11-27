package app.hapi.protocol.wire

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * Live streaming SSE frames from `GET /v1/sessions/{id}/stream` (Reins Native v1 Phase B).
 *
 * Each SSE frame is delivered on default `data:` lines with a JSON `type` discriminator.
 * Unknown or malformed frames degrade to [Unknown] instead of throwing.
 */
sealed interface SessionStreamEvent {
    data object Connected : SessionStreamEvent

    data class TextDelta(
        val turnId: String,
        val segmentId: String? = null,
        val delta: String,
    ) : SessionStreamEvent

    data class ThinkingDelta(
        val turnId: String,
        val segmentId: String? = null,
        val delta: String,
    ) : SessionStreamEvent

    data class TurnDone(
        val turnId: String,
        val aborted: Boolean = false,
    ) : SessionStreamEvent

    data class Error(
        val turnId: String? = null,
        val message: String,
        val resync: Boolean = false,
    ) : SessionStreamEvent

    /** Synthetic client-side signal emitted when the `/stream` SSE transport closes or fails. */
    data object Disconnected : SessionStreamEvent

    data class Unknown(val type: String?) : SessionStreamEvent
}

object SessionStreamEvents {
    fun parse(json: String): SessionStreamEvent {
        val element = try {
            HapiJson.parseToJsonElement(json)
        } catch (_: Exception) {
            return SessionStreamEvent.Unknown(type = null)
        }
        return parse(element)
    }

    fun parse(element: JsonElement): SessionStreamEvent {
        val obj = element as? JsonObject ?: return SessionStreamEvent.Unknown(type = null)
        val type = obj["type"].stringOrNull ?: return SessionStreamEvent.Unknown(type = null)
        return when (type) {
            "connected" -> SessionStreamEvent.Connected
            "text_delta" -> {
                val turnId = obj["turnId"].stringOrNull ?: obj["turn_id"].stringOrNull ?: return SessionStreamEvent.Unknown(type)
                val delta = obj["delta"].stringOrNull ?: return SessionStreamEvent.Unknown(type)
                val segmentId = obj["segmentId"].stringOrNull ?: obj["segment_id"].stringOrNull
                SessionStreamEvent.TextDelta(turnId = turnId, segmentId = segmentId, delta = delta)
            }
            "thinking_delta" -> {
                val turnId = obj["turnId"].stringOrNull ?: obj["turn_id"].stringOrNull ?: return SessionStreamEvent.Unknown(type)
                val delta = obj["delta"].stringOrNull ?: return SessionStreamEvent.Unknown(type)
                val segmentId = obj["segmentId"].stringOrNull ?: obj["segment_id"].stringOrNull
                SessionStreamEvent.ThinkingDelta(turnId = turnId, segmentId = segmentId, delta = delta)
            }
            "turn_done" -> {
                val turnId = obj["turnId"].stringOrNull ?: obj["turn_id"].stringOrNull ?: return SessionStreamEvent.Unknown(type)
                val aborted = obj["aborted"].boolOrNull ?: false
                SessionStreamEvent.TurnDone(turnId = turnId, aborted = aborted)
            }
            "error" -> {
                val turnId = obj["turnId"].stringOrNull ?: obj["turn_id"].stringOrNull
                val message = obj["message"].stringOrNull ?: "Stream error"
                val resync = obj["resync"].boolOrNull ?: false
                SessionStreamEvent.Error(turnId = turnId, message = message, resync = resync)
            }
            else -> SessionStreamEvent.Unknown(type)
        }
    }
}
