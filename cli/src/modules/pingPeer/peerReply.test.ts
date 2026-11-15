import { describe, expect, it, vi } from 'vitest'
import type { AxiosInstance } from 'axios'
import { forwardPeerReply, supportsPeerReply } from './pingPeer'
import { peerReplyLocalId } from './peerReply'

type Poll = { thinking?: boolean; consumed?: boolean; reply?: string; ready?: boolean;
    peerActive?: boolean; callerActive?: boolean; later?: string; before?: string;
    staleReady?: boolean; peerStatus?: number; callerStatus?: number; flavor?: string;
    callerArchived?: boolean; batchBefore?: boolean; batchAfter?: boolean }
let sequence = 0
function harness(polls: Poll[], extra: { deliveryFailures?: number; timeoutMs?: number; cycle?: boolean } = {}) {
    const task = `task-${++sequence}`
    const caller = `caller-${sequence}`
    let tick = 0
    let time = 0
    const posts: Array<{ path: string; body: any; config: any }> = []
    const gets: Array<{ path: string; config: any }> = []
    const accepted = new Map<string, string>()
    let failures = extra.deliveryFailures ?? 0
    const current = () => polls[Math.min(Math.max(0, tick - 1), polls.length - 1)] ?? {}
    const http = {
        post: async (url: string, body: any, config: any) => {
            const path = new URL(url).pathname
            posts.push({ path, body, config })
            if (path === '/api/auth') return { status: 200, data: { token: 'test-jwt' } }
            if (path.endsWith('/queued-state')) return { status: 200, data: {
                queuedLocalIds: current().consumed ? [] : [task], indeterminateLocalIds: [],
                invokedLocalMessages: current().consumed ? [{ localId: task, invokedAt: 100 }] : []
            } }
            accepted.set(body.localId, body.text)
            if (failures-- > 0) throw new Error('response lost after acceptance')
            return { status: 200, data: { ok: true } }
        },
        get: async (url: string, config: any) => {
            const path = new URL(url).pathname
            gets.push({ path, config })
            const c = current()
            if (path.endsWith('/messages')) {
                const agent = (message: string) => ({ role: 'agent', content: { type: 'codex', data: { type: 'message', message } } })
                const ready = { role: 'agent', content: { type: 'event', data: { type: 'ready' } } }
                const rows: any[] = [
                    ...(c.before ? [{ id: 'before', seq: 9, createdAt: 90, content: agent(c.before) }] : []),
                    ...(c.batchBefore ? [{ id: 'batch-before', localId: 'batch-before', seq: 8, createdAt: 90, invokedAt: 100, content: { role: 'user', content: { text: 'another batched task' } } }] : []),
                    { id: 'task-row', localId: task, seq: 10, createdAt: 95, invokedAt: c.consumed ? 100 : null, content: { role: 'user', content: { type: 'text', text: 'task' } } },
                    ...(c.batchAfter ? [{ id: 'batch-after', localId: 'batch-after', seq: 11, createdAt: 96, invokedAt: 100, content: { role: 'user', content: { text: 'another batched task' } } }] : []),
                    ...(c.staleReady ? [{ id: 'stale-ready', seq: 11, createdAt: 101, content: ready }] : []),
                    ...(c.reply ? [{ id: 'reply', seq: 12, createdAt: 110, content: agent(c.reply) }] : []),
                    ...(c.later ? [{ id: 'later-user', seq: 13, createdAt: 115, invokedAt: 115, content: { role: 'user', content: { type: 'text', text: 'other task' } } }, { id: 'later-reply', seq: 14, createdAt: 120, content: agent(c.later) }] : []),
                    ...(c.ready ? [{ id: 'ready', seq: 15, createdAt: 125, content: ready }] : []),
                    { id: 'scheduled', seq: 16, createdAt: 130, scheduledAt: 500, invokedAt: null, content: { role: 'user', content: { text: 'future task' } } }
                ].filter(row => (row.invokedAt ?? row.createdAt) > config.params.afterAt || ((row.invokedAt ?? row.createdAt) === config.params.afterAt && row.seq > config.params.afterSeq))
                const page = rows.slice(0, 2)
                const tail = page.at(-1)
                return { status: 200, data: { messages: page, page: { epoch: 1, snapshotHeadAt: 130, snapshotHeadSeq: 16, hasMore: rows.length > 2,
                    nextAfterAt: extra.cycle ? config.params.afterAt : tail ? tail.invokedAt ?? tail.createdAt : null,
                    nextAfterSeq: extra.cycle ? config.params.afterSeq : tail?.seq } } }
            }
            const isCaller = path.endsWith(`/sessions/${caller}`)
            return { status: (isCaller ? c.callerStatus : c.peerStatus) ?? 200, data: { session: {
                id: isCaller ? caller : 'peer', active: (isCaller ? c.callerActive : c.peerActive) ?? true,
                thinking: isCaller ? false : c.thinking ?? false,
                metadata: { name: 'Peer', flavor: c.flavor ?? 'codex', ...(isCaller && c.callerArchived ? { lifecycleState: 'archived' } : {}) }
            } } }
        }
    } as unknown as AxiosInstance
    const options = { peerSessionId: 'peer', taskLocalId: task, callerSessionId: caller,
        apiUrl: 'http://hub.test', accessToken: 'test-token', http, now: () => time,
        sleep: async () => { tick++; time += 10_000 }, timeoutMs: extra.timeoutMs ?? 120_000 }
    const deliveries = () => posts.filter(p => p.path === `/api/sessions/${caller}/messages`)
    return { options, posts, gets, accepted, deliveries, caller, task }
}
const done = (reply = 'final'): Poll => ({ consumed: true, reply, ready: true })

describe('bounded peer reply forwarding', () => {
    it('posts a complete first-turn reply with one deterministic id, using queue only', async () => {
        const h = harness([{ before: 'old answer' }, { consumed: true, thinking: true }, done(), done()])
        await forwardPeerReply(h.options)
        expect(h.deliveries()).toHaveLength(1)
        expect(h.deliveries()[0].body).toEqual({ text: 'Reply from peer [Peer](/sessions/peer):\n\nfinal', localId: peerReplyLocalId(h.caller, 'peer', h.task) })
        expect(h.posts.some(p => /resume|steer|spawn/.test(p.path))).toBe(false)
        expect(h.gets.every(p => p.config.maxRedirects === 0 && p.config.maxContentLength > 0)).toBe(true)
    })
    it('never forwards the later task answer as this task reply', async () => {
        const h = harness([{ ...done('possibly partial'), later: 'UNRELATED' }])
        await forwardPeerReply(h.options)
        expect(h.deliveries()[0].body.text).toContain('attribution is ambiguous')
        expect(h.deliveries()[0].body.text).not.toContain('UNRELATED')
        expect(h.deliveries()[0].body.text).not.toContain('possibly partial')
    })
    it('excludes pre-steer output and handles a late ready before actual dispatch', async () => {
        const h = harness([
            { consumed: true, staleReady: true, before: 'old answer' },
            { consumed: true, staleReady: true },
            { consumed: true, staleReady: true, thinking: true },
            { ...done('answer to steer'), staleReady: true }, { ...done('answer to steer'), staleReady: true }
        ])
        await forwardPeerReply(h.options)
        expect(h.deliveries()[0].body.text).toContain('answer to steer')
        expect(h.deliveries()[0].body.text).not.toContain('old answer')
    })
    it('does not consider a stale ready alone completion', async () => {
        const h = harness([{ consumed: true, staleReady: true }], { timeoutMs: 40_000 })
        await forwardPeerReply(h.options)
        expect(h.deliveries()[0].body.text).toContain('bounded watch expired')
        expect(h.deliveries()[0].body.text).not.toContain('stopped without replying')
    })
    it('keeps an offline unconsumed peer queued without waking it', async () => {
        const h = harness([{ peerActive: false }, { peerActive: false }, done(), done()])
        await forwardPeerReply(h.options)
        expect(h.deliveries()[0].body.text).toContain('final')
        expect(h.posts.every(p => !p.path.endsWith('/resume'))).toBe(true)
    })
    it('reports a peer that stops after consuming the task', async () => {
        const h = harness([{ consumed: true, peerActive: false }, { consumed: true, peerActive: false }])
        await forwardPeerReply(h.options)
        expect(h.deliveries()[0].body.text).toContain('stopped without replying')
    })
    it('allows bounded caller reconnect grace but drops deleted, forbidden or archived callers', async () => {
        const reconnect = harness([{ callerActive: false }, { callerActive: false }, done(), done()])
        await forwardPeerReply(reconnect.options)
        expect(reconnect.deliveries()).toHaveLength(1)
        for (const poll of [{ callerStatus: 404 }, { callerStatus: 403 }, { callerArchived: true }]) {
            const h = harness([poll])
            await forwardPeerReply(h.options)
            expect(h.deliveries()).toHaveLength(0)
        }
    })
    it('drops long-offline callers and terminal peer failures without notification', async () => {
        for (const poll of [{ callerActive: false }, { peerStatus: 404 }, { peerStatus: 403 }, { flavor: 'pi' }]) {
            const h = harness([poll])
            await forwardPeerReply(h.options)
            expect(h.deliveries()).toHaveLength(0)
        }
        expect(supportsPeerReply('pi')).toBe(false)
    })
    it('treats transient server failures as retryable, not peer completion', async () => {
        const h = harness([{ peerStatus: 503 }, done(), done()])
        await forwardPeerReply(h.options)
        expect(h.deliveries()[0].body.text).toContain('final')
    })
    it('joins duplicate watches and deduplicates a later registration', async () => {
        const h = harness([done(), done()])
        const first = forwardPeerReply(h.options)
        expect(forwardPeerReply(h.options)).toBe(first)
        await first
        await forwardPeerReply(h.options)
        expect(h.deliveries()).toHaveLength(1)
    })
    it('retries a lost POST response with one accepted localId and a usable delivery budget after watch timeout', async () => {
        const h = harness([{}], { timeoutMs: 20_000, deliveryFailures: 1 })
        await forwardPeerReply(h.options)
        expect(h.deliveries()).toHaveLength(2)
        expect(h.accepted.size).toBe(1)
        expect(new Set(h.deliveries().map(p => p.body.localId)).size).toBe(1)
        expect(h.deliveries().every(p => p.config.timeout >= 10_000)).toBe(true)
    })
    it('enforces UTF-8 payload bounds with a visible truncation marker', async () => {
        const h = harness([done('中'.repeat(30_000)), done('中'.repeat(30_000))])
        await forwardPeerReply(h.options)
        const text = h.deliveries()[0].body.text
        expect(Buffer.byteLength(text)).toBeLessThanOrEqual(32 * 1024)
        expect(text).toContain('Reply truncated')
        expect(text).not.toContain('�')
    })
    it('rejects pagination cycles instead of reading or forwarding unbounded history', async () => {
        const h = harness([done()], { cycle: true })
        await forwardPeerReply(h.options)
        expect(h.deliveries()[0].body.text).toContain('bounded reply')
        expect(h.gets.filter(p => p.path.endsWith('/messages'))).toHaveLength(1)
    })
    it.each(['batchBefore', 'batchAfter'] as const)('does not attribute a mixed batch when the other task is %s', async (placement) => {
        const h = harness([{ ...done('MIXED ANSWER'), [placement]: true }])
        await forwardPeerReply(h.options)
        expect(h.deliveries()[0].body.text).toContain('attribution is ambiguous')
        expect(h.deliveries()[0].body.text).not.toContain('MIXED ANSWER')
    })
    it('allows a bounded serialized envelope for heavily escaped reply text', async () => {
        const h = harness([done('"\\\n'.repeat(15_000) + '中'.repeat(5_000)), done('"\\\n'.repeat(15_000) + '中'.repeat(5_000))])
        await forwardPeerReply(h.options)
        const delivery = h.deliveries()[0]
        expect(Buffer.byteLength(delivery.body.text)).toBeLessThanOrEqual(32 * 1024)
        expect(Buffer.byteLength(JSON.stringify(delivery.body))).toBeLessThan(delivery.config.maxBodyLength)
        expect(delivery.body.text).toContain('Reply truncated')
    })
    it('reports an oversized response as a bounded scan outcome, not a six-hour retry', async () => {
        const h = harness([done()])
        const get = h.options.http.get.bind(h.options.http)
        let scans = 0
        h.options.http.get = vi.fn(async (url, config) => {
            if (String(url).endsWith('/messages')) {
                scans++
                throw Object.assign(new Error('maxContentLength size limit exceeded'), { isAxiosError: true, code: 'ERR_BAD_RESPONSE' })
            }
            return await get(url, config)
        }) as typeof h.options.http.get
        await forwardPeerReply(h.options)
        expect(scans).toBe(1)
        expect(h.deliveries()[0].body.text).toContain('bounded reply')
    })
    it('rejects self watches and forwarded-result loops before any HTTP', async () => {
        const h = harness([done()])
        await expect(forwardPeerReply({ ...h.options, callerSessionId: 'peer' })).rejects.toThrow('distinct caller')
        await expect(forwardPeerReply({ ...h.options, taskLocalId: 'ping-peer-reply-loop' })).rejects.toThrow('original task')
        expect(h.posts).toHaveLength(0)
    })
    it('uses real bounded delivery retry delays after the watch deadline expires', async () => {
        vi.useFakeTimers()
        vi.setSystemTime(0)
        try {
            const h = harness([{}], { deliveryFailures: 1 })
            const promise = forwardPeerReply({ ...h.options, sleep: undefined, now: Date.now, timeoutMs: 1_000 })
            await vi.advanceTimersByTimeAsync(1_000)
            expect(h.deliveries()).toHaveLength(1)
            await vi.advanceTimersByTimeAsync(9_999)
            expect(h.deliveries()).toHaveLength(1)
            await vi.advanceTimersByTimeAsync(1)
            await promise
            expect(h.deliveries()).toHaveLength(2)
            expect(h.accepted.size).toBe(1)
            expect(vi.getTimerCount()).toBe(0)
        } finally { vi.useRealTimers() }
    })
    it('passes cancellation to in-flight HTTP and sends nothing when the bridge stops', async () => {
        const h = harness([done()])
        const controller = new AbortController()
        let started = false
        h.options.http.post = vi.fn(async (_url, _body, config) => {
            started = true
            expect(config?.signal).toBe(controller.signal)
            return await new Promise((_resolve, reject) => controller.signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true }))
        }) as typeof h.options.http.post
        const promise = forwardPeerReply({ ...h.options, signal: controller.signal })
        await vi.waitFor(() => expect(started).toBe(true))
        controller.abort()
        await promise
        expect(h.deliveries()).toHaveLength(0)
    })
    it('aborts its real polling timer immediately without posting', async () => {
        vi.useFakeTimers()
        try {
            const h = harness([done()])
            const controller = new AbortController()
            const promise = forwardPeerReply({ ...h.options, sleep: undefined, signal: controller.signal })
            const assertion = expect(promise).rejects.toThrow('aborted')
            controller.abort()
            await assertion
            expect(vi.getTimerCount()).toBe(0)
            expect(h.posts).toHaveLength(0)
        } finally { vi.useRealTimers() }
    })
})
