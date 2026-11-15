/** Bounded, opt-in first-turn reply notification. No resume, steer or recursive watches. */
import { createHash } from 'node:crypto'
import axios, { type AxiosInstance } from 'axios'
import { extractAssistantPlainText, isObject } from '@hapi/protocol'
import { buildHubRequestHeaders } from '@/api/hubExtraHeaders'
import { isPeerToolsDisabled } from '@/modules/common/peerTools'
import { resolveAccessToken, resolveApiUrl } from './pingPeer'

const POLL_MS = 10_000
const TIMEOUT_MS = 6 * 60 * 60 * 1000
const MAX_POLLS = 2160
const MAX_PAGES = 20
const MAX_ROWS = 4000
const MAX_REPLY_BYTES = 32 * 1024
const OFFLINE_GRACE_POLLS = 6
const FLAVORS = new Set(['claude', 'codex', 'cursor', 'opencode', 'copilot', 'kimi', 'grok', 'dsh', 'agy'])
const activeWatches = new Map<string, Promise<void>>()
const completedWatches = new Map<string, number>()

export function supportsPeerReply(flavor: string | null | undefined): boolean {
    return FLAVORS.has(flavor ?? 'claude')
}

export type ForwardPeerReplyOptions = {
    peerSessionId: string
    taskLocalId: string
    callerSessionId: string
    apiUrl?: string
    accessToken?: string
    http?: AxiosInstance
    signal?: AbortSignal
    sleep?: (ms: number) => Promise<void>
    now?: () => number
    /** Test/internal limits only; MCP callers cannot alter these bounds. */
    timeoutMs?: number
}

class ReplyWatchError extends Error {
    constructor(readonly terminal: boolean, readonly status?: number, readonly bounded = false) {
        super(status ? `Peer reply request failed (HTTP ${status})` : 'Peer reply response exceeded safe bounds')
    }
}

function abortError(): Error { return new Error('Peer reply watch aborted') }

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
    return new Promise((resolve, reject) => {
        if (signal?.aborted) return reject(abortError())
        const onAbort = () => { clearTimeout(timer); reject(abortError()) }
        const timer = setTimeout(() => { signal?.removeEventListener('abort', onAbort); resolve() }, ms)
        timer.unref?.()
        signal?.addEventListener('abort', onAbort, { once: true })
    })
}

function clip(text: string, maxBytes = MAX_REPLY_BYTES): string {
    if (Buffer.byteLength(text, 'utf8') <= maxBytes) return text
    const suffix = '\n\n[Reply truncated; inspect the peer session for the full text.]'
    const bytes = Buffer.from(text, 'utf8').subarray(0, maxBytes - Buffer.byteLength(suffix))
    // A partial UTF-8 character is never emitted.
    return bytes.toString('utf8').replace(/\uFFFD$/, '') + suffix
}

type Row = {
    id: string; localId?: string; role: 'user' | 'agent' | 'ready'; text: string
    at: number; seq: number; invokedAt: number | null
}

function rowOf(value: unknown): Row | null {
    if (!isObject(value) || !isObject(value.content)) return null
    const content = value.content
    const invokedAt = typeof value.invokedAt === 'number' && Number.isFinite(value.invokedAt) ? value.invokedAt : null
    if (invokedAt === null && typeof value.scheduledAt === 'number') return null
    const createdAt = typeof value.createdAt === 'number' ? value.createdAt : null
    if (createdAt === null || !Number.isFinite(createdAt) || typeof value.seq !== 'number' || !Number.isSafeInteger(value.seq)) return null
    const ready = content.role === 'agent' && isObject(content.content) && content.content.type === 'event'
        && isObject(content.content.data) && content.content.data.type === 'ready'
    const role = content.role === 'user' ? 'user' : content.role === 'agent' ? (ready ? 'ready' : 'agent') : null
    if (!role) return null
    // Only assistant prose, never tool result/reasoning fallback, can be a reply.
    const text = role === 'agent' ? extractAssistantPlainText(content.content) ?? '' : ''
    return { id: typeof value.id === 'string' ? value.id : '',
        localId: typeof value.localId === 'string' ? value.localId : undefined,
        role, text: clip(text), at: invokedAt ?? createdAt, seq: value.seq, invokedAt }
}

function compare(a: { at: number; seq: number }, b: { at: number; seq: number }): number {
    return a.at - b.at || a.seq - b.seq
}

/** One deterministic submit identity across retries, duplicate MCP transports and process restarts. */
export function peerReplyLocalId(caller: string, peer: string, task: string): string {
    return `ping-peer-reply-${createHash('sha256').update(JSON.stringify([caller, peer, task])).digest('hex')}`
}

export function forwardPeerReply(options: ForwardPeerReplyOptions): Promise<void> {
    if (isPeerToolsDisabled()) return Promise.reject(new Error('Peer tools are disabled'))
    if (!options.callerSessionId || !options.peerSessionId || !options.taskLocalId
        || options.callerSessionId === options.peerSessionId || options.taskLocalId.startsWith('ping-peer-reply-')) {
        return Promise.reject(new Error('Reply watches require a distinct caller, peer and original task'))
    }
    const apiUrl = resolveApiUrl(options.apiUrl)
    const accessToken = resolveAccessToken(options.accessToken)
    const key = createHash('sha256').update(JSON.stringify([apiUrl, accessToken, options.callerSessionId, options.peerSessionId, options.taskLocalId])).digest('hex')
    const now = options.now ?? Date.now
    for (const [id, at] of completedWatches) if (now() - at > 24 * 60 * 60 * 1000) completedWatches.delete(id)
    if (completedWatches.has(key)) return Promise.resolve()
    const existing = activeWatches.get(key)
    if (existing) return existing
    if (activeWatches.size >= 128) return Promise.reject(new Error('Peer reply watch capacity reached; use inspect_peer'))
    const pending = watch({ ...options }, apiUrl, accessToken).then(posted => {
        if (posted) {
            completedWatches.set(key, now())
            if (completedWatches.size > 512) completedWatches.delete(completedWatches.keys().next().value!)
        }
    }).finally(() => { if (activeWatches.get(key) === pending) activeWatches.delete(key) })
    activeWatches.set(key, pending)
    return pending
}

async function watch(options: ForwardPeerReplyOptions, apiUrl: string, accessToken: string): Promise<boolean> {
    const http = options.http ?? axios
    const now = options.now ?? Date.now
    const timeout = Math.min(TIMEOUT_MS, Math.max(1, options.timeoutMs ?? TIMEOUT_MS))
    const deadline = now() + timeout
    const signal = options.signal
    let posting = false
    const pause = async () => {
        if (signal?.aborted) throw abortError()
        if (options.sleep) await options.sleep(POLL_MS)
        else await sleep(Math.min(POLL_MS, Math.max(1, deadline + (posting ? 60_000 : 0) - now())), signal)
        if (signal?.aborted) throw abortError()
    }
    const request = async (method: 'get' | 'post', path: string, jwt?: string, body?: unknown, params?: object) => {
        if (signal?.aborted) throw abortError()
        const config = { headers: jwt ? buildHubRequestHeaders({ Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' })
            : buildHubRequestHeaders({ 'Content-Type': 'application/json' }),
            signal, timeout: Math.min(20_000, Math.max(1, deadline + (posting ? 60_000 : 0) - now())), maxRedirects: 0,
            maxContentLength: 4 * 1024 * 1024, maxBodyLength: MAX_REPLY_BYTES * 6 + 4096,
            validateStatus: () => true, params }
        let response
        try {
            response = method === 'get' ? await http.get(apiUrl + path, config) : await http.post(apiUrl + path, body, config)
        } catch (error) {
            if (axios.isAxiosError(error) && error.code === 'ERR_BAD_RESPONSE' && /maxContentLength|size limit/i.test(error.message)) {
                throw new ReplyWatchError(true, undefined, true)
            }
            throw error
        }
        if (response.status < 200 || response.status >= 300) {
            throw new ReplyWatchError([400, 401, 403, 404, 410].includes(response.status), response.status)
        }
        return response.data
    }
    const auth = async (): Promise<string> => {
        const data = await request('post', '/api/auth', undefined, { accessToken })
        if (typeof data?.token !== 'string' || !data.token) throw new ReplyWatchError(true)
        return data.token
    }
    const session = async (jwt: string, id: string) => {
        const data = await request('get', `/api/sessions/${encodeURIComponent(id)}`, jwt)
        if (!isObject(data?.session) || data.session.id !== id) throw new ReplyWatchError(true)
        return data.session
    }
    // Consumption ties this watch to one transcript generation across polls.
    // A rewind may retain the task localId while replacing all reply evidence.
    let consumedTaskEpoch: unknown
    const rowsAfter = async (jwt: string, at: number): Promise<Row[]> => {
        let cursor = { at: Math.max(0, at - 1), seq: Number.MAX_SAFE_INTEGER }
        const seen = new Set<string>()
        const result: Row[] = []
        let epoch: unknown
        let snapshot: { at: number; seq: number } | undefined
        for (let pageNo = 0; pageNo < MAX_PAGES; pageNo++) {
            const data = await request('get', `/api/sessions/${encodeURIComponent(options.peerSessionId)}/messages`, jwt,
                undefined, { limit: 200, afterAt: cursor.at, afterSeq: cursor.seq, ...(epoch === undefined ? {} : { epoch }), ...(snapshot ? { untilAt: snapshot.at, untilSeq: snapshot.seq } : {}) })
            const page = data?.page
            if (!isObject(page) || !Number.isSafeInteger(page.epoch) || page.reset === true || (epoch !== undefined && page.epoch !== epoch)) throw new ReplyWatchError(true, undefined, true)
            if (consumedTaskEpoch !== undefined && page.epoch !== consumedTaskEpoch) {
                throw new ReplyWatchError(true, undefined, true)
            }
            consumedTaskEpoch ??= page.epoch
            epoch = page.epoch
            if (Number.isFinite(page.snapshotHeadAt) && Number.isSafeInteger(page.snapshotHeadSeq)) {
                const head = { at: page.snapshotHeadAt as number, seq: page.snapshotHeadSeq as number }
                if (snapshot && compare(head, snapshot) !== 0) throw new ReplyWatchError(true, undefined, true)
                snapshot ??= head
            } else if (page.hasMore === true) throw new ReplyWatchError(true, undefined, true)
            const pageRows = Array.isArray(data?.messages) ? data.messages : []
            if (pageRows.length > 200) throw new ReplyWatchError(true, undefined, true)
            for (const value of pageRows) {
                const row = rowOf(value)
                if (row && (compare(row, cursor) <= 0 || (snapshot && compare(row, snapshot) > 0))) throw new ReplyWatchError(true, undefined, true)
                if (row && !seen.has(row.id)) { result.push(row); seen.add(row.id) }
            }
            if (result.length > MAX_ROWS) throw new ReplyWatchError(true, undefined, true)
            if (page?.hasMore !== true) return result.sort(compare)
            const nextAt = page.nextAfterAt
            const nextSeq = page.nextAfterSeq
            if (typeof nextAt !== 'number' || !Number.isFinite(nextAt) || typeof nextSeq !== 'number' || !Number.isSafeInteger(nextSeq) || nextSeq < 1) {
                throw new ReplyWatchError(true, undefined, true)
            }
            const next = { at: nextAt, seq: nextSeq }
            if (compare(next, cursor) <= 0) {
                throw new ReplyWatchError(true, undefined, true)
            }
            cursor = next
        }
        throw new ReplyWatchError(true, undefined, true)
    }
    let peerName = options.peerSessionId.slice(0, 8)
    let notification: string | null = null
    let offlineCallerPolls = 0
    let stableEnd = ''
    let endedPolls = 0
    let sawThinking = false
    let consumed = false
    const staleReadyIds = new Set<string>()
    const link = () => `[${peerName.replace(/[\[\]\r\n]/g, ' ')}](/sessions/${encodeURIComponent(options.peerSessionId)})`
    for (let poll = 0; poll < MAX_POLLS && now() < deadline && !signal?.aborted; poll++) {
        await pause()
        if (now() >= deadline) break
        try {
            const jwt = await auth()
            const caller = await session(jwt, options.callerSessionId)
            if (isObject(caller.metadata) && caller.metadata.lifecycleState === 'archived') return false
            if (!caller.active) {
                if (++offlineCallerPolls >= OFFLINE_GRACE_POLLS) return false
                continue
            }
            offlineCallerPolls = 0
            const peer = await session(jwt, options.peerSessionId)
            if (isObject(peer.metadata)) {
                const name = peer.metadata.name
                if (typeof name === 'string' && name.trim()) peerName = name.slice(0, 255)
                if (!supportsPeerReply(typeof peer.metadata.flavor === 'string' ? peer.metadata.flavor : null)) return false
            }
            const state = await request('post', `/api/sessions/${encodeURIComponent(options.peerSessionId)}/messages/queued-state`, jwt, { localIds: [options.taskLocalId] })
            if (!isObject(state) || !Array.isArray(state.queuedLocalIds) || !Array.isArray(state.indeterminateLocalIds) || !Array.isArray(state.invokedLocalMessages)) throw new ReplyWatchError(true)
            const invoked = Array.isArray(state?.invokedLocalMessages)
                ? state.invokedLocalMessages.find((v: unknown) => isObject(v) && v.localId === options.taskLocalId) : null
            if (!invoked || !Number.isFinite(invoked.invokedAt)) {
                const queued = [...(Array.isArray(state?.queuedLocalIds) ? state.queuedLocalIds : []), ...(Array.isArray(state?.indeterminateLocalIds) ? state.indeterminateLocalIds : [])]
                if (!queued.includes(options.taskLocalId)) { notification = `The task sent to peer ${link()} was canceled or is no longer available.`; break }
                // Offline before consumption is not cancellation; never wake it.
                continue
            }
            consumed = true
            const rows = await rowsAfter(jwt, invoked.invokedAt)
            const index = rows.findIndex(r => r.localId === options.taskLocalId && r.role === 'user' && r.invokedAt === invoked.invokedAt)
            if (index < 0) { notification = `Cannot safely locate the consumed task in peer ${link()}; inspect_peer for its reply.`; break }
            if (rows.some(row => row.role === 'user' && row.id !== rows[index].id && row.invokedAt === invoked.invokedAt)) {
                notification = `Peer ${link()} consumed this task in a batch with another prompt; reply attribution is ambiguous. Use inspect_peer; no mixed-task answer was forwarded.`
                break
            }
            const after = rows.slice(index + 1)
            // Immediate ACK may precede model dispatch. A late ready from the
            // previous turn is not evidence that the consumed task completed.
            if (!sawThinking) {
                let hasPostTaskText = false
                for (const row of after) {
                    if (row.role === 'agent' && row.text.trim()) hasPostTaskText = true
                    if (row.role === 'ready' && !hasPostTaskText) staleReadyIds.add(row.id)
                }
            }
            const boundary = after.findIndex(r => (r.role === 'ready' && !staleReadyIds.has(r.id)) || (r.role === 'user' && r.invokedAt !== null && r.invokedAt !== invoked.invokedAt))
            const bounded = boundary < 0 ? after : after.slice(0, boundary)
            const next = boundary < 0 ? null : after[boundary]
            const reply = bounded.filter(r => r.role === 'agent' && r.text.trim()).at(-1)
            if (peer.thinking) sawThinking = true
            const ambiguous = next?.role === 'user'
            const ended = !peer.thinking && (next?.role === 'ready' || !peer.active)
            // A stale ready event without any new output/start evidence cannot
            // prove this task ran. Poll confirmation alone is not evidence.
            const evidence = Boolean(reply) || sawThinking || !peer.active
            const candidate = ended && evidence ? JSON.stringify([next?.id, reply?.id, reply?.text, ambiguous, peer.active]) : ''
            endedPolls = candidate && candidate === stableEnd ? endedPolls + 1 : candidate ? 1 : 0
            stableEnd = candidate
            if (ambiguous) {
                notification = `Peer ${link()} consumed another prompt before a provable task boundary; reply attribution is ambiguous. Use inspect_peer; no unrelated answer was forwarded.`
                break
            }
            if (endedPolls >= 2) {
                notification = reply ? `Reply from peer ${link()}:\n\n${reply.text}` : `Peer ${link()} stopped without replying to the consumed task.`
                break
            }
        } catch (error) {
            if (signal?.aborted) return false
            if (error instanceof ReplyWatchError && error.bounded) {
                notification = `Cannot safely read a bounded reply from peer ${link()}; use inspect_peer for its result.`
                break
            }
            if (error instanceof ReplyWatchError && error.terminal) return false
            // Transient network/5xx errors never become completion or cancellation.
            endedPolls = 0; stableEnd = ''
        }
    }
    if (signal?.aborted) return false
    notification ??= `Peer ${link()} did not reach a provable first-turn reply before the bounded watch expired (${consumed ? 'task consumed' : 'task not yet consumed'}). Use inspect_peer.`
    posting = true
    const localId = peerReplyLocalId(options.callerSessionId, options.peerSessionId, options.taskLocalId)
    for (let attempt = 0; attempt < OFFLINE_GRACE_POLLS && now() < deadline + 60_000 && !signal?.aborted; attempt++) {
        try {
            const jwt = await auth()
            const caller = await session(jwt, options.callerSessionId)
            if (isObject(caller.metadata) && caller.metadata.lifecycleState === 'archived') return false
            if (!caller.active) { await pause(); continue }
            const result = await request('post', `/api/sessions/${encodeURIComponent(options.callerSessionId)}/messages`, jwt,
                { text: clip(notification), localId })
            if (!isObject(result) || result.ok !== true) throw new ReplyWatchError(false)
            return true
        } catch (error) {
            if (signal?.aborted || (error instanceof ReplyWatchError && error.terminal)) return false
            if (attempt === OFFLINE_GRACE_POLLS - 1) throw error
            await pause()
        }
    }
    return false
}
