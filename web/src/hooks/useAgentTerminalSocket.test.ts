import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useAgentTerminalSocket } from './useAgentTerminalSocket'

// A minimal fake native WebSocket that records sent JSON frames and lets the test drive
// lifecycle events (open, message, close).
class FakeWebSocket {
    static readonly CONNECTING = 0
    static readonly OPEN = 1
    static readonly CLOSING = 2
    static readonly CLOSED = 3

    static instances: FakeWebSocket[] = []

    readonly url: string
    readyState = FakeWebSocket.CONNECTING
    readonly sent: Array<Record<string, unknown>> = []
    onopen: (() => void) | null = null
    onmessage: ((event: { data: string }) => void) | null = null
    onerror: ((event: unknown) => void) | null = null
    onclose: ((event: { code: number; reason: string }) => void) | null = null

    constructor(url: string) {
        this.url = url
        FakeWebSocket.instances.push(this)
    }

    send(raw: string): void {
        this.sent.push(JSON.parse(raw) as Record<string, unknown>)
    }

    close(): void {
        this.readyState = FakeWebSocket.CLOSED
    }

    simulateOpen(): void {
        this.readyState = FakeWebSocket.OPEN
        this.onopen?.()
    }

    openFrameCount(): number {
        return this.sent.filter((f) => f.type === 'open' && f.terminal_id === 'agent').length
    }

    closeFrameCount(): number {
        return this.sent.filter((f) => f.type === 'close' && f.terminal_id === 'agent').length
    }
}

const options = { baseUrl: 'http://localhost:3000', token: 'tok', sessionId: 'session-1' }

describe('useAgentTerminalSocket subscribe gating (Reins Native v1 WebSocket)', () => {
    beforeEach(() => {
        FakeWebSocket.instances = []
        vi.stubGlobal('WebSocket', FakeWebSocket)
    })

    afterEach(() => {
        vi.unstubAllGlobals()
    })

    it('connects to /v1/sessions/{id}/terminal and does NOT send open when viewer never asked', () => {
        const { result } = renderHook(() => useAgentTerminalSocket(options))

        act(() => result.current.connect())
        const ws = FakeWebSocket.instances[0]
        expect(ws).toBeDefined()
        expect(ws!.url).toBe('ws://localhost:3000/v1/sessions/session-1/terminal?token=tok')

        act(() => ws!.simulateOpen())
        expect(ws!.openFrameCount()).toBe(0)
    })

    it('sends open only after resubscribe(), and re-sends open across reconnects', () => {
        const { result } = renderHook(() => useAgentTerminalSocket(options))

        act(() => result.current.connect())
        const ws = FakeWebSocket.instances[0]!
        act(() => ws.simulateOpen())
        expect(ws.openFrameCount()).toBe(0)

        // Becoming visible → resubscribe() sends the open frame.
        act(() => result.current.resubscribe())
        expect(ws.openFrameCount()).toBe(1)

        // A reconnect (e.g. network blip) must re-send open because the viewer is still watching.
        act(() => ws.simulateOpen())
        expect(ws.openFrameCount()).toBe(2)
    })

    it('does not subscribe when connect() is called again on an already-connected socket', () => {
        const { result } = renderHook(() => useAgentTerminalSocket(options))

        act(() => result.current.connect())
        const ws = FakeWebSocket.instances[0]!
        act(() => ws.simulateOpen())

        // Second connect() hits the reuse branch; it must not send open on its own.
        act(() => result.current.connect())
        expect(ws.openFrameCount()).toBe(0)
    })

    it('stops re-subscribing on reconnect after unsubscribe() (viewer left)', () => {
        const { result } = renderHook(() => useAgentTerminalSocket(options))

        act(() => result.current.connect())
        const ws = FakeWebSocket.instances[0]!
        act(() => ws.simulateOpen())
        act(() => result.current.resubscribe())
        expect(ws.openFrameCount()).toBe(1)

        act(() => result.current.unsubscribe())
        // After leaving, a reconnect must NOT re-send open.
        act(() => ws.simulateOpen())
        expect(ws.openFrameCount()).toBe(1)
        expect(ws.closeFrameCount()).toBe(1)
    })
})
