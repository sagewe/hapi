package app.hapi.protocol.wire

import app.hapi.protocol.chat.AgentReasoningBlock
import app.hapi.protocol.chat.AgentTextBlock
import app.hapi.protocol.chat.NormalizedMessage
import app.hapi.protocol.chat.SessionStreamBuffer
import app.hapi.protocol.chat.normalizeDecryptedMessage
import app.hapi.protocol.chat.reduceChatBlocks
import app.hapi.protocol.window.MessageMerge
import app.hapi.protocol.window.asWindowMessage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ReinsPhaseBTest {

    @Test
    fun `assistant meta usage and model flow into UsageData and LatestUsage`() {
        val raw = """{
            "id":"msg-usage-1","seq":10,"role":"assistant","created_at":1700000001000,
            "blocks":[{"type":"text","text":"Done analyzing."}],
            "meta":{
                "model":"claude-sonnet-4-6",
                "usage":{
                    "input_tokens":12000,
                    "output_tokens":450,
                    "cache_creation_input_tokens":3000,
                    "cache_read_input_tokens":45000,
                    "context_tokens":60000,
                    "context_window":200000,
                    "service_tier":"standard"
                }
            }
        }"""
        val msg = HapiJson.decodeFromString<DecryptedMessage>(raw)
        val normalized = assertIs<NormalizedMessage.Agent>(normalizeDecryptedMessage(msg))
        assertEquals("claude-sonnet-4-6", normalized.model)
        val usage = assertNotNull(normalized.usage)
        assertEquals(12000.0, usage.inputTokens)
        assertEquals(450.0, usage.outputTokens)
        assertEquals(3000.0, usage.cacheCreationInputTokens)
        assertEquals(45000.0, usage.cacheReadInputTokens)
        assertEquals(60000.0, usage.contextTokens)
        assertEquals(200000.0, usage.contextWindow)
        assertEquals("standard", usage.serviceTier)

        val reduced = reduceChatBlocks(listOf(normalized), null)
        val latest = assertNotNull(reduced.latestUsage)
        assertEquals(60000.0, latest.contextSize)
        assertEquals(200000.0, latest.contextWindow)
        assertEquals(45000.0, latest.cacheRead)
        assertEquals("claude-sonnet-4-6", latest.model)
    }

    @Test
    fun `session stream event parser handles all Phase B frames without throwing`() {
        assertEquals(SessionStreamEvent.Connected, SessionStreamEvents.parse("""{"type":"connected"}"""))
        assertEquals(
            SessionStreamEvent.TextDelta(turnId = "t1", segmentId = "seg-1", delta = "Hello "),
            SessionStreamEvents.parse("""{"type":"text_delta","turnId":"t1","segmentId":"seg-1","delta":"Hello "}"""),
        )
        assertEquals(
            SessionStreamEvent.ThinkingDelta(turnId = "t1", segmentId = null, delta = "Hmm"),
            SessionStreamEvents.parse("""{"type":"thinking_delta","turn_id":"t1","delta":"Hmm"}"""),
        )
        assertEquals(
            SessionStreamEvent.TurnDone(turnId = "t1", aborted = true),
            SessionStreamEvents.parse("""{"type":"turn_done","turnId":"t1","aborted":true}"""),
        )
        assertEquals(
            SessionStreamEvent.Error(turnId = "t1", message = "lagged", resync = true),
            SessionStreamEvents.parse("""{"type":"error","turnId":"t1","message":"lagged","resync":true}"""),
        )
        assertIs<SessionStreamEvent.Unknown>(SessionStreamEvents.parse("not-json"))
        assertIs<SessionStreamEvent.Unknown>(SessionStreamEvents.parse("""{"type":"tool_use"}"""))
    }

    @Test
    fun `stream buffer accumulates deltas suppresses streaming upserts and drops cleanly when sealed`() {
        var buffer = SessionStreamBuffer()
            .apply(SessionStreamEvent.Connected, 1000L)
            .apply(SessionStreamEvent.ThinkingDelta("t1", "seg-1", "Thinking..."), 1001L)
            .apply(SessionStreamEvent.TextDelta("t1", "seg-1", "Hello "), 1002L)
            .apply(SessionStreamEvent.TextDelta("t1", "seg-1", "world!"), 1003L)

        val streamingUpsert = HapiJson.decodeFromString<DecryptedMessage>(
            """{
                "id":"m-stream","seq":5,"role":"assistant","created_at":1002,
                "blocks":[{"type":"text","text":"Hello "}],
                "meta":{"streaming":true,"segmentId":"seg-1"}
            }""",
        )
        assertTrue(streamingUpsert.isStreaming)
        assertEquals("seg-1", streamingUpsert.streamSegmentId)
        assertTrue(buffer.shouldSuppressPersisted(streamingUpsert))

        val overlay = buffer.overlayMessages(listOf(streamingUpsert))
        assertEquals(1, overlay.size)
        val reducedOverlay = reduceChatBlocks(overlay, null)
        assertEquals(2, reducedOverlay.blocks.size)
        assertEquals("Thinking...", assertIs<AgentReasoningBlock>(reducedOverlay.blocks[0]).text)
        assertEquals("Hello world!", assertIs<AgentTextBlock>(reducedOverlay.blocks[1]).text)

        // Sealed message arrives for seg-1 -> overlay is dropped so no duplicate bubbles appear.
        val sealedMsg = HapiJson.decodeFromString<DecryptedMessage>(
            """{
                "id":"m-stream","seq":5,"role":"assistant","created_at":1004,
                "blocks":[{"type":"text","text":"Hello world!"}],
                "meta":{"streaming":false,"segmentId":"seg-1"}
            }""",
        )
        assertFalse(sealedMsg.isStreaming)
        buffer = buffer.reconcileSealed(listOf(sealedMsg))
        assertFalse(buffer.hasActiveOverlay)
        assertEquals(emptyList(), buffer.overlayMessages(listOf(sealedMsg)))

        // Late delta for already-sealed segment must not resurrect the overlay.
        buffer = buffer.apply(SessionStreamEvent.TextDelta("t1", "seg-1", "late"), 1005L)
        assertFalse(buffer.hasActiveOverlay)
    }

    @Test
    fun `stream buffer clears turn on turn_done and falls back on disconnect`() {
        var buffer = SessionStreamBuffer()
            .apply(SessionStreamEvent.Connected, 1000L)
            .apply(SessionStreamEvent.TextDelta("t1", null, "Part 1"), 1001L)
            .apply(SessionStreamEvent.TextDelta("t2", null, "Part 2"), 1002L)
        assertEquals(2, buffer.segments.size)

        buffer = buffer.apply(SessionStreamEvent.TurnDone("t1", aborted = false), 1003L)
        assertEquals(1, buffer.segments.size)
        assertTrue(buffer.segments.keys.single().turnId == "t2")

        buffer = buffer.apply(SessionStreamEvent.Disconnected, 1004L)
        assertFalse(buffer.connected)
        assertFalse(buffer.hasActiveOverlay)
    }

    @Test
    fun `phase A in-place StoredMessage id upsert replaces existing row without duplicating`() {
        val initial = HapiJson.decodeFromString<DecryptedMessage>(
            """{"id":"m-1","seq":1,"role":"assistant","created_at":1000,"blocks":[{"type":"text","text":"Hel"}],"meta":{"streaming":true}}""",
        ).asWindowMessage()
        val updated = HapiJson.decodeFromString<DecryptedMessage>(
            """{"id":"m-1","seq":1,"role":"assistant","created_at":1000,"blocks":[{"type":"text","text":"Hello world"}],"meta":{"streaming":false}}""",
        ).asWindowMessage()

        val merged = MessageMerge.mergeMessages(listOf(initial), listOf(updated))
        assertEquals(1, merged.size)
        assertFalse(merged.single().wire.isStreaming)
        val norm = assertIs<NormalizedMessage.Agent>(normalizeDecryptedMessage(merged.single().wire))
        val reduced = reduceChatBlocks(listOf(norm), null)
        assertEquals("Hello world", assertIs<AgentTextBlock>(reduced.blocks.single()).text)
    }

    @Test
    fun `v1 session decodes steeringActive and agySessionProtocol and queue responses`() {
        val rawSession = """{
            "id":"s-agy","namespace":"default","machine_id":"m1","agent":"agy",
            "directory":"/repo","status":"thinking","archived":false,
            "meta_rev":2,"state_rev":5,"content_rev":3,"read_rev":3,"read_state_ver":1,"manual_unread":false,
            "pending_requests":{"steeringActive":true},
            "metadata":{"agySessionProtocol":"acp","host":"mac"},
            "created_at":1000,"updated_at":2000,"seq":1,"message_count":1
        }"""
        val sess = HapiJson.decodeFromString<Session>(rawSession)
        assertEquals(true, sess.agentState?.steeringActive)
        assertEquals("acp", sess.metadata?.agySessionProtocol)

        val queued = HapiJson.decodeFromString<QueuedStateResponse>(
            """{
                "queued_local_ids":["l1"],
                "indeterminate_local_ids":["l2"],
                "dispatching_local_ids":["l3"],
                "invoked_local_messages":[{"local_id":"l4","invoked_at":1700000000123}]
            }""",
        )
        assertEquals(listOf("l1"), queued.queuedLocalIds)
        assertEquals(listOf("l2"), queued.indeterminateLocalIds)
        assertEquals(listOf("l3"), queued.dispatchingLocalIds)
        assertEquals("l4", queued.invokedLocalMessages.single().localId)
        assertEquals(1700000000123L, queued.invokedLocalMessages.single().invokedAt)

        val cancel = HapiJson.decodeFromString<CancelMessageResponse>("""{"status":"cancelled","local_id":"l1"}""")
        assertEquals("cancelled", cancel.status)
        assertEquals("l1", cancel.localId)
        assertNull(cancel.message)

        val steer = HapiJson.decodeFromString<SteerQueuedMessageResponse>("""{"status":"steered","local_id":"l1"}""")
        assertEquals("steered", steer.status)
        assertEquals("l1", steer.localId)
    }
}
