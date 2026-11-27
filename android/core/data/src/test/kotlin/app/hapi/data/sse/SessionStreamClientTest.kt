package app.hapi.data.sse

import app.hapi.protocol.wire.SessionStreamEvent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest

class SessionStreamClientTest {

    @Test
    fun `builds encoded session stream url`() {
        val url = buildSessionStreamUrl(
            baseUrl = "https://hub.test/",
            sessionId = "sess 1",
            token = "jwt+tok",
        )
        assertEquals("https://hub.test/v1/sessions/sess+1/stream?token=jwt%2Btok", url)
    }

    @Test
    fun `emits stream events and force-refreshes token after 401`() = runTest {
        var attempt = 0
        val refreshFlags = mutableListOf<Boolean>()
        val tokenProvider = object : SseTokenProvider {
            override suspend fun freshToken(forceRefresh: Boolean): String {
                refreshFlags.add(forceRefresh)
                return if (forceRefresh) "jwt-2" else "jwt-1"
            }
        }
        val transport = object : SseTransport {
            override fun open(url: String, lastEventId: String?): Flow<TransportEvent> {
                attempt += 1
                return if (attempt == 1) {
                    flowOf(TransportEvent.Failure(code = 401))
                } else {
                    flowOf(
                        TransportEvent.Connected,
                        TransportEvent.Event(SseRawEvent(null, """{"type":"text_delta","turnId":"t1","segmentId":"s1","delta":"hi"}""")),
                        TransportEvent.Event(SseRawEvent(null, """{"type":"turn_done","turnId":"t1","aborted":false}""")),
                    )
                }
            }
        }

        val source = ReinsSessionStreamSource(
            baseUrl = "https://hub.test",
            transport = transport,
            tokenProvider = tokenProvider,
            initialBackoffMs = 1L,
            maxBackoffMs = 5L,
        )

        val events = source.stream("sess-1").take(4).toList()
        assertEquals(listOf(false, true), refreshFlags)
        assertEquals(
            listOf(
                SessionStreamEvent.Connected,
                SessionStreamEvent.TextDelta(turnId = "t1", segmentId = "s1", delta = "hi"),
                SessionStreamEvent.TurnDone(turnId = "t1", aborted = false),
                SessionStreamEvent.Disconnected,
            ),
            events,
        )
    }
}
