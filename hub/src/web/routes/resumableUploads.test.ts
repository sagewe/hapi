import { afterEach, describe, expect, it } from 'bun:test'
import { Hono } from 'hono'
import { createHash } from 'node:crypto'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { SyncEngine } from '../../sync/syncEngine'
import type { WebAppEnv } from '../middleware/auth'
import { ResumableUploads, UPLOAD_CHUNK_BYTES } from '../../uploads/resumable'
import { createResumableUploadRoutes } from './resumableUploads'

const roots: string[] = []
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))) })
async function setup() {
    const root = await mkdtemp(join(tmpdir(), 'hapi-upload-route-'))
    roots.push(root)
    let active = true
    let deliveries = 0
    const engine = {
        resolveSessionAccess: (id: string, namespace: string) => id === 's' && namespace === 'owner'
            ? { ok: true, sessionId: id, session: { active } }
            : { ok: false, reason: 'access-denied' },
        uploadFile: async (_id: string, _filename: string, content: string) => {
            deliveries++
            expect(Buffer.from(content, 'base64')).toEqual(Buffer.from('abcdef'))
            return { success: true, path: '/runner/file' }
        }
    } as unknown as SyncEngine
    const app = new Hono<WebAppEnv>()
    app.use('*', async (c, next) => { c.set('namespace', c.req.header('X-Test-Namespace') ?? 'owner'); await next() })
    app.route('/api', createResumableUploadRoutes(() => engine, new ResumableUploads(root)))
    return { app, inactive: () => { active = false }, deliveries: () => deliveries }
}
const id = 'a'.repeat(64)
const path = `/api/sessions/s/uploads/${id}`
const metadata = { filename: 'movie.mp4', mimeType: 'video/mp4', size: 6,
    sha256: createHash('sha256').update('abcdef').digest('hex') }
const start = { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(metadata) }

describe('resumable upload HTTP routes', () => {
    it('accepts bounded binary chunks, recovers an offset conflict, and caches completion', async () => {
        const { app, deliveries } = await setup()
        expect(await (await app.request(path, start)).json()).toMatchObject({ offset: 0 })
        const chunk = { method: 'PUT', headers: { 'Content-Type': 'application/octet-stream' }, body: 'abc' }
        expect(await (await app.request(path + '/chunk?offset=0', chunk)).json()).toMatchObject({ offset: 3 })
        expect((await app.request(path + '/chunk?offset=0', chunk)).status).toBe(409)
        expect(await (await app.request(path, start)).json()).toMatchObject({ offset: 3 })
        expect((await app.request(path + '/complete', { method: 'POST' })).status).toBe(409)
        await app.request(path + '/chunk?offset=3', { ...chunk, body: 'def' })
        for (let i = 0; i < 2; i++) {
            expect(await (await app.request(path + '/complete', { method: 'POST' })).json()).toEqual({ success: true, path: '/runner/file' })
        }
        expect(deliveries()).toBe(1)
    })

    it('authorizes every operation and preserves inactive-session recovery', async () => {
        const { app, inactive } = await setup()
        await app.request(path, start)
        expect((await app.request(path, { ...start, headers: { ...start.headers, 'X-Test-Namespace': 'other' } })).status).toBe(403)
        expect((await app.request(path.replace('/s/', '/other/'), start)).status).toBe(403)
        inactive()
        const response = await app.request(path + '/complete', { method: 'POST' })
        expect(response.status).toBe(409)
        expect(await response.json()).toMatchObject({ code: 'session_inactive' })
    })

    it('rejects oversized metadata, oversized chunks, invalid offsets and ids', async () => {
        const { app } = await setup()
        expect((await app.request(path, { ...start, body: 'x'.repeat(4097) })).status).toBe(413)
        await app.request(path, start)
        expect((await app.request(path + '/chunk?offset=0', { method: 'PUT', body: Buffer.alloc(UPLOAD_CHUNK_BYTES + 1) })).status).toBe(413)
        expect((await app.request(path + '/chunk?offset=-1', { method: 'PUT', body: 'a' })).status).toBe(400)
        expect((await app.request(path.replace(id, 'bad-id'), start)).status).toBe(400)
    })
})
