package app.hapi.data.sse

import app.hapi.protocol.wire.SessionStreamEvent
import app.hapi.protocol.wire.SessionStreamEvents
import java.net.URLEncoder
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.isActive

/**
 * Per-session live token stream (`GET /v1/sessions/{id}/stream`).
 *
 * Collecting opens the SSE stream and emits parsed [SessionStreamEvent] frames;
 * cancelling tears down the underlying connection immediately.
 */
interface SessionStreamSource {
    fun stream(sessionId: String): Flow<SessionStreamEvent>
}

/**
 * Builds `GET {base}/v1/sessions/{sessionId}/stream?token=...`.
 */
fun buildSessionStreamUrl(
    baseUrl: String,
    sessionId: String,
    token: String,
): String {
    val encodedSession = URLEncoder.encode(sessionId, Charsets.UTF_8.name())
    val encodedToken = URLEncoder.encode(token, Charsets.UTF_8.name())
    return "${baseUrl.trimEnd('/')}/v1/sessions/$encodedSession/stream?token=$encodedToken"
}

/**
 * Reconnecting SSE client for `GET /v1/sessions/{id}/stream`.
 *
 * Uses the same [SseTransport] (`OkHttpSseTransport`) and [SseTokenProvider]
 * as [SseEngine]. On 401 it force-refreshes the JWT; on transient failure or
 * server EOF it emits [SessionStreamEvent.Disconnected] so the UI falls back
 * to persisted Phase A upserts while backing off exponentially.
 */
class ReinsSessionStreamSource(
    private val baseUrl: String,
    private val transport: SseTransport,
    private val tokenProvider: SseTokenProvider,
    private val initialBackoffMs: Long = 1_000L,
    private val maxBackoffMs: Long = 15_000L,
) : SessionStreamSource {

    override fun stream(sessionId: String): Flow<SessionStreamEvent> = flow {
        var backoffMs = initialBackoffMs
        var forceRefresh = false

        while (currentCoroutineContext().isActive) {
            val token = try {
                tokenProvider.freshToken(forceRefresh)
            } catch (_: Exception) {
                null
            }
            forceRefresh = false

            if (token.isNullOrBlank()) {
                emit(SessionStreamEvent.Disconnected)
                delay(backoffMs)
                backoffMs = (backoffMs * 2).coerceAtMost(maxBackoffMs)
                continue
            }

            val url = buildSessionStreamUrl(baseUrl, sessionId, token)
            var got401 = false
            var connectedThisAttempt = false

            transport.open(url, lastEventId = null).collect { transportEvent ->
                when (transportEvent) {
                    is TransportEvent.Connected -> {
                        connectedThisAttempt = true
                        backoffMs = initialBackoffMs
                        emit(SessionStreamEvent.Connected)
                    }
                    is TransportEvent.Event -> {
                        val parsed = SessionStreamEvents.parse(transportEvent.event.data)
                        if (parsed !is SessionStreamEvent.Unknown) {
                            emit(parsed)
                        }
                    }
                    is TransportEvent.Failure -> {
                        if (transportEvent.code == 401) {
                            got401 = true
                        }
                    }
                }
            }

            if (connectedThisAttempt) {
                emit(SessionStreamEvent.Disconnected)
            }

            if (got401) {
                forceRefresh = true
                delay(250L)
            } else {
                delay(backoffMs)
                backoffMs = (backoffMs * 2).coerceAtMost(maxBackoffMs)
            }
        }
    }
}
