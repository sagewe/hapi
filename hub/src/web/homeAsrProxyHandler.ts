import type { ServerWebSocket } from 'bun'

type WebSocketCtor = new (url: string, opts?: unknown) => HomeAsrUpstreamWebSocket

export interface HomeAsrUpstreamWebSocket {
    readyState: number
    send(data: string | ArrayBuffer | Uint8Array): void
    close(code?: number, reason?: string): void
    onopen: (() => void) | null
    onmessage: ((event: { data: string | ArrayBuffer | Uint8Array }) => void) | null
    onerror: ((event: unknown) => void) | null
    onclose: ((event: { code: number; reason: string }) => void) | null
}

export interface HomeAsrProxyData {
    _homeAsrProxy: true
    wsOrigin: string
    token: string
    sampleRate: number
    model?: string
}

export interface HomeAsrProxyHandler {
    open(clientWs: ServerWebSocket<unknown>): void
    message(clientWs: ServerWebSocket<unknown>, message: string | ArrayBuffer | Uint8Array): void
    close(clientWs: ServerWebSocket<unknown>, code: number, reason: string): void
}

const WS_OPEN = 1
const MAX_PENDING_BYTES = 1024 * 1024 // 1 MiB (~32s of 16 kHz 16-bit mono PCM)

function toClientCloseCode(code: number): number {
    return code >= 1000 && code <= 4999 && code !== 1005 && code !== 1006 && code !== 1015
        ? code
        : 1011
}

export function createHomeAsrProxyWebSocketHandler(
    WebSocketImpl: WebSocketCtor = WebSocket as unknown as WebSocketCtor
): HomeAsrProxyHandler {
    const upstreamMap = new WeakMap<ServerWebSocket<unknown>, HomeAsrUpstreamWebSocket>()
    const pendingFramesMap = new WeakMap<ServerWebSocket<unknown>, Array<string | ArrayBuffer | Uint8Array>>()
    const pendingBytesMap = new WeakMap<ServerWebSocket<unknown>, number>()

    function cleanup(clientWs: ServerWebSocket<unknown>): void {
        pendingFramesMap.delete(clientWs)
        pendingBytesMap.delete(clientWs)
        upstreamMap.delete(clientWs)
    }

    return {
        open(clientWs) {
            const data = clientWs.data as HomeAsrProxyData
            const upstreamUrl = new URL('/v1/voice/asr/ws', data.wsOrigin)
            upstreamUrl.searchParams.set('sample_rate', String(data.sampleRate || 16000))
            upstreamUrl.searchParams.set('source', 'hapi-ws')
            if (data.model?.trim()) {
                upstreamUrl.searchParams.set('model', data.model.trim())
            }

            const upstream = new WebSocketImpl(upstreamUrl.toString(), {
                headers: { Authorization: `Bearer ${data.token}` }
            })
            upstreamMap.set(clientWs, upstream)
            pendingFramesMap.set(clientWs, [])
            pendingBytesMap.set(clientWs, 0)

            upstream.onopen = () => {
                const queued = pendingFramesMap.get(clientWs) ?? []
                pendingFramesMap.delete(clientWs)
                pendingBytesMap.delete(clientWs)
                for (const frame of queued) {
                    try {
                        upstream.send(frame)
                    } catch {
                        break
                    }
                }
            }

            upstream.onmessage = (event) => {
                const raw = event.data
                try {
                    if (clientWs.readyState === WS_OPEN) {
                        clientWs.send(typeof raw === 'string' ? raw : new Uint8Array(raw as ArrayBuffer))
                    }
                } catch {
                    /* client gone */
                }
            }

            upstream.onerror = (event) => {
                console.error('[Voice][HomeAsrProxy] Upstream WebSocket error', {
                    wsOrigin: data.wsOrigin,
                    error: event instanceof Error ? event.message : String(event)
                })
                cleanup(clientWs)
                try {
                    clientWs.close(1011, 'Home Model Gateway error')
                } catch {
                    /* */
                }
            }

            upstream.onclose = (event) => {
                cleanup(clientWs)
                try {
                    clientWs.close(toClientCloseCode(event.code), event.reason || 'Upstream closed')
                } catch {
                    /* */
                }
            }
        },

        message(clientWs, message) {
            const upstream = upstreamMap.get(clientWs)
            if (!upstream) return

            if (upstream.readyState === WS_OPEN && !pendingFramesMap.has(clientWs)) {
                try {
                    upstream.send(message)
                } catch {
                    /* upstream gone */
                }
                return
            }

            const frameSize = typeof message === 'string'
                ? message.length
                : (message as ArrayBuffer | Uint8Array).byteLength
            const nextBytes = (pendingBytesMap.get(clientWs) ?? 0) + frameSize
            if (nextBytes > MAX_PENDING_BYTES) {
                cleanup(clientWs)
                try {
                    upstream.close(1009, 'Pending audio buffer exceeded')
                } catch {
                    /* */
                }
                try {
                    clientWs.close(1009, 'Pending audio buffer exceeded')
                } catch {
                    /* */
                }
                return
            }
            pendingBytesMap.set(clientWs, nextBytes)
            const queue = pendingFramesMap.get(clientWs) ?? []
            queue.push(message instanceof Uint8Array ? new Uint8Array(message) : message)
            pendingFramesMap.set(clientWs, queue)
        },

        close(clientWs, code, reason) {
            const upstream = upstreamMap.get(clientWs)
            cleanup(clientWs)
            if (upstream) {
                try {
                    upstream.close(toClientCloseCode(code), (reason || 'Client closed').slice(0, 123))
                } catch {
                    /* */
                }
            }
        }
    }
}
