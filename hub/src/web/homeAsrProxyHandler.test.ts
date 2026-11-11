import { describe, expect, test } from 'bun:test'
import type { ServerWebSocket } from 'bun'
import { createHomeAsrProxyWebSocketHandler, type HomeAsrUpstreamWebSocket } from './homeAsrProxyHandler'

class FakeUpstreamWs implements HomeAsrUpstreamWebSocket {
    static instances: FakeUpstreamWs[] = []
    readyState = 0
    sent: Array<string | ArrayBuffer | Uint8Array> = []
    closedWith: { code?: number; reason?: string } | null = null
    onopen: (() => void) | null = null
    onmessage: ((event: { data: string | ArrayBuffer | Uint8Array }) => void) | null = null
    onerror: ((event: unknown) => void) | null = null
    onclose: ((event: { code: number; reason: string }) => void) | null = null

    constructor(public url: string, public opts?: unknown) {
        FakeUpstreamWs.instances.push(this)
    }

    send(data: string | ArrayBuffer | Uint8Array): void {
        this.sent.push(data)
    }

    close(code?: number, reason?: string): void {
        this.readyState = 3
        this.closedWith = { code, reason }
    }
}

describe('createHomeAsrProxyWebSocketHandler', () => {
    test('queues early PCM chunks during handshake and relays partial/final events', () => {
        FakeUpstreamWs.instances = []
        const handler = createHomeAsrProxyWebSocketHandler(FakeUpstreamWs as never)

        const clientReceived: Array<string | Uint8Array> = []
        const clientWs = {
            readyState: 1,
            data: {
                _homeAsrProxy: true as const,
                wsOrigin: 'wss://myhome.robin-larch.ts.net',
                token: 'secret-mcp-token',
                sampleRate: 16000,
                model: 'hybrid-qwen3'
            },
            send(payload: string | Uint8Array) {
                clientReceived.push(payload)
            },
            close() {}
        } as unknown as ServerWebSocket<unknown>

        handler.open(clientWs)
        expect(FakeUpstreamWs.instances).toHaveLength(1)
        const upstream = FakeUpstreamWs.instances[0]!
        expect(upstream.url).toBe(
            'wss://myhome.robin-larch.ts.net/v1/voice/asr/ws?sample_rate=16000&source=hapi-ws&model=hybrid-qwen3'
        )
        expect((upstream.opts as { headers: Record<string, string> }).headers.Authorization).toBe(
            'Bearer secret-mcp-token'
        )

        // Send early PCM chunk while upstream is still CONNECTING (readyState === 0)
        const pcmChunk = new Uint8Array([1, 2, 3, 4])
        handler.message(clientWs, pcmChunk)
        expect(upstream.sent).toHaveLength(0)

        // Upstream opens -> queued PCM is flushed immediately
        upstream.readyState = 1
        upstream.onopen?.()
        expect(upstream.sent).toHaveLength(1)

        // Subsequent finish frame goes straight through
        handler.message(clientWs, '{"type":"finish"}')
        expect(upstream.sent).toHaveLength(2)
        expect(upstream.sent[1]).toBe('{"type":"finish"}')

        // Upstream partial & final events relay back to client
        upstream.onmessage?.({ data: '{"type":"partial","text":"你好"}' })
        upstream.onmessage?.({ data: '{"type":"final","text":"你好，HAPI"}' })
        expect(clientReceived).toEqual([
            '{"type":"partial","text":"你好"}',
            '{"type":"final","text":"你好，HAPI"}'
        ])
    })
})
