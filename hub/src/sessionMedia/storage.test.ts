import { afterEach, describe, expect, it } from 'bun:test'
import { mkdtemp, rm, stat, symlink } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { SignJWT } from 'jose'
import { Hono } from 'hono'
import { SessionMediaStore } from './storage'
import { createGitRoutes } from '../web/routes/git'
import { createAuthMiddleware, type WebAppEnv } from '../web/middleware/auth'
import type { SyncEngine } from '../sync/syncEngine'

const dirs: string[] = []
afterEach(async () => { await Promise.all(dirs.splice(0).map(dir => rm(dir, { recursive: true, force: true }))) })
async function fixture() {
    const root = await mkdtemp(join(tmpdir(), 'hapi-media-')); dirs.push(root)
    const secret = new TextEncoder().encode('test-key-with-enough-entropy-for-signing')
    const media = new SessionMediaStore(root)
    let offline = false
    const engine = {
        resolveSessionAccess: (id: string, ns: string) => ns !== 'owner' ? { ok: false, reason: 'access-denied' }
            : { ok: true, sessionId: id, session: { id, namespace: 'owner', active: !offline } },
        readGeneratedImage: async () => offline ? { success: false } : { success: true, content: Buffer.from('report').toString('base64'), mimeType: 'application/pdf', fileName: '报告.pdf' }
    } as unknown as SyncEngine
    const app = () => {
        const app = new Hono<WebAppEnv>()
        app.use('/api/*', createAuthMiddleware(secret))
        app.route('/api', createGitRoutes(() => engine, new SessionMediaStore(root)))
        return app
    }
    const token = async (ns = 'owner') => new SignJWT({ uid: 1, ns }).setProtectedHeader({ alg: 'HS256' }).setExpirationTime('1h').sign(secret)
    const request = async (path: string, ns = 'owner') => app().request(`/api/sessions/${path}`, { headers: { Authorization: `Bearer ${await token(ns)}` } })
    return { root, media, app, request, offline: () => { offline = true } }
}
describe('durable session media', () => {
    it('authenticates both index and originals, rejects another namespace', async () => {
        const f = await fixture()
        for (const suffix of ['case-files', 'uploads/file1', 'generated-images/report']) {
            expect((await f.app().request(`/api/sessions/session1/${suffix}`)).status).toBe(401)
            expect((await f.request(`session1/${suffix}`, 'other')).status).toBe(403)
        }
        expect(await (await f.request('session1/case-files')).json()).toEqual({ files: [] })
    })
    it('persists on first retrieval and returns original bytes after restart without a CLI', async () => {
        const f = await fixture()
        expect((await f.request('session1/generated-images/report')).status).toBe(200)
        f.offline()
        const result = await f.request('session1/generated-images/report')
        expect(result.status).toBe(200); expect(await result.text()).toBe('report')
        const files = await (await f.request('session1/case-files')).json() as { files: Array<{ id: string }> }
        expect(files.files[0]).toMatchObject({ id: 'report', category: 'deliverables', fileName: '报告.pdf', size: 6 })
        expect((await stat(join(f.root, 'session1/generated'))).mode & 0o777).toBe(0o700)
        expect((await stat(join(f.root, 'session1/generated/report.data'))).mode & 0o777).toBe(0o600)
        expect((await f.request('session2/generated-images/report')).status).toBe(404)
    })
    it('isolates uploaded originals by session and preserves bytes after restart', async () => {
        const f = await fixture()
        await f.media.put('session1', 'uploads', 'original', '原件.zip', 'application/zip', Buffer.from('original'))
        f.offline()
        const result = await f.request('session1/uploads/original')
        expect(result.status).toBe(200); expect(await result.text()).toBe('original')
        expect((await f.request('session2/uploads/original')).status).toBe(404)
    })
    it('rejects traversal, unsafe filenames, oversized files and symlink payloads', async () => {
        const f = await fixture()
        for (const id of ['../escape', '/tmp/file', 'a\\b']) {
            await expect(f.media.put('session1', 'uploads', id, 'f.pdf', 'application/pdf', Buffer.from('x'))).rejects.toThrow()
        }
        for (const name of ['../secret', '/tmp/file', 'a\\b', 'nul\0.pdf']) {
            await expect(f.media.put('session1', 'uploads', 'upload', name, 'application/pdf', Buffer.from('x'))).rejects.toThrow()
        }
        await expect(f.media.put('session1', 'uploads', 'large', 'f.zip', 'application/zip', Buffer.alloc(50 * 1024 * 1024 + 1))).rejects.toThrow('large')
        expect((await f.request('session1/uploads/%2e%2e%2fescape')).status).toBe(400)
        await f.media.put('session1', 'uploads', 'file', 'f.pdf', 'application/pdf', Buffer.from('x'))
        await rm(join(f.root, 'session1/uploads/file.data'))
        await symlink('/etc/passwd', join(f.root, 'session1/uploads/file.data'))
        await expect(f.media.get('session1', 'uploads', 'file')).rejects.toThrow()
    })
})
