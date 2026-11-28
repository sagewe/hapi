package app.hapi.protocol.chat

import app.hapi.protocol.wire.DecryptedMessage
import app.hapi.protocol.wire.SessionStreamEvent
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Pure immutable state machine for live token deltas arriving on
 * `GET /v1/sessions/{id}/stream` (Reins Native v1 Phase B).
 *
 * Deltas are accumulated per `(turnId, segmentId ?: turnId)` and reconciled
 * against persisted `message_received` rows:
 * - Only persisted `meta.streaming == true` rows whose `streamSegmentId` is
 *   actively covered by `/stream` (with at least as much accumulated content)
 *   are suppressed, so concurrent streaming rows (e.g. thinking + text) are
 *   never hidden.
 * - Any `streamSegmentId` already streaming in Phase A when `/stream` connects
 *   (recorded in [preExistingStreamingSegmentIds]) stays Phase-A-authoritative
 *   until sealed or `turn_done`, preventing mid-turn join prefix truncation
 *   even during fast bursts inside an 800ms Phase A throttle window.
 * - When a sealed message (`meta.streaming` absent/false) carrying
 *   `meta.segmentId` lands in the window, or when `turn_done` arrives, the
 *   corresponding live overlay segment is dropped cleanly.
 */
data class LiveStreamSegmentKey(
    val turnId: String,
    val segmentId: String,
)

data class LiveStreamSegment(
    val turnId: String,
    val segmentId: String,
    val hasExplicitSegmentId: Boolean = true,
    val text: String = "",
    val thinking: String = "",
    val createdAt: Long,
) {
    val totalLength: Int get() = text.length + thinking.length

    fun toNormalizedAgent(): NormalizedMessage.Agent? {
        val content = buildList<NormalizedAgentContent> {
            if (thinking.isNotEmpty()) {
                add(
                    NormalizedAgentContent.Reasoning(
                        text = thinking,
                        uuid = "stream:$turnId:$segmentId:thinking",
                        parentUUID = null,
                    ),
                )
            }
            if (text.isNotEmpty()) {
                add(
                    NormalizedAgentContent.Text(
                        text = text,
                        uuid = "stream:$turnId:$segmentId:text",
                        parentUUID = null,
                    ),
                )
            }
        }
        if (content.isEmpty()) return null
        return NormalizedMessage.Agent(
            id = "stream:$turnId:$segmentId",
            localId = null,
            createdAt = createdAt,
            isSidechain = false,
            content = content,
        )
    }
}

data class SessionStreamBuffer(
    val connected: Boolean = false,
    val segments: Map<LiveStreamSegmentKey, LiveStreamSegment> = emptyMap(),
    val sealedSegmentIds: Set<String> = emptySet(),
    val preExistingStreamingSegmentIds: Set<String> = emptySet(),
    internal val awaitingInitialWindowSnapshot: Boolean = false,
) {
    val hasActiveOverlay: Boolean get() = segments.isNotEmpty()

    fun apply(
        event: SessionStreamEvent,
        nowMs: Long,
        persistedMessages: List<DecryptedMessage> = emptyList(),
    ): SessionStreamBuffer = when (event) {
        is SessionStreamEvent.Connected -> {
            if (connected) {
                this
            } else {
                val preExisting = LinkedHashSet<String>()
                for (msg in persistedMessages) {
                    if (!msg.isStreaming) continue
                    val segId = msg.streamSegmentId ?: continue
                    if (segId !in sealedSegmentIds) {
                        preExisting.add(segId)
                    }
                }
                val remaining = if (preExisting.isEmpty()) {
                    segments
                } else {
                    segments.filterValues { !(it.hasExplicitSegmentId && it.segmentId in preExisting) }
                }
                copy(
                    connected = true,
                    segments = remaining,
                    preExistingStreamingSegmentIds = preExisting,
                    awaitingInitialWindowSnapshot = persistedMessages.isEmpty(),
                )
            }
        }
        is SessionStreamEvent.Disconnected -> copy(
            connected = false,
            segments = emptyMap(),
            preExistingStreamingSegmentIds = emptySet(),
            awaitingInitialWindowSnapshot = false,
        )
        is SessionStreamEvent.TextDelta -> appendDelta(
            turnId = event.turnId,
            rawSegmentId = event.segmentId,
            textDelta = event.delta,
            thinkingDelta = null,
            nowMs = nowMs,
        )
        is SessionStreamEvent.ThinkingDelta -> appendDelta(
            turnId = event.turnId,
            rawSegmentId = event.segmentId,
            textDelta = null,
            thinkingDelta = event.delta,
            nowMs = nowMs,
        )
        is SessionStreamEvent.TurnDone -> {
            val remaining = segments.filterKeys { it.turnId != event.turnId }
            if (remaining.size == segments.size && preExistingStreamingSegmentIds.isEmpty()) {
                this
            } else {
                copy(segments = remaining, preExistingStreamingSegmentIds = emptySet())
            }
        }
        is SessionStreamEvent.Error -> {
            val remaining = if (event.turnId != null) {
                segments.filterKeys { it.turnId != event.turnId }
            } else {
                emptyMap()
            }
            copy(segments = remaining)
        }
        is SessionStreamEvent.Unknown -> this
    }

    /**
     * Drop any live overlay segment whose `segmentId` has been sealed by a
     * persisted non-streaming message in the window, clear sealed IDs from
     * [preExistingStreamingSegmentIds], and capture mid-turn pre-existing
     * streaming rows if the initial window landed after `/stream` connected.
     */
    fun reconcileSealed(messages: List<DecryptedMessage>): SessionStreamBuffer {
        var nextSealed: MutableSet<String>? = null
        val sealedInWindow = HashSet<String>()
        for (msg in messages) {
            if (msg.isStreaming) continue
            val segId = msg.streamSegmentId ?: continue
            sealedInWindow.add(segId)
            if (segId !in sealedSegmentIds) {
                if (nextSealed == null) nextSealed = LinkedHashSet(sealedSegmentIds)
                nextSealed.add(segId)
            }
        }
        val updatedSealed = if (nextSealed != null) {
            if (nextSealed.size > MAX_SEALED_HISTORY) {
                LinkedHashSet(nextSealed.toList().takeLast(MAX_SEALED_HISTORY))
            } else {
                nextSealed
            }
        } else {
            sealedSegmentIds
        }

        var nextPreExisting: MutableSet<String>? = null
        if (preExistingStreamingSegmentIds.isNotEmpty() && sealedInWindow.isNotEmpty()) {
            for (segId in sealedInWindow) {
                if (segId in preExistingStreamingSegmentIds) {
                    if (nextPreExisting == null) nextPreExisting = LinkedHashSet(preExistingStreamingSegmentIds)
                    nextPreExisting.remove(segId)
                }
            }
        }

        if (connected && messages.isNotEmpty()) {
            for (msg in messages) {
                if (!msg.isStreaming) continue
                val segId = msg.streamSegmentId ?: continue
                if (segId in updatedSealed) continue
                val currentPreExisting = nextPreExisting ?: preExistingStreamingSegmentIds
                if (segId in currentPreExisting) continue
                val live = segments.values.firstOrNull { it.hasExplicitSegmentId && it.segmentId == segId }
                val persistedLen = assistantContentLength(msg)
                val shouldProtect = if (awaitingInitialWindowSnapshot) {
                    live == null || persistedLen > live.totalLength
                } else {
                    live != null && persistedLen > live.totalLength
                }
                if (shouldProtect) {
                    if (nextPreExisting == null) nextPreExisting = LinkedHashSet(preExistingStreamingSegmentIds)
                    nextPreExisting.add(segId)
                }
            }
        }

        val updatedPreExisting = nextPreExisting ?: preExistingStreamingSegmentIds
        val nextAwaiting = if (awaitingInitialWindowSnapshot && messages.isNotEmpty()) {
            false
        } else {
            awaitingInitialWindowSnapshot
        }
        val remaining = segments.filterValues { seg ->
            if (seg.segmentId in updatedSealed) {
                false
            } else if (seg.hasExplicitSegmentId && seg.segmentId in updatedPreExisting) {
                false
            } else {
                true
            }
        }
        if (
            updatedSealed === sealedSegmentIds &&
            updatedPreExisting === preExistingStreamingSegmentIds &&
            nextAwaiting == awaitingInitialWindowSnapshot &&
            remaining.size == segments.size
        ) {
            return this
        }
        return copy(
            segments = remaining,
            sealedSegmentIds = updatedSealed,
            preExistingStreamingSegmentIds = updatedPreExisting,
            awaitingInitialWindowSnapshot = nextAwaiting,
        )
    }

    /**
     * Whether a persisted window message should be suppressed in favor of the
     * active `/stream` overlay.
     *
     * Never suppresses globally without matching `streamSegmentId` (so
     * concurrent streaming thinking/text rows are never hidden) and never
     * suppresses mid-turn pre-existing segments or segments whose Phase A
     * snapshot carries a longer accumulated prefix than `/stream`.
     */
    fun shouldSuppressPersisted(message: DecryptedMessage): Boolean {
        if (!connected || !message.isStreaming) return false
        val segId = message.streamSegmentId
        if (segId != null) {
            if (segId in preExistingStreamingSegmentIds) return false
            if (segId in sealedSegmentIds) return true
            val live = segments.values.firstOrNull { it.hasExplicitSegmentId && it.segmentId == segId }
                ?: return false
            if (live.totalLength == 0) return false
            if (assistantContentLength(message) > live.totalLength) return false
            return true
        }
        val unkeyedLive = segments.values.firstOrNull { !it.hasExplicitSegmentId && it.totalLength > 0 }
            ?: return false
        if (assistantContentLength(message) > unkeyedLive.totalLength) return false
        return true
    }

    /**
     * Active live overlay messages to append to the normalized chat stream,
     * skipping any segment already sealed by [persistedMessages], protected as
     * a mid-turn pre-existing segment, or shorter than its persisted Phase A
     * streaming snapshot.
     */
    fun overlayMessages(persistedMessages: List<DecryptedMessage>): List<NormalizedMessage.Agent> {
        if (!connected || segments.isEmpty()) return emptyList()
        val sealedNow = HashSet<String>(sealedSegmentIds.size + 8)
        sealedNow.addAll(sealedSegmentIds)
        val persistedStreamingLenBySegId = HashMap<String, Int>()
        var maxUnsegmentedStreamingLen = 0
        for (msg in persistedMessages) {
            if (!msg.isStreaming) {
                msg.streamSegmentId?.let(sealedNow::add)
            } else {
                val len = assistantContentLength(msg)
                val segId = msg.streamSegmentId
                if (segId != null) {
                    val prev = persistedStreamingLenBySegId[segId] ?: 0
                    if (len > prev) persistedStreamingLenBySegId[segId] = len
                } else if (len > maxUnsegmentedStreamingLen) {
                    maxUnsegmentedStreamingLen = len
                }
            }
        }
        return segments.values.mapNotNull { seg ->
            if (seg.hasExplicitSegmentId) {
                if (seg.segmentId in sealedNow || seg.segmentId in preExistingStreamingSegmentIds) {
                    return@mapNotNull null
                }
                val persistedLen = persistedStreamingLenBySegId[seg.segmentId] ?: 0
                if (persistedLen > seg.totalLength) {
                    return@mapNotNull null
                }
            } else if (maxUnsegmentedStreamingLen > seg.totalLength) {
                return@mapNotNull null
            }
            seg.toNormalizedAgent()
        }
    }

    private fun appendDelta(
        turnId: String,
        rawSegmentId: String?,
        textDelta: String?,
        thinkingDelta: String?,
        nowMs: Long,
    ): SessionStreamBuffer {
        if (textDelta.isNullOrEmpty() && thinkingDelta.isNullOrEmpty()) return this
        val hasExplicitSegmentId = !rawSegmentId.isNullOrEmpty()
        val segmentId = if (hasExplicitSegmentId) rawSegmentId!! else turnId
        if (segmentId in sealedSegmentIds) return this
        if (hasExplicitSegmentId && segmentId in preExistingStreamingSegmentIds) return this
        val key = LiveStreamSegmentKey(turnId = turnId, segmentId = segmentId)
        val existing = segments[key]
        val updated = if (existing != null) {
            existing.copy(
                text = if (textDelta != null) existing.text + textDelta else existing.text,
                thinking = if (thinkingDelta != null) existing.thinking + thinkingDelta else existing.thinking,
            )
        } else {
            LiveStreamSegment(
                turnId = turnId,
                segmentId = segmentId,
                hasExplicitSegmentId = hasExplicitSegmentId,
                text = textDelta ?: "",
                thinking = thinkingDelta ?: "",
                createdAt = nowMs,
            )
        }
        val next = LinkedHashMap<LiveStreamSegmentKey, LiveStreamSegment>(segments.size + 1)
        next.putAll(segments)
        next[key] = updated
        return copy(connected = true, segments = next)
    }

    private companion object {
        const val MAX_SEALED_HISTORY = 64

        fun assistantContentLength(message: DecryptedMessage): Int {
            val root = message.content as? JsonObject ?: return 0
            val outerContent = root["content"] as? JsonObject ?: return 0
            val data = outerContent["data"] as? JsonObject ?: return 0
            val innerMessage = data["message"] as? JsonObject ?: return 0
            val blocks = innerMessage["content"] as? JsonArray ?: return 0
            var total = 0
            for (element in blocks) {
                val blk = element as? JsonObject ?: continue
                val text = (blk["text"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                if (text != null) total += text.length
                val thinking = (blk["thinking"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                if (thinking != null) total += thinking.length
            }
            return total
        }
    }
}
