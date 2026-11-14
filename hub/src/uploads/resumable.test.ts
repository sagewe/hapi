import { afterEach, describe, expect, it } from 'bun:test'
import { createHash } from 'node:crypto'
import { mkdtemp, readdir, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { ResumableUploads, UPLOAD_CHUNK_BYTES, UPLOAD_TTL_MS } from './resumable'

const roots: string[] = []
const id = 'a'.repeat(64)
const bytes = Buffer.from('resumable content')
const metadata = {
    filename: 'test.bin', mimeType: 'application/octet-stream', size: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex')
}
async function setup(now?: () => number) {
    const root = await mkdtemp(join(tmpdir(), 'hapi-resumable-'))
    roots.push(root)
    return { root, uploads: new ResumableUploads(root, now) }
}
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))) })

describe('resumable upload storage', () => {
    it('resumes after a lost response and Hub restart, and finalizes once', async () => {
        const { root, uploads } = await setup()
        expect((await uploads.start('owner', 'session', id, metadata)).offset).toBe(0)
        await uploads.append('owner', 'session', id, 0, bytes.subarray(0, 5))
        const restarted = new ResumableUploads(root)
        expect((await restarted.start('owner', 'session', id, metadata)).offset).toBe(5)
        await restarted.append('owner', 'session', id, 5, bytes.subarray(5))
        let deliveries = 0
        const deliver = async (_m: unknown, received: Buffer) => {
            deliveries++
            expect(received).toEqual(bytes)
            return { success: true, path: '/runner/upload' }
        }
        const results = await Promise.all([
            restarted.complete('owner', 'session', id, deliver),
            restarted.complete('owner', 'session', id, deliver)
        ])
        expect(results[0]).toEqual(results[1])
        expect(deliveries).toBe(1)
        const again = new ResumableUploads(root)
        expect((await again.start('owner', 'session', id, metadata)).result?.path).toBe('/runner/upload')
        expect((await readdir(join(root, (await readdir(root))[0]))).sort()).toEqual(['manifest.json'])
    })

    it('rejects concurrent offsets without appending data twice', async () => {
        const { uploads } = await setup()
        await uploads.start('owner', 'session', id, metadata)
        const results = await Promise.allSettled([
            uploads.append('owner', 'session', id, 0, bytes.subarray(0, 5)),
            uploads.append('owner', 'session', id, 0, bytes.subarray(0, 5))
        ])
        expect(results.filter(r => r.status === 'fulfilled')).toHaveLength(1)
        expect((await uploads.start('owner', 'session', id, metadata)).offset).toBe(5)
    })

    it('isolates namespace and session; rejects conflicting metadata and path traversal', async () => {
        const { uploads } = await setup()
        await uploads.start('owner', 'session', id, metadata)
        await expect(uploads.append('other', 'session', id, 0, bytes)).rejects.toMatchObject({ status: 404 })
        await expect(uploads.append('owner', 'other', id, 0, bytes)).rejects.toMatchObject({ status: 404 })
        await expect(uploads.start('owner', 'session', id, { ...metadata, filename: 'changed' })).rejects.toMatchObject({ status: 409 })
        await expect(uploads.start('owner', 'session', '../escape', metadata)).rejects.toMatchObject({ status: 400 })
    })

    it('enforces size bounds and refuses incomplete or corrupt content', async () => {
        const { uploads } = await setup()
        await uploads.start('owner', 'session', id, metadata)
        await expect(uploads.append('owner', 'session', id, 0, Buffer.alloc(UPLOAD_CHUNK_BYTES + 1))).rejects.toMatchObject({ status: 400 })
        await expect(uploads.append('owner', 'session', id, 0, Buffer.alloc(bytes.length + 1))).rejects.toMatchObject({ status: 413 })
        const deliver = async () => { throw new Error('must not deliver') }
        await expect(uploads.complete('owner', 'session', id, deliver)).rejects.toMatchObject({ status: 409 })
        await uploads.append('owner', 'session', id, 0, Buffer.alloc(bytes.length))
        await expect(uploads.complete('owner', 'session', id, deliver)).rejects.toMatchObject({ status: 409 })
        expect((await uploads.start('owner', 'session', id, metadata)).offset).toBe(0)
    })

    it('keeps accepted bytes when Runner handoff fails', async () => {
        const { uploads } = await setup()
        await uploads.start('owner', 'session', id, metadata)
        await uploads.append('owner', 'session', id, 0, bytes)
        await expect(uploads.complete('owner', 'session', id, async () => ({ success: false, error: 'offline' }))).rejects.toMatchObject({ status: 503 })
        expect((await uploads.start('owner', 'session', id, metadata)).offset).toBe(bytes.length)
        expect(await uploads.complete('owner', 'session', id, async () => ({ success: true, path: '/done' }))).toEqual({ success: true, path: '/done' })
    })

    it('expires stale data, bounds reservations and uses private file permissions', async () => {
        let now = 1
        const { root, uploads } = await setup(() => now)
        await uploads.start('owner', 'session', id, metadata)
        const dir = join(root, (await readdir(root))[0])
        expect((await stat(dir)).mode & 0o777).toBe(0o700)
        expect((await stat(join(dir, 'data'))).mode & 0o777).toBe(0o600)
        await uploads.append('owner', 'session', id, 0, bytes)
        now += UPLOAD_TTL_MS + 1
        expect((await uploads.start('owner', 'session', id, metadata)).offset).toBe(0)
        for (let i = 0; i < 10; i++) {
            await uploads.start('owner', 'session', i.toString(16).padStart(64, '0'), { ...metadata, size: 50 * 1024 * 1024 })
        }
        await expect(uploads.start('owner', 'session', 'b'.repeat(64), { ...metadata, size: 50 * 1024 * 1024 })).rejects.toMatchObject({ status: 429 })
    })
})
