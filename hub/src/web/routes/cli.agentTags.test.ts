import { beforeAll, describe, expect, it, spyOn } from 'bun:test'
import { Hono } from 'hono'
import { SessionTagsContextSchema, AgentSessionTagsResultSchema } from '@hapi/protocol'
import { createConfiguration } from '../../configuration'
import { Store } from '../../store'
import { RpcRegistry } from '../../socket/rpcRegistry'
import { SyncEngine } from '../../sync/syncEngine'
import { createCliRoutes } from './cli'

beforeAll(async () => {
    const config = await createConfiguration()
    config._setCliApiToken('test-token', 'env', false)
})

function setup() {
    const store = new Store(':memory:')
    const engine = new SyncEngine(store, {} as never, new RpcRegistry(), { broadcast() {} } as never)
    const app = new Hono()
    app.route('/cli', createCliRoutes(() => engine))
    const create = async (tag: string, tags: string[] = [], namespace = 'default') => {
        const session = engine.getOrCreateSession(tag, { path: '/repo', host: 'host', name: 'Manual title' }, null, namespace)
        await engine.renameSession(session.id, undefined, true, tags)
        return session.id
    }
    const headers = (namespace = 'default') => ({ authorization: `Bearer test-token${namespace === 'default' ? '' : `:${namespace}`}`, 'content-type': 'application/json' })
    return { store, engine, app, create, headers, close: () => { engine.stop(); store.close() } }
}

describe('CLI agent tag APIs', () => {
    it('reads namespace-scoped context and appends without changing locked user fields', async () => {
        const h = setup()
        try {
            const id = await h.create('target', ['Manual'])
            await h.create('other', ['Shared'])
            await h.create('foreign', ['Secret'], 'private')
            const response = await h.app.request(`/cli/sessions/${id}/tags`, { headers: h.headers() })
            expect(response.status).toBe(200)
            expect(SessionTagsContextSchema.parse(await response.json())).toEqual({ tags: ['Manual'], availableTags: ['Manual', 'Shared'], titleLocked: true, truncated: false })
            const append = await h.app.request(`/cli/sessions/${id}/tags`, { method: 'POST', headers: h.headers(), body: JSON.stringify({ tags: [' manual ', 'Created', 'created'] }) })
            expect(append.status).toBe(200)
            expect(AgentSessionTagsResultSchema.parse(await append.json())).toEqual({ tags: ['Manual', 'Created'], added: ['Created'], skipped: [], limitReached: false })
            expect(h.store.sessions.getSession(id)?.metadata).toMatchObject({ name: 'Manual title', titleLocked: true })
        } finally { h.close() }
    })

    it('requires the existing CLI token and enforces target namespace on reads and writes', async () => {
        const h = setup()
        try {
            const id = await h.create('private', ['Secret'], 'private')
            for (const method of ['GET', 'POST']) {
                const init = { method, body: method === 'POST' ? JSON.stringify({ tags: ['Forged'] }) : undefined }
                expect((await h.app.request(`/cli/sessions/${id}/tags`, init)).status).toBe(401)
                expect((await h.app.request(`/cli/sessions/${id}/tags`, { ...init, headers: { authorization: 'Bearer invalid' } })).status).toBe(401)
                const denied = await h.app.request(`/cli/sessions/${id}/tags`, { ...init, headers: h.headers() })
                expect(denied.status).toBe(403)
                expect(await denied.text()).not.toContain('Secret')
            }
            expect((await h.app.request(`/cli/sessions/${id}/tags`, { headers: h.headers('private') })).status).toBe(200)
            expect((h.store.sessions.getSession(id)?.metadata as any).tags).toEqual(['Secret'])
            expect((await h.app.request('/cli/sessions/missing/tags', { headers: h.headers() })).status).toBe(404)
        } finally { h.close() }
    })

    it('rejects malformed, empty, oversized and unrelated-field bodies without mutation', async () => {
        const h = setup()
        try {
            const id = await h.create('validation', ['Manual'])
            const version = h.store.sessions.getSession(id)!.metadataVersion
            for (const body of ['not json', JSON.stringify({ tags: [] }), JSON.stringify({ tags: ['  '] }), JSON.stringify({ tags: ['x'.repeat(65)] }), JSON.stringify({ tags: ['a','b','c','d'] }), JSON.stringify({ tags: ['Good'], titleLocked: false })]) {
                const response = await h.app.request(`/cli/sessions/${id}/tags`, { method: 'POST', headers: h.headers(), body })
                expect(response.status).toBe(400)
            }
            expect(h.store.sessions.getSession(id)!.metadataVersion).toBe(version)
        } finally { h.close() }
    })

    it('reports skipped suggestions at capacity instead of removing manual tags', async () => {
        const h = setup()
        try {
            const tags = Array.from({ length: 20 }, (_, i) => `Manual${i}`)
            const id = await h.create('full', tags)
            const response = await h.app.request(`/cli/sessions/${id}/tags`, { method: 'POST', headers: h.headers(), body: JSON.stringify({ tags: ['New'] }) })
            expect(response.status).toBe(200)
            expect(await response.json()).toEqual({ tags, added: [], skipped: ['New'], limitReached: true })
        } finally { h.close() }
    })

    it('maps persistent CAS contention to an explicit 409', async () => {
        const h = setup()
        try {
            const id = await h.create('conflict', ['Manual'])
            const spy = spyOn(h.store.sessions, 'updateSessionMetadata').mockImplementation(() => ({ result: 'version-mismatch', version: 99, value: {} }))
            const response = await h.app.request(`/cli/sessions/${id}/tags`, { method: 'POST', headers: h.headers(), body: JSON.stringify({ tags: ['New'] }) })
            expect(response.status).toBe(409)
            expect(spy).toHaveBeenCalledTimes(5)
            spy.mockRestore()
        } finally { h.close() }
    })

    it('reports an unavailable engine without invoking tag operations', async () => {
        const app = new Hono()
        app.route('/cli', createCliRoutes(() => null))
        for (const method of ['GET', 'POST']) {
            expect((await app.request('/cli/sessions/missing/tags', { method, headers: { authorization: 'Bearer test-token' } })).status).toBe(503)
        }
    })
})
