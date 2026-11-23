import { Hono } from 'hono'
import { lstat, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { z } from 'zod'
import type { WebAppEnv } from '../middleware/auth'

export function validApkFilename(value: string): boolean {
    return value.length <= 160 && !value.includes('..') && /^[A-Za-z0-9][A-Za-z0-9._-]*\.apk$/.test(value)
}
const releaseSchema = z.object({
    packageName: z.string().regex(/^[a-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/),
    versionCode: z.number().int().positive(), versionName: z.string().min(1).max(80),
    fileName: z.string().refine(validApkFilename), sha256: z.string().regex(/^[a-f0-9]{64}$/),
    size: z.number().int().positive().max(500 * 1024 * 1024),
    releaseNotes: z.string().max(20000), publishedAt: z.string().datetime({ offset: true }),
    downloadPath: z.string()
})
export function createAndroidUpdateRoutes(dataDir: string): Hono<WebAppEnv> {
    const app = new Hono<WebAppEnv>()
    const directory = join(dataDir, 'android-releases')
    app.use('*', async (c, next) => {
        // This router must only be mounted behind the server's JWT middleware.
        if (!c.get('namespace')) return c.json({ error: 'Authentication required' }, 401)
        c.header('Cache-Control', 'no-store')
        return next()
    })
    async function regularFile(filename: string) {
        const dir = await lstat(directory)
        if (!dir.isDirectory() || dir.isSymbolicLink()) throw new Error('Invalid release directory')
        const path = join(directory, filename)
        const stat = await lstat(path)
        if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('Invalid release file')
        return { path, size: stat.size }
    }
    app.get('/app-updates/android/latest', async (c) => {
        try {
            const file = await regularFile('latest.json')
            if (file.size > 64000) throw new Error('Invalid manifest')
            const release = releaseSchema.parse(JSON.parse(await readFile(file.path, 'utf8')))
            if (release.downloadPath !== `/api/app-updates/android/download/${release.fileName}`) throw new Error('Invalid download path')
            const apk = await regularFile(release.fileName)
            if (apk.size !== release.size) throw new Error('Incomplete publication')
            return c.json(release)
        } catch { return c.json({ error: 'No Android release available' }, 404) }
    })
    app.get('/app-updates/android/download/:filename', async (c) => {
        const filename = c.req.param('filename')
        if (!validApkFilename(filename)) return c.json({ error: 'Invalid APK filename' }, 400)
        try {
            const file = await regularFile(filename)
            return new Response(Bun.file(file.path).stream(), { headers: {
                'Content-Type': 'application/vnd.android.package-archive',
                'Content-Length': String(file.size), 'Cache-Control': 'no-store',
                'Content-Disposition': `attachment; filename="${filename}"`,
                'X-Content-Type-Options': 'nosniff'
            } })
        } catch { return c.json({ error: 'APK not found' }, 404) }
    })
    return app
}
