package app.hapi.protocol.wire

import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNames
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/**
 * The SSE event union (`SyncEventSchema`, `shared/src/schemas.ts`;
 * `docs/api/client-contract/sse.md` — 13 types, discriminated on `type`).
 * Decode with [SyncEvents.parse]; there is no polymorphic serializer because
 * frames arrive one JSON document per SSE `data:` line and unknown /
 * malformed frames must degrade to [Unknown] instead of throwing.
 *
 * `session-updated` / `session-added` / `machine-updated` keep their `data`
 * raw: resolving full-object vs patch is the caller's job (full [Session] /
 * [Machine] via [HapiJson], patch via [SessionPatches.parse] /
 * [MachinePatches.parse], anything else → REST refetch fallback).
 */
sealed interface SyncEvent {
    val namespace: String?

    @Serializable
    data class SessionAdded(
        override val namespace: String? = null,
        val sessionId: String,
        val data: JsonElement? = null,
    ) : SyncEvent

    @Serializable
    data class SessionUpdated(
        override val namespace: String? = null,
        val sessionId: String,
        /** Full `Session` or `SessionPatch`; absent/unparseable ⇒ refetch. */
        val data: JsonElement? = null,
    ) : SyncEvent

    @Serializable
    data class SessionRemoved(
        override val namespace: String? = null,
        val sessionId: String,
    ) : SyncEvent

    @Serializable
    data class MessageReceived(
        override val namespace: String? = null,
        val sessionId: String,
        val message: DecryptedMessage,
    ) : SyncEvent

    /** History changed structurally (rewind/fork/import/clear): drop the window, tail-sync. */
    @Serializable
    data class MessagesInvalidated(
        override val namespace: String? = null,
        val sessionId: String,
    ) : SyncEvent

    @Serializable
    data class ScheduledMatured(
        override val namespace: String? = null,
        val sessionId: String,
    ) : SyncEvent

    @Serializable
    data class SessionEnded(
        override val namespace: String? = null,
        val sessionId: String,
        /** `'completed' | 'terminated' | 'error' | 'handoff' | 'cleared'`. */
        val reason: String? = null,
    ) : SyncEvent

    /**
     * Not `@Serializable`: built by hand in [SyncEvents.parse] because `data`
     * is tri-state — `Present(JsonNull)` = machine **removed**,
     * `Present(object)` = full `Machine` or `MachinePatch`, [OptionalField.Absent]
     * = refetch machines (`docs/api/client-contract/sse.md`). A nullable
     * `JsonElement?` property would collapse the first and last cases.
     */
    data class MachineUpdated(
        override val namespace: String? = null,
        val machineId: String,
        val data: OptionalField<JsonElement> = OptionalField.Absent,
    ) : SyncEvent

    @OptIn(ExperimentalSerializationApi::class)
    @Serializable
    data class Toast(
        override val namespace: String? = null,
        val data: Data,
    ) : SyncEvent {
        @OptIn(ExperimentalSerializationApi::class)
        @Serializable
        data class Data(
            val title: String,
            val body: String,
            @JsonNames("session_id")
            val sessionId: String,
            val url: String,
        )
    }

    /** The agent consumed queued user messages: stamp `invokedAt`, leave the queued bar. */
    @Serializable
    data class MessagesConsumed(
        override val namespace: String? = null,
        val sessionId: String,
        val localIds: List<String>,
        val invokedAt: Long,
    ) : SyncEvent

    @Serializable
    data class MessagesIndeterminate(
        override val namespace: String? = null,
        val sessionId: String,
        val localIds: List<String>,
    ) : SyncEvent

    @Serializable
    data class MessagesRequeued(
        override val namespace: String? = null,
        val sessionId: String,
        val localIds: List<String>,
    ) : SyncEvent

    @Serializable
    data class MessageCancelled(
        override val namespace: String? = null,
        val sessionId: String,
        val messageId: String,
        val localId: String? = null,
    ) : SyncEvent

    /** Staleness-watchdog food; carries no SSE `id`. */
    @Serializable
    data class Heartbeat(
        override val namespace: String? = null,
        val data: Data? = null,
    ) : SyncEvent {
        @Serializable
        data class Data(
            val timestamp: Long,
        )
    }

    /** Subscribe handshake; carries no SSE `id`. */
    @OptIn(ExperimentalSerializationApi::class)
    @Serializable
    data class ConnectionChanged(
        override val namespace: String? = null,
        val data: Data? = null,
    ) : SyncEvent {
        @OptIn(ExperimentalSerializationApi::class)
        @Serializable
        data class Data(
            val status: String,
            /** Needed for `POST /v1/visibility` reporting. */
            @JsonNames("subscription_id")
            val subscriptionId: String? = null,
            /** `'ok'` = replay is complete, skip resync; `'gap'`/absent = full REST resync. */
            val resume: String? = null,
        )
    }

    /**
     * Unrecognized `type`, or a known `type` whose payload failed to decode
     * (the web reference likewise drops frames failing `safeParse`). Callers
     * treat it as a no-op; [raw] is retained for diagnostics.
     */
    data class Unknown(
        val type: String?,
        val raw: JsonObject? = null,
    ) : SyncEvent {
        override val namespace: String? get() = raw?.get("namespace").stringOrNull
    }
}

object SyncEvents {
    /**
     * Total decode of one SSE `data:` payload. Never throws: invalid JSON,
     * non-object frames, unknown `type`s, and malformed known-type payloads
     * all become [SyncEvent.Unknown].
     */
    fun parse(json: String): SyncEvent {
        val element = try {
            HapiJson.parseToJsonElement(json)
        } catch (_: Exception) {
            return SyncEvent.Unknown(type = null, raw = null)
        }
        return parse(element)
    }

    fun parse(element: JsonElement): SyncEvent {
        val obj = element as? JsonObject ?: return SyncEvent.Unknown(type = null, raw = null)
        val type = obj["type"].stringOrNull ?: return SyncEvent.Unknown(type = null, raw = obj)
        return when (type) {
            "session_added", "session-added" -> parseSessionAdded(obj, type)
            "session_updated", "session-updated" -> parseSessionUpdated(obj, type)
            "session_removed", "session-removed" -> parseSessionRemoved(obj, type)
            "message_received", "message-received" -> parseMessageReceived(obj, type)
            "messages_invalidated", "messages-invalidated" -> parseSimpleSessionEvent(obj, type) { ns, sid ->
                SyncEvent.MessagesInvalidated(namespace = ns, sessionId = sid)
            }
            "scheduled_matured", "scheduled-matured" -> parseSimpleSessionEvent(obj, type) { ns, sid ->
                SyncEvent.ScheduledMatured(namespace = ns, sessionId = sid)
            }
            "session_ended", "session-ended" -> parseSessionEnded(obj, type)
            "machine_updated", "machine-updated" -> parseMachineUpdated(obj, type)
            "toast" -> decodeStrategy(obj, type, SyncEvent.Toast.serializer())
            "messages_consumed", "messages-consumed" -> decodeStrategy(obj, type, SyncEvent.MessagesConsumed.serializer())
            "messages_indeterminate", "messages-indeterminate" -> decodeStrategy(obj, type, SyncEvent.MessagesIndeterminate.serializer())
            "messages_requeued", "messages-requeued" -> decodeStrategy(obj, type, SyncEvent.MessagesRequeued.serializer())
            "message_cancelled", "message-cancelled" -> decodeStrategy(obj, type, SyncEvent.MessageCancelled.serializer())
            "heartbeat" -> decodeStrategy(obj, type, SyncEvent.Heartbeat.serializer())
            "connection_changed", "connection-changed" -> decodeStrategy(obj, type, SyncEvent.ConnectionChanged.serializer())
            else -> SyncEvent.Unknown(type = type, raw = obj)
        }
    }

    private fun decodeStrategy(
        obj: JsonObject,
        type: String,
        strategy: DeserializationStrategy<SyncEvent>,
    ): SyncEvent = try {
        HapiJson.decodeFromJsonElement(strategy, obj)
    } catch (_: Exception) {
        SyncEvent.Unknown(type = type, raw = obj)
    }

    private fun parseSessionAdded(obj: JsonObject, type: String): SyncEvent {
        val sessionId = obj["session_id"].stringOrNull ?: obj["sessionId"].stringOrNull
            ?: return SyncEvent.Unknown(type = type, raw = obj)
        return SyncEvent.SessionAdded(
            namespace = obj["namespace"].stringOrNull,
            sessionId = sessionId,
            data = obj["session"] ?: obj["data"],
        )
    }

    private fun parseSessionUpdated(obj: JsonObject, type: String): SyncEvent {
        val sessionId = obj["session_id"].stringOrNull ?: obj["sessionId"].stringOrNull
            ?: return SyncEvent.Unknown(type = type, raw = obj)
        return SyncEvent.SessionUpdated(
            namespace = obj["namespace"].stringOrNull,
            sessionId = sessionId,
            data = obj["session"] ?: obj["data"],
        )
    }

    private fun parseSessionRemoved(obj: JsonObject, type: String): SyncEvent {
        val sessionId = obj["session_id"].stringOrNull ?: obj["sessionId"].stringOrNull
            ?: return SyncEvent.Unknown(type = type, raw = obj)
        return SyncEvent.SessionRemoved(
            namespace = obj["namespace"].stringOrNull,
            sessionId = sessionId,
        )
    }

    private fun parseSessionEnded(obj: JsonObject, type: String): SyncEvent {
        val sessionId = obj["session_id"].stringOrNull ?: obj["sessionId"].stringOrNull
            ?: return SyncEvent.Unknown(type = type, raw = obj)
        val reasonElem = obj["reason"]
        val reason = when {
            reasonElem == null || reasonElem is JsonNull -> null
            reasonElem is JsonPrimitive && reasonElem.isString -> reasonElem.content
            else -> reasonElem.toString()
        }
        return SyncEvent.SessionEnded(
            namespace = obj["namespace"].stringOrNull,
            sessionId = sessionId,
            reason = reason,
        )
    }

    private fun parseMessageReceived(obj: JsonObject, type: String): SyncEvent {
        val sessionId = obj["session_id"].stringOrNull ?: obj["sessionId"].stringOrNull
            ?: return SyncEvent.Unknown(type = type, raw = obj)
        val messageElem = obj["message"] ?: return SyncEvent.Unknown(type = type, raw = obj)
        val message = try {
            HapiJson.decodeFromJsonElement(DecryptedMessage.serializer(), messageElem)
        } catch (_: Exception) {
            return SyncEvent.Unknown(type = type, raw = obj)
        }
        return SyncEvent.MessageReceived(
            namespace = obj["namespace"].stringOrNull,
            sessionId = sessionId,
            message = message,
        )
    }

    private inline fun parseSimpleSessionEvent(
        obj: JsonObject,
        type: String,
        factory: (String?, String) -> SyncEvent,
    ): SyncEvent {
        val sessionId = obj["session_id"].stringOrNull ?: obj["sessionId"].stringOrNull
            ?: return SyncEvent.Unknown(type = type, raw = obj)
        return factory(obj["namespace"].stringOrNull, sessionId)
    }

    private fun parseMachineUpdated(obj: JsonObject, type: String): SyncEvent {
        val machineId = obj["machine_id"].stringOrNull ?: obj["machineId"].stringOrNull
            ?: return SyncEvent.Unknown(type = type, raw = obj)
        val data: OptionalField<JsonElement> = when {
            obj.containsKey("data") -> OptionalField.Present(obj.getValue("data"))
            obj.containsKey("machine") -> {
                val m = obj.getValue("machine")
                if (m !is JsonNull) {
                    OptionalField.Present(m)
                } else {
                    val active = obj["active"].boolOrNull
                    val updatedAt = obj["updated_at"].longOrNull
                    if (active != null || updatedAt != null) {
                        OptionalField.Present(buildJsonObject {
                            active?.let { put("active", JsonPrimitive(it)) }
                            updatedAt?.let {
                                put("activeAt", JsonPrimitive(it))
                                put("updatedAt", JsonPrimitive(it))
                            }
                        })
                    } else {
                        OptionalField.Present(JsonNull)
                    }
                }
            }
            obj.containsKey("active") || obj.containsKey("updated_at") -> {
                OptionalField.Present(buildJsonObject {
                    obj["active"].boolOrNull?.let { put("active", JsonPrimitive(it)) }
                    obj["updated_at"].longOrNull?.let {
                        put("activeAt", JsonPrimitive(it))
                        put("updatedAt", JsonPrimitive(it))
                    }
                })
            }
            else -> OptionalField.Absent
        }
        return SyncEvent.MachineUpdated(
            namespace = obj["namespace"].stringOrNull,
            machineId = machineId,
            data = data,
        )
    }
}
