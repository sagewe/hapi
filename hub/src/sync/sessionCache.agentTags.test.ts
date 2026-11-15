import { describe, expect, it, spyOn } from 'bun:test'
import { Store } from '../store'
import { SessionCache } from './sessionCache'
import type { EventPublisher } from './eventPublisher'

function setup() {
    const store = new Store(':memory:')
    const events: unknown[] = []
    const cache = new SessionCache(store, { emit(event: unknown) { events.push(event) } } as EventPublisher)
    const create = async (id: string, tags: string[] = [], namespace = 'default') => {
        const session = cache.getOrCreateSession(id, { path: '/repo', host: 'host', name: 'Manual title', summary: { text: 'Manual summary', updatedAt: 1 } }, null, namespace)
        if (tags.length) await cache.renameSession(session.id, undefined, undefined, tags)
        return session.id
    }
    return { store, cache, create, events }
}

describe('SessionCache agent tag append', () => {
    it('appends new tags while retaining manual casing/order, title and lock', async () => {
        const { store, cache, create, events } = setup()
        try {
            const id = await create('locked', ['Manual', 'API'])
            await cache.renameSession(id, undefined, true)
            const before = store.sessions.getSession(id)!
            const result = await cache.appendSessionTags(id, 'default', [' api ', 'New', 'new'])
            expect(result).toEqual({ tags: ['Manual', 'API', 'New'], added: ['New'], skipped: [], limitReached: false })
            expect(store.sessions.getSession(id)?.metadata).toMatchObject({ name: 'Manual title', summary: { text: 'Manual summary' }, titleLocked: true, tags: result.tags })
            expect(store.sessions.getSession(id)?.updatedAt).toBe(before.updatedAt)
            expect(events.some((event: any) => event.type === 'session-updated' && event.data?.metadata?.tags?.includes('New'))).toBe(true)
            const version = store.sessions.getSession(id)!.metadataVersion
            expect((await cache.appendSessionTags(id, 'default', ['NEW'])).added).toEqual([])
            expect(store.sessions.getSession(id)!.metadataVersion).toBe(version)
        } finally { store.close() }
    })

    it('never replaces manual tags to make room for suggestions', async () => {
        const { store, cache, create } = setup()
        try {
            const manual = Array.from({ length: 19 }, (_, i) => `Manual${i}`)
            const id = await create('capacity', manual)
            expect(await cache.appendSessionTags(id, 'default', ['Last', 'Skip', 'Other'])).toEqual({
                tags: [...manual, 'Last'], added: ['Last'], skipped: ['Skip', 'Other'], limitReached: true
            })
            expect(await cache.appendSessionTags(id, 'default', ['New'])).toEqual({
                tags: [...manual, 'Last'], added: [], skipped: ['New'], limitReached: true
            })
        } finally { store.close() }
    })

    it('rebases on concurrent manual removals, title changes and lock changes without resurrecting stale fields', async () => {
        const { store, cache, create } = setup()
        try {
            const id = await create('manual-race', ['Manual', 'Removed'])
            const update = store.sessions.updateSessionMetadata.bind(store.sessions)
            let injected = false
            const spy = spyOn(store.sessions, 'updateSessionMetadata').mockImplementation((sid, metadata, version, namespace, options) => {
                if (!injected) {
                    injected = true
                    const row = store.sessions.getSession(sid)!
                    update(sid, { ...(row.metadata as object), name: 'Manual winner', summary: { text: 'Latest summary', updatedAt: 2 } }, row.metadataVersion, namespace,
                        { allowTitleUpdate: true, titleLocked: true, tags: ['Manual', 'Concurrent'] })
                }
                return update(sid, metadata, version, namespace, options)
            })
            const result = await cache.appendSessionTags(id, 'default', ['Suggested'])
            expect(spy).toHaveBeenCalledTimes(2)
            expect(result.tags).toEqual(['Manual', 'Concurrent', 'Suggested'])
            expect(store.sessions.getSession(id)?.metadata).toMatchObject({ name: 'Manual winner', titleLocked: true, summary: { text: 'Latest summary' }, tags: result.tags })
            spy.mockRestore()
        } finally { store.close() }
    })

    it('refreshes the capacity decision when a manual writer fills the last slot', async () => {
        const { store, cache, create } = setup()
        try {
            const id = await create('capacity-race', Array.from({ length: 19 }, (_, i) => `t${i}`))
            const update = store.sessions.updateSessionMetadata.bind(store.sessions)
            let injected = false
            const spy = spyOn(store.sessions, 'updateSessionMetadata').mockImplementation((sid, metadata, version, namespace, options) => {
                if (!injected) {
                    injected = true
                    const row = store.sessions.getSession(sid)!
                    update(sid, row.metadata, row.metadataVersion, namespace, { tags: [...(row.metadata as any).tags, 'UserLast'] })
                }
                return update(sid, metadata, version, namespace, options)
            })
            const result = await cache.appendSessionTags(id, 'default', ['AgentLast'])
            expect(result.added).toEqual([])
            expect(result.skipped).toEqual(['AgentLast'])
            expect(result.limitReached).toBe(true)
            expect(result.tags.at(-1)).toBe('UserLast')
            spy.mockRestore()
        } finally { store.close() }
    })

    it('merges concurrent append callers rather than replacing their additions', async () => {
        const { store, cache, create } = setup()
        try {
            const id = await create('append-race', ['Manual'])
            const second = new SessionCache(store, { emit() {} } as unknown as EventPublisher)
            second.refreshSession(id)
            await Promise.all([cache.appendSessionTags(id, 'default', ['A']), second.appendSessionTags(id, 'default', ['B'])])
            expect((store.sessions.getSession(id)?.metadata as any).tags).toEqual(['Manual', 'A', 'B'])
        } finally { store.close() }
    })

    it('does not let sparse/raw agent metadata replace tags or unlock the title', async () => {
        const { store, cache, create } = setup()
        try {
            const id = await create('raw-guard', ['Manual'])
            await cache.renameSession(id, undefined, true)
            await cache.appendSessionTags(id, 'default', ['Agent'])
            const row = store.sessions.getSession(id)!
            expect(store.sessions.updateSessionMetadata(id, { tags: ['Forged'], titleLocked: false, name: 'Forged title' }, row.metadataVersion, 'default').result).toBe('success')
            expect(store.sessions.getSession(id)?.metadata).toMatchObject({ tags: ['Manual', 'Agent'], titleLocked: true, name: 'Manual title' })
        } finally { store.close() }
    })

    it('checks namespace and missing sessions in the core methods', async () => {
        const { store, cache, create } = setup()
        try {
            const id = await create('private', ['Secret'], 'private')
            expect(() => cache.getSessionTagsContext(id, 'default')).toThrow('access denied')
            await expect(cache.appendSessionTags(id, 'default', ['Public'])).rejects.toThrow('access denied')
            await expect(cache.appendSessionTags('missing', 'default', ['Public'])).rejects.toThrow('not found')
        } finally { store.close() }
    })

    it('bounds CAS retries and refuses invalid direct-call suggestions', async () => {
        const { store, cache, create } = setup()
        try {
            const id = await create('retry')
            const spy = spyOn(store.sessions, 'updateSessionMetadata').mockImplementation(() => ({ result: 'version-mismatch', version: 99, value: {} }))
            await expect(cache.appendSessionTags(id, 'default', ['New'])).rejects.toThrow('modified concurrently')
            expect(spy).toHaveBeenCalledTimes(5)
            spy.mockRestore()
            await expect(cache.appendSessionTags(id, 'default', ['a','b','c','d'])).rejects.toThrow()
        } finally { store.close() }
    })
})

describe('namespace tag vocabulary', () => {
    it('sorts by session frequency then stable text, collapses casing and preserves current spelling', async () => {
        const { store, cache, create } = setup()
        try {
            const id = await create('context', ['aPi', 'Current'])
            await create('other', ['API', 'Beta'])
            await create('third', ['beta', 'Alpha'])
            await create('foreign', ['DoNotLeak'], 'private')
            expect(cache.getSessionTagsContext(id, 'default')).toEqual({ tags: ['aPi', 'Current'], availableTags: ['aPi', 'Beta', 'Alpha', 'Current'], titleLocked: false, truncated: false })
        } finally { store.close() }
    })

    it('caps vocabulary at 200 while retaining rare current tags and never reading another namespace', async () => {
        const { store, cache, create } = setup()
        try {
            const id = await create('rare', ['VeryRare'])
            for (let i = 0; i < 205; i++) {
                const tag = `tag${String(i).padStart(3, '0')}`
                await create(`v${i}`, [tag])
                await create(`v${i}-second`, [tag])
            }
            await create('foreign', ['Secret'], 'private')
            const context = cache.getSessionTagsContext(id, 'default')
            expect(context.availableTags).toHaveLength(200)
            expect(context.availableTags).toContain('VeryRare')
            expect(context.availableTags.at(-1)).toBe('VeryRare')
            expect(context.availableTags).not.toContain('tag204')
            expect(context.availableTags).not.toContain('Secret')
            expect(context.truncated).toBe(true)
        } finally { store.close() }
    })
})
