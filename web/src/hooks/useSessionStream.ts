import { useEffect, useRef, useState } from 'react'
import { buildSegmentStreamId, buildV1SessionStreamUrl } from '@/api/v1Adapters'
import type { DecryptedMessage } from '@/types/api'

type UnknownRecord = Record<string, unknown>

function isRecord(value: unknown): value is UnknownRecord {
    return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asNonEmptyString(value: unknown): string | null {
    if (typeof value !== 'string') return null
    const trimmed = value.trim()
    return trimmed.length > 0 ? trimmed : null
}

export type SessionStreamFrame =
    | { type: 'connected' }
    | { type: 'text_delta'; turnId: string; segmentId: string | null; delta: string }
    | { type: 'thinking_delta'; turnId: string; segmentId: string | null; delta: string }
    | { type: 'tool_use'; turnId: string | null }
    | { type: 'tool_result'; turnId: string | null }
    | { type: 'assistant_message'; turnId: string | null }
    | { type: 'turn_done'; turnId: string; aborted: boolean }
    | { type: 'error'; turnId: string | null; message: string; resync: boolean }

export type StreamOverlaySegment = {
    key: string
    turnId: string
    segmentId: string | null
    kind: 'text' | 'thinking'
    text: string
    createdAt: number
    /** Last message id in the window when an unsegmented stream began, for clean dedupe. */
    anchorMessageId: string | null
    completedAt: number | null
}

export type StreamOverlaySnapshot = {
    segments: readonly StreamOverlaySegment[]
    isConnected: boolean
    preExistingStreamingSegmentIds?: readonly string[]
}

const EMPTY_SNAPSHOT: StreamOverlaySnapshot = {
    segments: [],
    isConnected: false
}

const CONNECT_TIMEOUT_MS = 10_000
const VISIBILITY_RESUME_STALE_MS = 45_000
const RECONNECT_BASE_DELAY_MS = 1_000
const RECONNECT_MAX_DELAY_MS = 30_000
const RECONNECT_JITTER_MS = 500
const RECONNECT_SLOW_AFTER_ATTEMPTS = 8
const RECONNECT_SLOW_MAX_DELAY_MS = 300_000
const DEFAULT_TURN_DONE_GRACE_MS = 1_500
const MAX_SEALED_SEGMENT_HISTORY = 256

function getVisibilityState(): 'visible' | 'hidden' {
    if (typeof document === 'undefined') {
        return 'visible'
    }
    return document.visibilityState === 'hidden' ? 'hidden' : 'visible'
}

export function parseSessionStreamFrame(raw: string): SessionStreamFrame | null {
    let parsed: unknown
    try {
        parsed = JSON.parse(raw)
    } catch {
        return null
    }
    if (!isRecord(parsed) || typeof parsed.type !== 'string') {
        return null
    }
    switch (parsed.type) {
        case 'connected':
            return { type: 'connected' }
        case 'text_delta':
        case 'thinking_delta': {
            const turnId = asNonEmptyString(parsed.turnId ?? parsed.turn_id) ?? 'default'
            const segmentId = asNonEmptyString(parsed.segmentId ?? parsed.segment_id)
            const delta = typeof parsed.delta === 'string' ? parsed.delta : ''
            if (delta.length === 0) return null
            return {
                type: parsed.type,
                turnId,
                segmentId,
                delta
            }
        }
        case 'tool_use':
        case 'tool_result':
        case 'assistant_message':
            return {
                type: parsed.type,
                turnId: asNonEmptyString(parsed.turnId ?? parsed.turn_id)
            }
        case 'turn_done': {
            const turnId = asNonEmptyString(parsed.turnId ?? parsed.turn_id) ?? 'default'
            return {
                type: 'turn_done',
                turnId,
                aborted: parsed.aborted === true
            }
        }
        case 'error':
            return {
                type: 'error',
                turnId: asNonEmptyString(parsed.turnId ?? parsed.turn_id),
                message: typeof parsed.message === 'string' ? parsed.message : 'Stream error',
                resync: parsed.resync === true
            }
        default:
            return null
    }
}

export function getMessageStreamingMeta(message: DecryptedMessage): {
    streaming: boolean
    segmentId: string | null
} {
    const content = message.content
    if (!isRecord(content) || !isRecord(content.meta)) {
        return { streaming: false, segmentId: null }
    }
    const meta = content.meta
    const streaming = meta.streaming === true
    const segmentId = asNonEmptyString(meta.segmentId ?? meta.segment_id)
    return { streaming, segmentId }
}

function getAssistantOutputBlocks(message: DecryptedMessage): UnknownRecord[] | null {
    const content = message.content
    if (!isRecord(content) || content.role !== 'agent') return null
    const inner = content.content
    if (!isRecord(inner) || inner.type !== 'output') return null
    const data = inner.data
    if (!isRecord(data) || data.type !== 'assistant') return null
    const msg = data.message
    if (!isRecord(msg) || !Array.isArray(msg.content)) return null
    return msg.content.filter(isRecord)
}

function getAssistantContentLength(message: DecryptedMessage): number {
    const blocks = getAssistantOutputBlocks(message)
    if (!blocks) return 0
    let total = 0
    for (const blk of blocks) {
        if (blk.type === 'text' && typeof blk.text === 'string') {
            total += blk.text.length
        }
        if (blk.type === 'thinking' && typeof blk.thinking === 'string') {
            total += blk.thinking.length
        }
    }
    return total
}

function replaceAssistantOutputBlocks(
    message: DecryptedMessage,
    nextBlocks: UnknownRecord[]
): DecryptedMessage {
    const content = message.content as UnknownRecord
    const inner = content.content as UnknownRecord
    const data = inner.data as UnknownRecord
    const msg = data.message as UnknownRecord
    return {
        ...message,
        content: {
            ...content,
            content: {
                ...inner,
                data: {
                    ...data,
                    message: {
                        ...msg,
                        content: nextBlocks
                    }
                }
            }
        }
    }
}

function hasSealedAssistantCoverage(
    messages: readonly DecryptedMessage[],
    segment: StreamOverlaySegment
): boolean {
    let startIndex = 0
    if (segment.anchorMessageId !== null) {
        const anchorIndex = messages.findIndex((msg) => msg.id === segment.anchorMessageId)
        if (anchorIndex >= 0) {
            startIndex = anchorIndex + 1
        }
    }
    for (let i = startIndex; i < messages.length; i += 1) {
        const msg = messages[i]
        if (!msg) continue
        const meta = getMessageStreamingMeta(msg)
        if (meta.streaming) continue
        const blocks = getAssistantOutputBlocks(msg)
        if (!blocks) continue
        for (const blk of blocks) {
            if (segment.kind === 'text' && blk.type === 'text' && typeof blk.text === 'string' && blk.text.length > 0) {
                if (segment.completedAt !== null) return true
                if (blk.text.length >= segment.text.length && blk.text.startsWith(segment.text)) {
                    return true
                }
            }
            if (segment.kind === 'thinking' && blk.type === 'thinking' && typeof blk.thinking === 'string' && blk.thinking.length > 0) {
                if (segment.completedAt !== null) return true
                if (blk.thinking.length >= segment.text.length && blk.thinking.startsWith(segment.text)) {
                    return true
                }
            }
        }
    }
    return false
}

function createVirtualStreamMessage(segment: StreamOverlaySegment): DecryptedMessage {
    const streamId = segment.segmentId
        ? buildSegmentStreamId(segment.segmentId, segment.kind, 0)
        : segment.key
    const block: UnknownRecord = segment.kind === 'thinking'
        ? { type: 'thinking', thinking: segment.text, streamId }
        : { type: 'text', text: segment.text, streamId }
    return {
        id: `live-stream:${segment.key}`,
        seq: null,
        localId: null,
        createdAt: segment.createdAt,
        content: {
            role: 'agent',
            content: {
                type: 'output',
                data: {
                    type: 'assistant',
                    message: {
                        role: 'assistant',
                        content: [block]
                    }
                }
            },
            meta: {
                streaming: true,
                ...(segment.segmentId ? { segmentId: segment.segmentId } : {}),
                streamTurnId: segment.turnId
            }
        }
    }
}

/**
 * Pure reconciliation between persisted/Phase-A messages and Phase-B `/stream`
 * live delta buffers.
 *
 * Guarantees:
 * - Zero duplicate bubbles: active `/stream` segments merge in-place with any
 *   Phase A `meta.streaming === true` row sharing `meta.segmentId`, and yield
 *   immediately once a sealed (`meta.streaming !== true`) row arrives.
 * - Zero flicker: live overlay, Phase A streaming upsert, and sealed row all
 *   share the exact same `streamId` (`seg:<segmentId>:<kind>`), keeping the
 *   reduced `ChatBlock.id` and React component identity stable across seal.
 * - Mid-turn join safety: if the server's `meta.streaming` snapshot already
 *   carries a longer prefix than `/stream` saw after joining, the longer text
 *   is preserved instead of truncating back to the tail suffix.
 * - Graceful fallback: when `/stream` is disconnected or empty, returns
 *   `messages` unchanged so Phase A `meta.streaming` upserts render normally.
 */
export function mergeStreamOverlayMessages(
    messages: readonly DecryptedMessage[],
    overlay: StreamOverlaySnapshot,
    options?: { viewMode?: 'tail' | 'history' }
): DecryptedMessage[] {
    if (overlay.segments.length === 0 || options?.viewMode === 'history') {
        return messages as DecryptedMessage[]
    }

    const sealedSegmentIds = new Set<string>()
    for (const msg of messages) {
        const { streaming, segmentId } = getMessageStreamingMeta(msg)
        if (!streaming && segmentId !== null) {
            sealedSegmentIds.add(segmentId)
        }
    }
    const preExistingSegmentIds = new Set<string>(overlay.preExistingStreamingSegmentIds ?? [])

    const overlayBySegmentAndKind = new Map<string, StreamOverlaySegment>()
    for (const seg of overlay.segments) {
        if (
            seg.segmentId !== null
            && seg.text.length > 0
            && !sealedSegmentIds.has(seg.segmentId)
            && !preExistingSegmentIds.has(seg.segmentId)
        ) {
            overlayBySegmentAndKind.set(`${seg.segmentId}:${seg.kind}`, seg)
        }
    }

    const consumedKeys = new Set<string>()
    let mutatedExisting = false
    const updatedMessages: DecryptedMessage[] = messages.map((msg) => {
        const { streaming, segmentId } = getMessageStreamingMeta(msg)
        if (!streaming || segmentId === null) {
            return msg
        }
        const textOverlay = overlayBySegmentAndKind.get(`${segmentId}:text`)
        const thinkingOverlay = overlayBySegmentAndKind.get(`${segmentId}:thinking`)
        if (!textOverlay && !thinkingOverlay) {
            return msg
        }

        const blocks = getAssistantOutputBlocks(msg)
        if (!blocks) {
            return msg
        }

        let blockChanged = false
        let sawText = false
        let sawThinking = false
        const nextBlocks = blocks.map((blk) => {
            if (blk.type === 'text' && typeof blk.text === 'string' && !sawText && textOverlay) {
                sawText = true
                consumedKeys.add(textOverlay.key)
                const desiredStreamId = buildSegmentStreamId(segmentId, 'text', 0)
                const nextText = textOverlay.text.length >= blk.text.length ? textOverlay.text : blk.text
                if (nextText !== blk.text || blk.streamId !== desiredStreamId) {
                    blockChanged = true
                    return { ...blk, text: nextText, streamId: desiredStreamId }
                }
                return blk
            }
            if (blk.type === 'thinking' && typeof blk.thinking === 'string' && !sawThinking && thinkingOverlay) {
                sawThinking = true
                consumedKeys.add(thinkingOverlay.key)
                const desiredStreamId = buildSegmentStreamId(segmentId, 'thinking', 0)
                const nextThinking = thinkingOverlay.text.length >= blk.thinking.length
                    ? thinkingOverlay.text
                    : blk.thinking
                if (nextThinking !== blk.thinking || blk.streamId !== desiredStreamId) {
                    blockChanged = true
                    return { ...blk, thinking: nextThinking, streamId: desiredStreamId }
                }
                return blk
            }
            return blk
        })

        if (thinkingOverlay && !sawThinking) {
            consumedKeys.add(thinkingOverlay.key)
            blockChanged = true
            nextBlocks.unshift({
                type: 'thinking',
                thinking: thinkingOverlay.text,
                streamId: buildSegmentStreamId(segmentId, 'thinking', 0)
            })
        }
        if (textOverlay && !sawText) {
            consumedKeys.add(textOverlay.key)
            blockChanged = true
            nextBlocks.push({
                type: 'text',
                text: textOverlay.text,
                streamId: buildSegmentStreamId(segmentId, 'text', 0)
            })
        }

        if (!blockChanged) {
            return msg
        }
        mutatedExisting = true
        return replaceAssistantOutputBlocks(msg, nextBlocks)
    })

    const appended: DecryptedMessage[] = []
    for (const seg of overlay.segments) {
        if (consumedKeys.has(seg.key) || seg.text.length === 0) {
            continue
        }
        if (seg.segmentId !== null) {
            if (sealedSegmentIds.has(seg.segmentId) || preExistingSegmentIds.has(seg.segmentId)) {
                continue
            }
        } else if (hasSealedAssistantCoverage(messages, seg)) {
            continue
        }
        appended.push(createVirtualStreamMessage(seg))
    }

    if (!mutatedExisting && appended.length === 0) {
        return messages as DecryptedMessage[]
    }
    return appended.length > 0 ? [...updatedMessages, ...appended] : updatedMessages
}

export function useSessionStream(options: {
    enabled: boolean
    baseUrl: string
    token: string
    sessionId: string | null
    messages: readonly DecryptedMessage[]
    isThinking?: boolean
    onResync?: () => void
    turnDoneGraceMs?: number
}): StreamOverlaySnapshot {
    const turnDoneGraceMs = options.turnDoneGraceMs ?? DEFAULT_TURN_DONE_GRACE_MS
    const [snapshotState, setSnapshotState] = useState<{
        sessionId: string | null
        snapshot: StreamOverlaySnapshot
    }>({ sessionId: options.sessionId, snapshot: EMPTY_SNAPSHOT })
    const [reconnectNonce, setReconnectNonce] = useState(0)

    const sessionIdRef = useRef(options.sessionId)
    const segmentsRef = useRef<Map<string, StreamOverlaySegment>>(new Map())
    const sealedSegmentIdsRef = useRef<Set<string>>(new Set())
    const preExistingStreamingSegmentIdsRef = useRef<Set<string>>(new Set())
    const awaitingInitialWindowSnapshotRef = useRef(false)
    const isConnectedRef = useRef(false)
    const messagesRef = useRef(options.messages)
    const onResyncRef = useRef(options.onResync)
    const prevThinkingRef = useRef(options.isThinking ?? false)
    const rafIdRef = useRef<number | null>(null)
    const fallbackFlushTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
    const turnGraceTimersRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map())
    const reconnectTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
    const reconnectAttemptRef = useRef(0)
    const reconnectDeferredRef = useRef(false)
    const hiddenAtRef = useRef<number | null>(null)
    const eventSourceRef = useRef<EventSource | null>(null)

    sessionIdRef.current = options.sessionId
    messagesRef.current = options.messages
    onResyncRef.current = options.onResync

    const cancelScheduledFlush = () => {
        if (rafIdRef.current !== null && typeof cancelAnimationFrame === 'function') {
            cancelAnimationFrame(rafIdRef.current)
        }
        rafIdRef.current = null
        if (fallbackFlushTimerRef.current !== null) {
            clearTimeout(fallbackFlushTimerRef.current)
            fallbackFlushTimerRef.current = null
        }
    }

    const publishSnapshotNow = () => {
        cancelScheduledFlush()
        const segments = Array.from(segmentsRef.current.values(), (seg) => ({ ...seg }))
        const isConnected = isConnectedRef.current
        const activeSessionId = sessionIdRef.current
        setSnapshotState((previous) => {
            if (
                previous.sessionId === activeSessionId
                && segments.length === 0
                && previous.snapshot.segments.length === 0
                && previous.snapshot.isConnected === isConnected
            ) {
                return previous
            }
            return { sessionId: activeSessionId, snapshot: { segments, isConnected } }
        })
    }

    const scheduleFrameFlush = () => {
        if (rafIdRef.current !== null || fallbackFlushTimerRef.current !== null) {
            return
        }
        if (typeof requestAnimationFrame === 'function') {
            rafIdRef.current = requestAnimationFrame(() => {
                rafIdRef.current = null
                publishSnapshotNow()
            })
            return
        }
        fallbackFlushTimerRef.current = setTimeout(() => {
            fallbackFlushTimerRef.current = null
            publishSnapshotNow()
        }, 16)
    }

    const clearTurnGraceTimers = () => {
        for (const timer of turnGraceTimersRef.current.values()) {
            clearTimeout(timer)
        }
        turnGraceTimersRef.current.clear()
    }

    const clearAllSegments = () => {
        clearTurnGraceTimers()
        if (segmentsRef.current.size > 0) {
            segmentsRef.current.clear()
        }
    }

    const scheduleTurnGraceCleanup = (turnId: string) => {
        const existing = turnGraceTimersRef.current.get(turnId)
        if (existing) {
            clearTimeout(existing)
        }
        const timer = setTimeout(() => {
            turnGraceTimersRef.current.delete(turnId)
            let removed = false
            for (const [key, seg] of segmentsRef.current) {
                if (seg.turnId === turnId && seg.completedAt !== null) {
                    segmentsRef.current.delete(key)
                    removed = true
                }
            }
            if (removed) {
                publishSnapshotNow()
            }
        }, turnDoneGraceMs)
        turnGraceTimersRef.current.set(turnId, timer)
    }

    const recordSealedSegment = (segmentId: string) => {
        const sealed = sealedSegmentIdsRef.current
        sealed.add(segmentId)
        if (sealed.size > MAX_SEALED_SEGMENT_HISTORY) {
            const oldest = sealed.values().next().value
            if (oldest !== undefined) {
                sealed.delete(oldest)
            }
        }
    }

    const snapshotPreExistingStreamingSegments = (messages: readonly DecryptedMessage[]) => {
        const preExisting = preExistingStreamingSegmentIdsRef.current
        preExisting.clear()
        for (const msg of messages) {
            const { streaming, segmentId } = getMessageStreamingMeta(msg)
            if (streaming && segmentId !== null && !sealedSegmentIdsRef.current.has(segmentId)) {
                preExisting.add(segmentId)
            }
        }
        if (preExisting.size > 0) {
            for (const [key, seg] of segmentsRef.current) {
                if (seg.segmentId !== null && preExisting.has(seg.segmentId)) {
                    segmentsRef.current.delete(key)
                }
            }
        }
        awaitingInitialWindowSnapshotRef.current = messages.length === 0
    }

    // Reset per-session sealed history when session changes.
    useEffect(() => {
        sealedSegmentIdsRef.current.clear()
        preExistingStreamingSegmentIdsRef.current.clear()
        awaitingInitialWindowSnapshotRef.current = false
        clearAllSegments()
        isConnectedRef.current = false
        setSnapshotState({ sessionId: options.sessionId, snapshot: EMPTY_SNAPSHOT })
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [options.sessionId])

    // Prune overlay segments immediately when their sealed StoredMessage lands via /v1/events or REST,
    // clear sealed IDs from preExistingStreamingSegmentIds, and protect mid-turn streaming rows if
    // the initial window snapshot arrives right after /stream connects.
    useEffect(() => {
        const sealedNow = new Set<string>()
        for (const msg of options.messages) {
            const { streaming, segmentId } = getMessageStreamingMeta(msg)
            if (!streaming && segmentId !== null) {
                sealedNow.add(segmentId)
                recordSealedSegment(segmentId)
                preExistingStreamingSegmentIdsRef.current.delete(segmentId)
            }
        }

        if (isConnectedRef.current && options.messages.length > 0) {
            for (const msg of options.messages) {
                const { streaming, segmentId } = getMessageStreamingMeta(msg)
                if (
                    !streaming
                    || segmentId === null
                    || sealedNow.has(segmentId)
                    || sealedSegmentIdsRef.current.has(segmentId)
                    || preExistingStreamingSegmentIdsRef.current.has(segmentId)
                ) {
                    continue
                }
                let hasLive = false
                let liveLen = 0
                for (const seg of segmentsRef.current.values()) {
                    if (seg.segmentId === segmentId) {
                        hasLive = true
                        liveLen += seg.text.length
                    }
                }
                const persistedLen = getAssistantContentLength(msg)
                const shouldProtect = awaitingInitialWindowSnapshotRef.current
                    ? (!hasLive || persistedLen > liveLen)
                    : (hasLive && persistedLen > liveLen)
                if (shouldProtect) {
                    preExistingStreamingSegmentIdsRef.current.add(segmentId)
                }
            }
            if (awaitingInitialWindowSnapshotRef.current) {
                awaitingInitialWindowSnapshotRef.current = false
            }
        }

        if (segmentsRef.current.size === 0) {
            return
        }

        let changed = false
        for (const [key, seg] of segmentsRef.current) {
            if (seg.segmentId !== null) {
                if (
                    sealedNow.has(seg.segmentId)
                    || preExistingStreamingSegmentIdsRef.current.has(seg.segmentId)
                ) {
                    segmentsRef.current.delete(key)
                    changed = true
                }
            } else if (hasSealedAssistantCoverage(options.messages, seg)) {
                segmentsRef.current.delete(key)
                changed = true
            }
        }

        if (changed) {
            for (const [turnId, timer] of turnGraceTimersRef.current) {
                const stillHasTurn = Array.from(segmentsRef.current.values()).some((seg) => seg.turnId === turnId)
                if (!stillHasTurn) {
                    clearTimeout(timer)
                    turnGraceTimersRef.current.delete(turnId)
                }
            }
            publishSnapshotNow()
        }
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [options.messages])

    // Safety net: if session.thinking transitions true -> false without a turn_done frame,
    // mark remaining open segments for grace cleanup so nothing leaks across turns.
    useEffect(() => {
        const isThinking = options.isThinking ?? false
        if (prevThinkingRef.current && !isThinking) {
            preExistingStreamingSegmentIdsRef.current.clear()
            if (segmentsRef.current.size > 0) {
                const now = Date.now()
                const affectedTurns = new Set<string>()
                for (const seg of segmentsRef.current.values()) {
                    if (seg.completedAt === null) {
                        seg.completedAt = now
                        affectedTurns.add(seg.turnId)
                    }
                }
                for (const turnId of affectedTurns) {
                    scheduleTurnGraceCleanup(turnId)
                }
                if (affectedTurns.size > 0) {
                    publishSnapshotNow()
                }
            }
        }
        prevThinkingRef.current = isThinking
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [options.isThinking])

    // Live EventSource lifecycle for GET /v1/sessions/{id}/stream.
    useEffect(() => {
        const canConnect = Boolean(
            options.enabled
            && options.sessionId
            && options.token
            && typeof EventSource !== 'undefined'
        )

        if (!canConnect || !options.sessionId) {
            eventSourceRef.current?.close()
            eventSourceRef.current = null
            if (reconnectTimerRef.current) {
                clearTimeout(reconnectTimerRef.current)
                reconnectTimerRef.current = null
            }
            reconnectAttemptRef.current = 0
            reconnectDeferredRef.current = false
            isConnectedRef.current = false
            preExistingStreamingSegmentIdsRef.current.clear()
            awaitingInitialWindowSnapshotRef.current = false
            clearAllSegments()
            publishSnapshotNow()
            return
        }

        const url = buildV1SessionStreamUrl(options.baseUrl, options.sessionId, options.token)
        const eventSource = new EventSource(url)
        eventSourceRef.current = eventSource
        let reconnectRequested = false

        const scheduleReconnect = () => {
            if (getVisibilityState() === 'hidden') {
                reconnectDeferredRef.current = true
                if (reconnectTimerRef.current) {
                    clearTimeout(reconnectTimerRef.current)
                    reconnectTimerRef.current = null
                }
                return
            }

            const attempt = reconnectAttemptRef.current
            const maxDelay = attempt >= RECONNECT_SLOW_AFTER_ATTEMPTS
                ? RECONNECT_SLOW_MAX_DELAY_MS
                : RECONNECT_MAX_DELAY_MS
            const exponentialDelay = attempt === 0
                ? 0
                : Math.min(maxDelay, RECONNECT_BASE_DELAY_MS * (2 ** (attempt - 1)))
            const jitter = Math.floor(Math.random() * (RECONNECT_JITTER_MS + 1))
            reconnectAttemptRef.current = attempt + 1
            if (reconnectTimerRef.current) {
                clearTimeout(reconnectTimerRef.current)
            }
            reconnectTimerRef.current = setTimeout(() => {
                reconnectTimerRef.current = null
                setReconnectNonce((value) => value + 1)
            }, exponentialDelay + jitter)
        }

        const requestReconnect = (force = false) => {
            if (reconnectRequested && !force) {
                return
            }
            reconnectRequested = true
            eventSource.close()
            if (eventSourceRef.current === eventSource) {
                eventSourceRef.current = null
            }
            isConnectedRef.current = false
            preExistingStreamingSegmentIdsRef.current.clear()
            awaitingInitialWindowSnapshotRef.current = false
            clearAllSegments()
            publishSnapshotNow()
            scheduleReconnect()
        }

        const markConnected = () => {
            reconnectAttemptRef.current = 0
            reconnectDeferredRef.current = false
            if (!isConnectedRef.current) {
                isConnectedRef.current = true
                snapshotPreExistingStreamingSegments(messagesRef.current)
                publishSnapshotNow()
            }
        }

        const handleFrame = (frame: SessionStreamFrame) => {
            switch (frame.type) {
                case 'connected': {
                    markConnected()
                    return
                }
                case 'text_delta':
                case 'thinking_delta': {
                    if (
                        frame.segmentId !== null
                        && (
                            sealedSegmentIdsRef.current.has(frame.segmentId)
                            || preExistingStreamingSegmentIdsRef.current.has(frame.segmentId)
                        )
                    ) {
                        return
                    }
                    const kind: 'text' | 'thinking' = frame.type === 'thinking_delta' ? 'thinking' : 'text'
                    const key = frame.segmentId !== null
                        ? buildSegmentStreamId(frame.segmentId, kind, 0)
                        : `stream:${frame.turnId}:${kind}`

                    // When a brand-new turn begins, drop any lingering grace-period segments from prior turns.
                    for (const [existingKey, existingSeg] of segmentsRef.current) {
                        if (existingSeg.turnId !== frame.turnId && existingSeg.completedAt !== null) {
                            segmentsRef.current.delete(existingKey)
                        }
                    }

                    const existing = segmentsRef.current.get(key)
                    if (existing && !(existing.segmentId === null && existing.completedAt !== null)) {
                        existing.text += frame.delta
                        existing.completedAt = null
                    } else {
                        const currentMessages = messagesRef.current
                        const anchorMessageId = frame.segmentId === null
                            ? (currentMessages.length > 0 ? currentMessages[currentMessages.length - 1]!.id : null)
                            : null
                        segmentsRef.current.set(key, {
                            key,
                            turnId: frame.turnId,
                            segmentId: frame.segmentId,
                            kind,
                            text: frame.delta,
                            createdAt: Date.now(),
                            anchorMessageId,
                            completedAt: null
                        })
                    }
                    scheduleFrameFlush()
                    return
                }
                case 'tool_use':
                case 'assistant_message': {
                    const now = Date.now()
                    const affectedTurns = new Set<string>()
                    for (const seg of segmentsRef.current.values()) {
                        if (seg.segmentId !== null) continue
                        if (frame.turnId !== null && seg.turnId !== frame.turnId) continue
                        if (seg.completedAt === null) {
                            seg.completedAt = now
                            affectedTurns.add(seg.turnId)
                        }
                    }
                    for (const turnId of affectedTurns) {
                        scheduleTurnGraceCleanup(turnId)
                    }
                    if (affectedTurns.size > 0) {
                        publishSnapshotNow()
                    }
                    return
                }
                case 'turn_done': {
                    preExistingStreamingSegmentIdsRef.current.clear()
                    const now = Date.now()
                    let changed = false
                    let hasPending = false
                    for (const [key, seg] of segmentsRef.current) {
                        if (seg.turnId !== frame.turnId) continue
                        if (seg.segmentId === null && hasSealedAssistantCoverage(messagesRef.current, { ...seg, completedAt: now })) {
                            segmentsRef.current.delete(key)
                            changed = true
                            continue
                        }
                        if (seg.completedAt === null) {
                            seg.completedAt = now
                            changed = true
                        }
                        hasPending = true
                    }
                    if (hasPending) {
                        scheduleTurnGraceCleanup(frame.turnId)
                    }
                    if (changed) {
                        publishSnapshotNow()
                    }
                    return
                }
                case 'error': {
                    if (frame.resync) {
                        if (frame.turnId !== null) {
                            for (const [key, seg] of segmentsRef.current) {
                                if (seg.turnId === frame.turnId) {
                                    segmentsRef.current.delete(key)
                                }
                            }
                            const timer = turnGraceTimersRef.current.get(frame.turnId)
                            if (timer) {
                                clearTimeout(timer)
                                turnGraceTimersRef.current.delete(frame.turnId)
                            }
                        } else {
                            clearAllSegments()
                        }
                        publishSnapshotNow()
                        onResyncRef.current?.()
                    }
                    return
                }
                case 'tool_result':
                    return
            }
        }

        const connectDeadlineTimer = setTimeout(() => {
            if (eventSourceRef.current !== eventSource) {
                return
            }
            if (eventSource.readyState === EventSource.OPEN) {
                return
            }
            requestReconnect(true)
        }, CONNECT_TIMEOUT_MS)

        eventSource.onopen = () => {
            clearTimeout(connectDeadlineTimer)
            if (reconnectTimerRef.current) {
                clearTimeout(reconnectTimerRef.current)
                reconnectTimerRef.current = null
            }
            markConnected()
        }

        eventSource.onmessage = (message: MessageEvent<string>) => {
            if (typeof message.data !== 'string') return
            const frame = parseSessionStreamFrame(message.data)
            if (!frame) return
            handleFrame(frame)
        }

        eventSource.onerror = () => {
            clearTimeout(connectDeadlineTimer)
            requestReconnect()
        }

        const onVisibilityChange = () => {
            const visibility = getVisibilityState()
            if (visibility === 'hidden') {
                hiddenAtRef.current = Date.now()
                return
            }
            const hiddenAt = hiddenAtRef.current
            hiddenAtRef.current = null
            if (reconnectDeferredRef.current) {
                reconnectDeferredRef.current = false
                setReconnectNonce((value) => value + 1)
                return
            }
            if (
                eventSourceRef.current === eventSource
                && hiddenAt !== null
                && Date.now() - hiddenAt >= VISIBILITY_RESUME_STALE_MS
            ) {
                requestReconnect(true)
            }
        }

        if (typeof document !== 'undefined') {
            document.addEventListener('visibilitychange', onVisibilityChange)
        }

        return () => {
            clearTimeout(connectDeadlineTimer)
            if (typeof document !== 'undefined') {
                document.removeEventListener('visibilitychange', onVisibilityChange)
            }
            if (reconnectTimerRef.current) {
                clearTimeout(reconnectTimerRef.current)
                reconnectTimerRef.current = null
            }
            eventSource.close()
            if (eventSourceRef.current === eventSource) {
                eventSourceRef.current = null
            }
            isConnectedRef.current = false
            preExistingStreamingSegmentIdsRef.current.clear()
            awaitingInitialWindowSnapshotRef.current = false
            clearAllSegments()
            cancelScheduledFlush()
        }
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [options.baseUrl, options.enabled, options.sessionId, options.token, reconnectNonce])

    return snapshotState.sessionId === options.sessionId ? snapshotState.snapshot : EMPTY_SNAPSHOT
}
