package app.hapi.protocol.chat

import app.hapi.protocol.wire.DecryptedMessage
import app.hapi.protocol.wire.SessionStreamEvent

/**
 * Pure immutable state machine for live token deltas arriving on
 * `GET /v1/sessions/{id}/stream` (Reins Native v1 Phase B).
 *
 * Deltas are accumulated per `(turnId, segmentId ?: turnId)` and reconciled
 * against persisted `message_received` rows:
 * - While `/stream` has active live segments, Phase A `meta.streaming == true`
 *   upserts are suppressed so the user never sees duplicate assistant bubbles.
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
    val text: String = "",
    val thinking: String = "",
    val createdAt: Long,
) {
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
) {
    val hasActiveOverlay: Boolean get() = segments.isNotEmpty()

    fun apply(event: SessionStreamEvent, nowMs: Long): SessionStreamBuffer = when (event) {
        is SessionStreamEvent.Connected -> copy(connected = true)
        is SessionStreamEvent.Disconnected -> copy(connected = false, segments = emptyMap())
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
            if (remaining.size == segments.size) this else copy(segments = remaining)
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
     * persisted non-streaming message in the window.
     */
    fun reconcileSealed(messages: List<DecryptedMessage>): SessionStreamBuffer {
        var nextSealed: MutableSet<String>? = null
        for (msg in messages) {
            if (msg.isStreaming) continue
            val segId = msg.streamSegmentId ?: continue
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
        val remaining = segments.filterKeys { it.segmentId !in updatedSealed }
        if (updatedSealed === sealedSegmentIds && remaining.size == segments.size) return this
        return copy(segments = remaining, sealedSegmentIds = updatedSealed)
    }

    /**
     * Whether a persisted window message should be suppressed in favor of the
     * active `/stream` overlay.
     */
    fun shouldSuppressPersisted(message: DecryptedMessage): Boolean =
        connected && hasActiveOverlay && message.isStreaming

    /**
     * Active live overlay messages to append to the normalized chat stream,
     * skipping any segment already sealed by [persistedMessages].
     */
    fun overlayMessages(persistedMessages: List<DecryptedMessage>): List<NormalizedMessage.Agent> {
        if (segments.isEmpty()) return emptyList()
        val sealedNow = HashSet<String>(sealedSegmentIds.size + 8)
        sealedNow.addAll(sealedSegmentIds)
        for (msg in persistedMessages) {
            if (!msg.isStreaming) {
                msg.streamSegmentId?.let(sealedNow::add)
            }
        }
        return segments.values.mapNotNull { seg ->
            if (seg.segmentId in sealedNow) null else seg.toNormalizedAgent()
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
        val segmentId = rawSegmentId ?: turnId
        if (segmentId in sealedSegmentIds) return this
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
    }
}
