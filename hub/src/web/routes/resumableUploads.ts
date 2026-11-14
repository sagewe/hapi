import { Hono } from 'hono'
import { bodyLimit } from 'hono/body-limit'
import { HTTPException } from 'hono/http-exception'
import { join } from 'node:path'
import type { SyncEngine } from '../../sync/syncEngine'
import type { WebAppEnv } from '../middleware/auth'
import { getHapiHomeDir } from '../../scratchlistAttachments/storage'
import { ResumableUploadRequestSchema } from '@hapi/protocol'
import { ResumableUploads, UploadError, UPLOAD_CHUNK_BYTES } from '../../uploads/resumable'
import { requireSessionFromParam, requireSyncEngine } from './guards'

export function createResumableUploadRoutes(getSyncEngine: () => SyncEngine | null,
    uploads = new ResumableUploads(join(getHapiHomeDir(), 'pending-uploads'))) {
    const app = new Hono<WebAppEnv>()
    app.use('/sessions/:id/uploads/:uploadId/chunk', bodyLimit({ maxSize: UPLOAD_CHUNK_BYTES }))
    app.use('/sessions/:id/uploads/:uploadId/complete', bodyLimit({ maxSize: 4096 }))
    app.use('/sessions/:id/uploads/:uploadId', bodyLimit({ maxSize: 4096 }))
    app.onError((error, c) => {
        if (error instanceof UploadError) return c.json({ error: error.message }, error.status)
        if (error instanceof HTTPException) return error.getResponse()
        return c.json({ error: 'Upload temporarily unavailable' }, 503)
    })
    const access = (c: Parameters<typeof requireSyncEngine>[0]) => {
        const engine = requireSyncEngine(c, getSyncEngine)
        if (engine instanceof Response) return engine
        const session = requireSessionFromParam(c, engine, { requireActive: true })
        if (session instanceof Response) return session
        return { engine, sessionId: session.sessionId, namespace: c.get('namespace'), id: c.req.param('uploadId') ?? '' }
    }
    app.post('/sessions/:id/uploads/:uploadId', async c => {
        const a = access(c)
        if (a instanceof Response) return a
        const metadata = ResumableUploadRequestSchema.safeParse(await c.req.json().catch(error => {
            if (error instanceof SyntaxError) return null
            throw error
        }))
        if (!metadata.success) return c.json({ error: 'Invalid upload metadata' }, 400)
        return c.json(await uploads.start(a.namespace, a.sessionId, a.id, metadata.data))
    })
    app.put('/sessions/:id/uploads/:uploadId/chunk', async c => {
        const a = access(c)
        if (a instanceof Response) return a
        const rawOffset = c.req.query('offset')
        if (!rawOffset || !/^\d+$/.test(rawOffset)) return c.json({ error: 'Invalid offset' }, 400)
        const bytes = Buffer.from(await c.req.arrayBuffer())
        return c.json(await uploads.append(a.namespace, a.sessionId, a.id, Number(rawOffset), bytes))
    })
    app.post('/sessions/:id/uploads/:uploadId/complete', async c => {
        const a = access(c)
        if (a instanceof Response) return a
        return c.json(await uploads.complete(a.namespace, a.sessionId, a.id,
            (metadata, bytes) => a.engine.uploadFile(a.sessionId, metadata.filename, bytes.toString('base64'), metadata.mimeType)))
    })
    return app
}
