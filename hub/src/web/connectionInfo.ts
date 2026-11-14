import { randomUUID } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

/** Public identity, independent of auth credentials and network addresses. */
export function hubIdentity(dataDir: string): string {
    mkdirSync(dataDir, { recursive: true, mode: 0o700 })
    const path = join(dataDir, 'connection-id')
    try { writeFileSync(path, randomUUID() + '\n', { flag: 'wx', mode: 0o600 }) }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error }
    const id = readFileSync(path, 'utf8').trim()
    if (!/^[a-f0-9-]{36}$/.test(id)) throw new Error('Invalid Hub connection identity')
    return id
}

export function privateConnectionURL(raw = process.env.HAPI_DIRECT_URL): string | null {
    if (!raw) return null
    try {
        const url = new URL(raw)
        if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search || url.hash) return null
        return url.origin
    } catch { return null }
}
