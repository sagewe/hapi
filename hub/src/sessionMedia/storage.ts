import { createHash, randomUUID } from 'node:crypto'
import { constants } from 'node:fs'
import { mkdir, open, readdir, rename, rm, lstat, chmod } from 'node:fs/promises'
import { join } from 'node:path'
import { getHapiHomeDir } from '../scratchlistAttachments/storage'

export type CaseFile = {
    id: string; category: 'deliverables' | 'uploads'; fileName: string
    mimeType: string; size: number; createdAt: number; downloadPath: string
}
type Stored = CaseFile & { sessionId: string }
export const MAX_MEDIA_BYTES = 50 * 1024 * 1024
export function validMediaId(id: string): boolean { return /^[a-zA-Z0-9_-]{1,160}$/.test(id) }
export function safeMediaName(name: string): string {
    const safe = name.replace(/\\/g, '/').split('/').pop()?.replace(/[\x00-\x1f\x7f]/g, '').trim() ?? ''
    return (!safe || safe === '.' || safe === '..') ? 'file' : [...safe].slice(0, 120).join('')
}
export function validUploadName(name: string): boolean {
    return !!name && !/[\\/\x00-\x1f\x7f]/.test(name) && name !== '.' && name !== '..' && Buffer.byteLength(name) <= 255
}
/** Immutable payload + atomic manifest. No wire-provided path is ever opened. */
export class SessionMediaStore {
    constructor(private readonly root = join(getHapiHomeDir(), 'session-media')) {}
    private dir(sessionId: string, category: CaseFile['category']): string {
        if (!validMediaId(sessionId)) throw new Error('Invalid session id')
        return join(this.root, sessionId, category === 'deliverables' ? 'generated' : 'uploads')
    }
    async put(sessionId: string, category: CaseFile['category'], id: string, fileName: string, mimeType: string, bytes: Uint8Array): Promise<CaseFile> {
        if (!validMediaId(id)) throw new Error('Invalid media id')
        if (bytes.length > MAX_MEDIA_BYTES) throw new Error('File too large')
        if (category === 'uploads' && !validUploadName(fileName)) throw new Error('Invalid upload filename')
        const dir = this.dir(sessionId, category)
        for (const path of [this.root, join(this.root, sessionId), dir]) {
            await mkdir(path, { recursive: true, mode: 0o700 })
            if (!(await lstat(path)).isDirectory()) throw new Error('Invalid media directory')
            await chmod(path, 0o700)
        }
        const existing = await this.get(sessionId, category, id)
        if (existing) return existing.file
        const stem = join(dir, id)
        const tmp = `${stem}-${randomUUID()}.tmp`
        const file: Stored = { sessionId, id, category, fileName: safeMediaName(fileName),
            mimeType: /^[a-zA-Z0-9.+-]+\/[a-zA-Z0-9.+-]+$/.test(mimeType) ? mimeType : 'application/octet-stream',
            size: bytes.length, createdAt: Date.now(),
            downloadPath: `/api/sessions/${encodeURIComponent(sessionId)}/${category === 'uploads' ? 'uploads' : 'generated-images'}/${encodeURIComponent(id)}` }
        try {
            const handle = await open(tmp, 'wx', 0o600)
            try { await handle.writeFile(bytes); await handle.sync() } finally { await handle.close() }
            await rename(tmp, `${stem}.data`)
            const meta = `${tmp}.json`
            const manifest = await open(meta, 'wx', 0o600)
            try { await manifest.writeFile(JSON.stringify(file)); await manifest.sync() } finally { await manifest.close() }
            await rename(meta, `${stem}.json`)
        } finally { await rm(tmp, { force: true }); await rm(`${tmp}.json`, { force: true }) }
        const { sessionId: _, ...result } = file
        return result
    }
    private async info(sessionId: string, category: CaseFile['category'], id: string): Promise<CaseFile | null> {
        if (!validMediaId(id)) return null
        const dir = this.dir(sessionId, category)
        try {
            for (const path of [this.root, join(this.root, sessionId), dir]) {
                if (!(await lstat(path)).isDirectory()) throw new Error('Invalid media directory')
            }
            const raw = await this.readRegular(join(dir, `${id}.json`), 16384)
            const meta = JSON.parse(raw.toString()) as Stored
            if (meta.sessionId !== sessionId || meta.id !== id || meta.category !== category || !Number.isSafeInteger(meta.size) || meta.size < 0 || meta.size > MAX_MEDIA_BYTES) return null
            const data = await lstat(join(dir, `${id}.data`))
            if (!data.isFile() || data.size !== meta.size) throw new Error('Invalid media file')
            const { sessionId: _, ...file } = meta
            return file
        } catch (error) {
            if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null
            throw error
        }
    }
    async get(sessionId: string, category: CaseFile['category'], id: string): Promise<{ file: CaseFile; bytes: Buffer } | null> {
        const file = await this.info(sessionId, category, id)
        if (!file) return null
        const bytes = await this.readRegular(join(this.dir(sessionId, category), `${id}.data`), MAX_MEDIA_BYTES)
        if (bytes.length !== file.size) throw new Error('Invalid media file')
        return { file, bytes }
    }
    async remove(sessionId: string, category: CaseFile['category'], id: string): Promise<void> {
        if (!validMediaId(id)) throw new Error('Invalid media id')
        const dir = this.dir(sessionId, category)
        if (!await this.info(sessionId, category, id)) return
        await rm(join(dir, `${id}.json`), { force: true })
        await rm(join(dir, `${id}.data`), { force: true })
    }
    private async readRegular(path: string, cap: number): Promise<Buffer> {
        const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW)
        try {
            const stat = await handle.stat()
            if (!stat.isFile() || stat.size > cap) throw new Error('Invalid media file')
            return await handle.readFile()
        } finally { await handle.close() }
    }
    async list(sessionId: string): Promise<CaseFile[]> {
        const files: CaseFile[] = []
        for (const category of ['deliverables', 'uploads'] as const) {
            const dir = this.dir(sessionId, category)
            const entries = await readdir(dir).catch((e: NodeJS.ErrnoException) => { if (e.code === 'ENOENT') return []; throw e })
            for (const entry of entries) {
                if (!entry.endsWith('.json')) continue
                const item = await this.info(sessionId, category, entry.slice(0, -5))
                if (item) files.push(item)
            }
        }
        return files.sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id))
    }
}
export function uploadMediaId(path: string): string { return createHash('sha256').update(path).digest('hex') }
