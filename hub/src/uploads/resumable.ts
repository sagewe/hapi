import { createHash, randomUUID } from 'node:crypto'
import { mkdir, open, readFile, readdir, rename, rm, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { ResumableUploadRequestSchema, type ResumableUploadRequest, type UploadFileResponse } from '@hapi/protocol'

export const UPLOAD_CHUNK_BYTES = 512 * 1024
export const UPLOAD_TTL_MS = 24 * 60 * 60 * 1000
const MAX_RESERVED_BYTES = 512 * 1024 * 1024
type Metadata = ResumableUploadRequest
type Manifest = Metadata & { updatedAt: number; result?: UploadFileResponse }

export class UploadError extends Error {
    constructor(message: string, readonly status: 400 | 404 | 409 | 413 | 429 | 503) { super(message) }
}

/** Durable, namespace/session-scoped staging. The Runner still owns final attachments. */
export class ResumableUploads {
    private readonly locks = new Map<string, Promise<void>>()
    constructor(private readonly root: string, private readonly now = Date.now) {}

    private key(namespace: string, sessionId: string, id: string): string {
        if (!/^[a-f0-9]{64}$/.test(id)) throw new UploadError('Invalid upload id', 400)
        return createHash('sha256').update(JSON.stringify([namespace, sessionId, id])).digest('hex')
    }

    private async locked<T>(key: string, work: () => Promise<T>): Promise<T> {
        const previous = this.locks.get(key) ?? Promise.resolve()
        let release!: () => void
        const next = new Promise<void>(resolve => { release = resolve })
        this.locks.set(key, next)
        await previous
        try { return await work() } finally {
            release()
            if (this.locks.get(key) === next) this.locks.delete(key)
        }
    }

    private async save(dir: string, manifest: Manifest): Promise<void> {
        const temp = join(dir, `manifest-${randomUUID()}.tmp`)
        await writeFile(temp, JSON.stringify(manifest), { mode: 0o600 })
        await rename(temp, join(dir, 'manifest.json'))
    }

    private async load(dir: string): Promise<Manifest> {
        try {
            const manifest = JSON.parse(await readFile(join(dir, 'manifest.json'), 'utf8')) as Manifest
            if (this.now() - manifest.updatedAt > UPLOAD_TTL_MS) throw new UploadError('Upload expired', 404)
            return manifest
        } catch (error) {
            if (error instanceof UploadError) throw error
            if ((error as NodeJS.ErrnoException).code === 'ENOENT') throw new UploadError('Upload not found', 404)
            throw error
        }
    }

    private async status(dir: string, manifest: Manifest) {
        const offset = manifest.result ? manifest.size : (await stat(join(dir, 'data'))).size
        return { offset, chunkSize: UPLOAD_CHUNK_BYTES, result: manifest.result }
    }

    async start(namespace: string, sessionId: string, id: string, metadata: Metadata) {
        metadata = ResumableUploadRequestSchema.parse(metadata)
        const key = this.key(namespace, sessionId, id)
        return this.locked(key, async () => {
            const dir = join(this.root, key)
            try {
                const manifest = await this.load(dir)
                if (['filename', 'mimeType', 'size', 'sha256'].some(k => manifest[k as keyof Metadata] !== metadata[k as keyof Metadata])) {
                    throw new UploadError('Upload metadata mismatch', 409)
                }
                manifest.updatedAt = this.now()
                await this.save(dir, manifest)
                return this.status(dir, manifest)
            } catch (error) {
                if (!(error instanceof UploadError) || error.status !== 404) throw error
            }
            // Serialize reservation and expiry cleanup across uploads. Never prune a live operation.
            return this.locked('quota', async () => {
                await mkdir(this.root, { recursive: true, mode: 0o700 })
                let reserved = 0
                let count = 0
                for (const entry of await readdir(this.root)) {
                    if (!/^[a-f0-9]{64}$/.test(entry)) continue
                    const entryDir = join(this.root, entry)
                    try {
                        const m = await this.load(entryDir)
                        reserved += m.result ? 0 : m.size
                        count++
                    } catch (error) {
                        if (error instanceof UploadError && error.status === 404 && (entry === key || !this.locks.has(entry))) {
                            await rm(entryDir, { recursive: true, force: true })
                        } else if (!(error instanceof UploadError)) throw error
                    }
                }
                if (reserved + metadata.size > MAX_RESERVED_BYTES || count >= 256) throw new UploadError('Upload staging quota exceeded', 429)
                await mkdir(dir, { mode: 0o700 })
                try {
                    await writeFile(join(dir, 'data'), Buffer.alloc(0), { mode: 0o600, flag: 'wx' })
                    const manifest = { ...metadata, updatedAt: this.now() }
                    await this.save(dir, manifest)
                    return this.status(dir, manifest)
                } catch (error) {
                    await rm(dir, { recursive: true, force: true })
                    throw error
                }
            })
        })
    }

    async append(namespace: string, sessionId: string, id: string, offset: number, bytes: Buffer) {
        const key = this.key(namespace, sessionId, id)
        return this.locked(key, async () => {
            const dir = join(this.root, key)
            const manifest = await this.load(dir)
            if (!Number.isSafeInteger(offset) || offset < 0 || bytes.length === 0 || bytes.length > UPLOAD_CHUNK_BYTES) {
                throw new UploadError('Invalid chunk', 400)
            }
            if (manifest.result) return this.status(dir, manifest)
            const file = await open(join(dir, 'data'), 'r+')
            try {
                const size = (await file.stat()).size
                if (offset !== size) throw new UploadError('Upload offset mismatch', 409)
                if (offset + bytes.length > manifest.size) throw new UploadError('Chunk exceeds declared size', 413)
                let written = 0
                while (written < bytes.length) {
                    const result = await file.write(bytes, written, bytes.length - written, offset + written)
                    if (!result.bytesWritten) throw new Error('Short upload write')
                    written += result.bytesWritten
                }
                await file.sync()
            } finally { await file.close() }
            manifest.updatedAt = this.now()
            await this.save(dir, manifest)
            return this.status(dir, manifest)
        })
    }

    async complete(namespace: string, sessionId: string, id: string, deliver: (metadata: Metadata, bytes: Buffer) => Promise<UploadFileResponse>) {
        const key = this.key(namespace, sessionId, id)
        return this.locked(key, async () => {
            const dir = join(this.root, key)
            const manifest = await this.load(dir)
            if (manifest.result) return manifest.result
            const bytes = await readFile(join(dir, 'data'))
            if (bytes.length !== manifest.size) throw new UploadError('Upload incomplete', 409)
            if (createHash('sha256').update(bytes).digest('hex') !== manifest.sha256) {
                // Corrupted content cannot make progress; allow a clean retry with the same id.
                await rm(dir, { recursive: true, force: true })
                throw new UploadError('Upload checksum mismatch', 409)
            }
            const result = await deliver(manifest, bytes)
            if (!result.success || !result.path) throw new UploadError('Attachment handoff failed', 503)
            manifest.result = result
            manifest.updatedAt = this.now()
            await this.save(dir, manifest)
            await rm(join(dir, 'data'), { force: true })
            return result
        })
    }
}
