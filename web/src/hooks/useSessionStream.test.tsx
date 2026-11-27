import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { adaptV1Message } from '@/api/v1Adapters'
import { normalizeDecryptedMessage } from '@/chat/normalize'
import { reduceChatBlocks } from '@/chat/reducer'
import type { DecryptedMessage } from '@/types/api'
import {
    mergeStreamOverlayMessages,
    parseSessionStreamFrame,
    useSessionStream,
    type StreamOverlaySnapshot
} from './useSessionStream'

class MockEventSource {
    static readonly CONNECTING = 0
    static readonly OPEN = 1
    static readonly CLOSED = 2
    static instances: MockEventSource[] = []

    readonly url: string
    readyState = MockEventSource.CONNECTING
    onopen: ((event: Event) => void) | null = null
    onmessage: ((event: MessageEvent<string>) => void) | null = null
    onerror: ((event: Event) => void) | null = null
    closed = false

    constructor(url: string) {
        this.url = url
        MockEventSource.instances.push(this)
    }

    emitOpen() {
        this.readyState = MockEventSource.OPEN
        this.onopen?.(new Event('open'))
    }

    emitData(payload: unknown) {
        const data = typeof payload === 'string' ? payload : JSON.stringify(payload)
        this.onmessage?.(new MessageEvent('message', { data }))
    }

    emitError() {
        this.onerror?.(new Event('error'))
    }

    close() {
        this.closed = true
        this.readyState = MockEventSource.CLOSED
    }
}

function makeV1AssistantRow(options: {
    id: string
    seq: number
    text?: string
    thinking?: string
    segmentId?: string
    streaming?: boolean
    createdAt?: number
}): DecryptedMessage {
    const blocks: Array<Record<string, unknown>> = []
    if (options.thinking !== undefined) {
        blocks.push({ type: 'thinking', thinking: options.thinking })
    }
    if (options.text !== undefined) {
        blocks.push({ type: 'text', text: options.text })
    }
    const meta: Record<string, unknown> = {}
    if (options.segmentId !== undefined) meta.segmentId = options.segmentId
    if (options.streaming !== undefined) meta.streaming = options.streaming
    return adaptV1Message({
        id: options.id,
        session_id: 'sess-1',
        seq: options.seq,
        local_id: null,
        role: 'assistant',
        content_rev: options.seq,
        invoked_at: options.createdAt ?? 1000,
        delivery_state: 'invoked',
        blocks,
        meta,
        created_at: options.createdAt ?? 1000
    })
}

function reduceToBlocks(messages: DecryptedMessage[]) {
    const normalized = messages
        .map(normalizeDecryptedMessage)
        .filter((msg): msg is NonNullable<typeof msg> => msg !== null)
    return reduceChatBlocks(normalized, null).blocks
}

describe('parseSessionStreamFrame', () => {
    it('parses Phase B stream frames in camelCase and snake_case', () => {
        expect(parseSessionStreamFrame('{"type":"connected"}')).toEqual({ type: 'connected' })
        expect(parseSessionStreamFrame(JSON.stringify({
            type: 'text_delta',
            turnId: 'turn-1',
            segmentId: 'seg-1',
            delta: 'Hello'
        }))).toEqual({
            type: 'text_delta',
            turnId: 'turn-1',
            segmentId: 'seg-1',
            delta: 'Hello'
        })
        expect(parseSessionStreamFrame(JSON.stringify({
            type: 'thinking_delta',
            turn_id: 'turn-1',
            segment_id: 'seg-think',
            delta: 'Considering...'
        }))).toEqual({
            type: 'thinking_delta',
            turnId: 'turn-1',
            segmentId: 'seg-think',
            delta: 'Considering...'
        })
        expect(parseSessionStreamFrame(JSON.stringify({
            type: 'turn_done',
            turnId: 'turn-1',
            aborted: true
        }))).toEqual({
            type: 'turn_done',
            turnId: 'turn-1',
            aborted: true
        })
        expect(parseSessionStreamFrame(JSON.stringify({
            type: 'error',
            turnId: 'turn-1',
            message: 'lagged',
            resync: true
        }))).toEqual({
            type: 'error',
            turnId: 'turn-1',
            message: 'lagged',
            resync: true
        })
        expect(parseSessionStreamFrame('{"type":"text_delta","turnId":"t1","delta":""}')).toBeNull()
        expect(parseSessionStreamFrame('not-json')).toBeNull()
    })
})

describe('mergeStreamOverlayMessages', () => {
    it('reconciles live /stream deltas with Phase A meta.streaming upserts and sealed rows without duplicate bubbles or block ID churn', () => {
        const userMsg = adaptV1Message({
            id: 'u1',
            session_id: 'sess-1',
            seq: 1,
            local_id: 'loc-1',
            role: 'user',
            content_rev: 1,
            invoked_at: 100,
            delivery_state: 'invoked',
            blocks: [{ type: 'text', text: 'Explain this' }],
            meta: {},
            created_at: 100
        })

        // Step 1: /stream deltas arrive before the first 800ms Phase A upsert.
        const liveOverlay: StreamOverlaySnapshot = {
            isConnected: true,
            segments: [
                {
                    key: 'seg:seg-think:thinking',
                    turnId: 't1',
                    segmentId: 'seg-think',
                    kind: 'thinking',
                    text: 'Let me analyze the code.',
                    createdAt: 200,
                    anchorMessageId: null,
                    completedAt: null
                },
                {
                    key: 'seg:seg-text:text',
                    turnId: 't1',
                    segmentId: 'seg-text',
                    kind: 'text',
                    text: 'Here is the complete answer',
                    createdAt: 210,
                    anchorMessageId: null,
                    completedAt: null
                }
            ]
        }

        const step1Blocks = reduceToBlocks(mergeStreamOverlayMessages([userMsg], liveOverlay))
        expect(step1Blocks).toHaveLength(3)
        expect(step1Blocks[1]).toMatchObject({
            kind: 'agent-reasoning',
            id: 'seg:seg-think:thinking',
            text: 'Let me analyze the code.'
        })
        expect(step1Blocks[2]).toMatchObject({
            kind: 'agent-text',
            id: 'seg:seg-text:text',
            text: 'Here is the complete answer'
        })

        // Step 2: Phase A meta.streaming === true upsert lands with slightly older snapshot text.
        const streamingUpsert = makeV1AssistantRow({
            id: 'a-text',
            seq: 2,
            text: 'Here is the',
            segmentId: 'seg-text',
            streaming: true,
            createdAt: 220
        })
        const step2Merged = mergeStreamOverlayMessages([userMsg, streamingUpsert], liveOverlay)
        const step2Blocks = reduceToBlocks(step2Merged)
        // Zero duplicate bubbles: still 1 reasoning + 1 text block, and the longer 60fps overlay text wins.
        expect(step2Blocks.filter((b) => b.kind === 'agent-text')).toHaveLength(1)
        expect(step2Blocks.find((b) => b.kind === 'agent-text')).toMatchObject({
            id: 'seg:seg-text:text',
            text: 'Here is the complete answer'
        })

        // Step 3: Phase A seals both segments (meta.streaming removed).
        const sealedThinking = makeV1AssistantRow({
            id: 'a-think',
            seq: 2,
            thinking: 'Let me analyze the code.',
            segmentId: 'seg-think',
            createdAt: 200
        })
        const sealedText = makeV1AssistantRow({
            id: 'a-text',
            seq: 3,
            text: 'Here is the complete answer!',
            segmentId: 'seg-text',
            createdAt: 230
        })
        const step3Blocks = reduceToBlocks(
            mergeStreamOverlayMessages([userMsg, sealedThinking, sealedText], liveOverlay)
        )
        expect(step3Blocks).toHaveLength(3)
        expect(step3Blocks[1]).toMatchObject({
            kind: 'agent-reasoning',
            id: 'seg:seg-think:thinking',
            text: 'Let me analyze the code.'
        })
        expect(step3Blocks[2]).toMatchObject({
            kind: 'agent-text',
            id: 'seg:seg-text:text',
            text: 'Here is the complete answer!'
        })
    })

    it('preserves a longer server prefix when joining mid-turn (never truncates to tail suffix)', () => {
        const midTurnServerRow = makeV1AssistantRow({
            id: 'a-mid',
            seq: 5,
            text: 'First 500 characters already streamed before client opened chat',
            segmentId: 'seg-mid',
            streaming: true,
            createdAt: 500
        })
        const tailOnlyOverlay: StreamOverlaySnapshot = {
            isConnected: true,
            segments: [{
                key: 'seg:seg-mid:text',
                turnId: 't1',
                segmentId: 'seg-mid',
                kind: 'text',
                text: ' tail delta',
                createdAt: 550,
                anchorMessageId: null,
                completedAt: null
            }]
        }
        const merged = mergeStreamOverlayMessages([midTurnServerRow], tailOnlyOverlay)
        const blocks = reduceToBlocks(merged)
        expect(blocks).toHaveLength(1)
        expect(blocks[0]).toMatchObject({
            kind: 'agent-text',
            id: 'seg:seg-mid:text',
            text: 'First 500 characters already streamed before client opened chat'
        })
    })

    it('falls back cleanly to Phase A meta.streaming rows when /stream overlay is empty and skips history viewMode', () => {
        const streamingRow = makeV1AssistantRow({
            id: 'a-fallback',
            seq: 2,
            text: 'Phase A fallback prose',
            segmentId: 'seg-fb',
            streaming: true
        })
        const emptyOverlay: StreamOverlaySnapshot = { isConnected: false, segments: [] }
        expect(mergeStreamOverlayMessages([streamingRow], emptyOverlay)).toEqual([streamingRow])
        const blocks = reduceToBlocks(mergeStreamOverlayMessages([streamingRow], emptyOverlay))
        expect(blocks).toHaveLength(1)
        expect(blocks[0]).toMatchObject({ kind: 'agent-text', text: 'Phase A fallback prose' })

        const activeOverlay: StreamOverlaySnapshot = {
            isConnected: true,
            segments: [{
                key: 'seg:seg-new:text',
                turnId: 't2',
                segmentId: 'seg-new',
                kind: 'text',
                text: 'Live tail chunk',
                createdAt: 900,
                anchorMessageId: null,
                completedAt: null
            }]
        }
        expect(mergeStreamOverlayMessages([streamingRow], activeOverlay, { viewMode: 'history' })).toEqual([streamingRow])
    })
})

describe('useSessionStream hook', () => {
    const originalEventSource = globalThis.EventSource
    const originalRaf = globalThis.requestAnimationFrame
    const originalCancelRaf = globalThis.cancelAnimationFrame
    let rafQueue: Array<{ id: number; cb: FrameRequestCallback }> = []
    let nextRafId = 1

    beforeEach(() => {
        vi.useFakeTimers()
        MockEventSource.instances = []
        rafQueue = []
        nextRafId = 1
        globalThis.EventSource = MockEventSource as unknown as typeof EventSource
        globalThis.requestAnimationFrame = ((cb: FrameRequestCallback) => {
            const id = nextRafId++
            rafQueue.push({ id, cb })
            return id
        }) as typeof requestAnimationFrame
        globalThis.cancelAnimationFrame = ((id: number) => {
            rafQueue = rafQueue.filter((entry) => entry.id !== id)
        }) as typeof cancelAnimationFrame
    })

    afterEach(() => {
        globalThis.EventSource = originalEventSource
        globalThis.requestAnimationFrame = originalRaf
        globalThis.cancelAnimationFrame = originalCancelRaf
        vi.useRealTimers()
    })

    const flushRaf = () => {
        const pending = rafQueue.splice(0, rafQueue.length)
        for (const entry of pending) {
            entry.cb(performance.now())
        }
    }

    it('connects with bearer query token, batches deltas per animation frame, prunes on seal, and cleans up on switch/unmount', () => {
        const { result, rerender, unmount } = renderHook(
            (props: { sessionId: string; messages: DecryptedMessage[]; enabled?: boolean }) => useSessionStream({
                enabled: props.enabled ?? true,
                baseUrl: 'https://hub.example.test',
                token: 'jwt-secret',
                sessionId: props.sessionId,
                messages: props.messages,
                turnDoneGraceMs: 1000
            }),
            { initialProps: { sessionId: 'sess/1', messages: [] as DecryptedMessage[] } }
        )

        expect(MockEventSource.instances).toHaveLength(1)
        const es1 = MockEventSource.instances[0]!
        expect(es1.url).toBe('https://hub.example.test/v1/sessions/sess%2F1/stream?token=jwt-secret')

        act(() => {
            es1.emitOpen()
            es1.emitData({ type: 'connected' })
        })
        expect(result.current.isConnected).toBe(true)

        // Rapid burst within a single animation frame batches into one flush.
        act(() => {
            es1.emitData({ type: 'thinking_delta', turnId: 't1', segmentId: 'seg-1', delta: 'Step 1. ' })
            es1.emitData({ type: 'thinking_delta', turnId: 't1', segmentId: 'seg-1', delta: 'Step 2.' })
            es1.emitData({ type: 'text_delta', turnId: 't1', segmentId: 'seg-2', delta: 'Hello' })
            es1.emitData({ type: 'text_delta', turnId: 't1', segmentId: 'seg-2', delta: ' world' })
        })
        expect(result.current.segments).toHaveLength(0)

        act(() => flushRaf())
        expect(result.current.segments).toHaveLength(2)
        expect(result.current.segments[0]).toMatchObject({ segmentId: 'seg-1', kind: 'thinking', text: 'Step 1. Step 2.' })
        expect(result.current.segments[1]).toMatchObject({ segmentId: 'seg-2', kind: 'text', text: 'Hello world' })

        // turn_done holds segment during grace window (preventing flicker before /v1/events seal arrives).
        act(() => {
            es1.emitData({ type: 'turn_done', turnId: 't1', aborted: false })
        })
        expect(result.current.segments).toHaveLength(2)

        // Sealed message lands for seg-1 -> pruned immediately while seg-2 remains until its seal or grace expiry.
        const sealedSeg1 = makeV1AssistantRow({
            id: 'm1',
            seq: 1,
            thinking: 'Step 1. Step 2.',
            segmentId: 'seg-1'
        })
        rerender({ sessionId: 'sess/1', messages: [sealedSeg1] })
        expect(result.current.segments).toHaveLength(1)
        expect(result.current.segments[0]?.segmentId).toBe('seg-2')

        // Late out-of-order delta for already-sealed seg-1 is ignored.
        act(() => {
            es1.emitData({ type: 'thinking_delta', turnId: 't1', segmentId: 'seg-1', delta: ' stale' })
            flushRaf()
        })
        expect(result.current.segments).toHaveLength(1)

        // Grace timer expires for unsealed seg-2 -> cleaned up automatically.
        act(() => {
            vi.advanceTimersByTime(1000)
        })
        expect(result.current.segments).toHaveLength(0)

        // Switching sessions immediately closes the prior stream and opens the new one.
        rerender({ sessionId: 'sess-2', messages: [] })
        expect(es1.closed).toBe(true)
        expect(MockEventSource.instances).toHaveLength(2)
        const es2 = MockEventSource.instances[1]!
        expect(es2.url).toBe('https://hub.example.test/v1/sessions/sess-2/stream?token=jwt-secret')

        unmount()
        expect(es2.closed).toBe(true)
    })

    it('clears overlay on disconnect/error, reconnects with backoff, and handles resync errors', () => {
        const onResync = vi.fn()
        const { result } = renderHook(() => useSessionStream({
            enabled: true,
            baseUrl: 'https://hub.example.test',
            token: 'jwt-1',
            sessionId: 'sess-err',
            messages: [],
            onResync
        }))

        const es1 = MockEventSource.instances[0]!
        act(() => {
            es1.emitOpen()
            es1.emitData({ type: 'text_delta', turnId: 't1', segmentId: 'seg-a', delta: 'Partial' })
            flushRaf()
        })
        expect(result.current.segments).toHaveLength(1)

        // Lag/resync error clears stale buffer and triggers onResync.
        act(() => {
            es1.emitData({ type: 'error', turnId: 't1', message: 'lagged', resync: true })
        })
        expect(result.current.segments).toHaveLength(0)
        expect(onResync).toHaveBeenCalledTimes(1)

        // Transport error closes EventSource, marks disconnected, and schedules reconnect.
        act(() => {
            es1.emitData({ type: 'text_delta', turnId: 't2', segmentId: 'seg-b', delta: 'Drop' })
            flushRaf()
            es1.emitError()
        })
        expect(es1.closed).toBe(true)
        expect(result.current.isConnected).toBe(false)
        expect(result.current.segments).toHaveLength(0)

        act(() => {
            vi.advanceTimersByTime(1000)
        })
        expect(MockEventSource.instances).toHaveLength(2)
    })

    it('handles unsegmented turns cleanly across tool_use and sealed assistant handoff without concatenating segments', () => {
        const initialUser = adaptV1Message({
            id: 'u-unseg',
            session_id: 'sess-u',
            seq: 1,
            local_id: 'loc-u',
            role: 'user',
            content_rev: 1,
            invoked_at: 100,
            delivery_state: 'invoked',
            blocks: [{ type: 'text', text: 'Run check' }],
            meta: {},
            created_at: 100
        })
        const { result, rerender } = renderHook(
            (props: { messages: DecryptedMessage[] }) => useSessionStream({
                enabled: true,
                baseUrl: 'https://hub.example.test',
                token: 'jwt-1',
                sessionId: 'sess-u',
                messages: props.messages,
                turnDoneGraceMs: 1000
            }),
            { initialProps: { messages: [initialUser] } }
        )

        const es = MockEventSource.instances[0]!
        act(() => {
            es.emitOpen()
            es.emitData({ type: 'text_delta', turnId: 't-unseg', delta: 'Checking files...' })
            flushRaf()
        })
        expect(result.current.segments).toHaveLength(1)
        expect(result.current.segments[0]?.text).toBe('Checking files...')

        // tool_use marks the unsegmented pre-tool text completed; post-tool text starts fresh instead of concatenating.
        act(() => {
            es.emitData({ type: 'tool_use', turnId: 't-unseg' })
            es.emitData({ type: 'text_delta', turnId: 't-unseg', delta: 'All checks passed!' })
            flushRaf()
        })
        expect(result.current.segments).toHaveLength(1)
        expect(result.current.segments[0]?.text).toBe('All checks passed!')

        // Final sealed assistant message lands -> overlay deduplicates cleanly.
        const finalAssistant = makeV1AssistantRow({
            id: 'a-unseg-final',
            seq: 2,
            text: 'All checks passed!',
            createdAt: 200
        })
        rerender({ messages: [initialUser, finalAssistant] })
        expect(result.current.segments).toHaveLength(0)
    })
})
