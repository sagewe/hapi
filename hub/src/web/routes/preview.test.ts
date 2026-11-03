import { expect, it } from 'bun:test'
import { Hono } from 'hono'
import { createSessionsRoutes } from './sessions'
import type { SyncEngine } from '../../sync/syncEngine'
import type { WebAppEnv } from '../middleware/auth'
it('binds preview to the authorized session machine and denies cross-namespace access', async () => {
    const calls: unknown[] = []
    const engine = {
        resolveSessionAccess: (id: string, namespace: string) => id === 'own' && namespace === 'alice'
            ? { ok: true, sessionId: 'own', session: { metadata: { machineId: 'machine-a' } } }
            : { ok: false, reason: 'access-denied' },
        getMachineByNamespace: (id: string, namespace: string) => id === 'machine-a' && namespace === 'alice' ? { active: true } : undefined,
        openPreview: async (machineId: string, input: unknown) => {
            calls.push({ machineId, input })
            return { id: '12345678-1234-4123-8123-123456789012', origin: 'https://preview.example', username: 'preview', password: 'x'.repeat(43), expiresAt: Date.now() + 1000 }
        },
    } as unknown as SyncEngine
    const app = new Hono<WebAppEnv>()
    app.use('*', async (c, next) => { c.set('namespace', 'alice'); c.set('userId', 1); await next() })
    app.route('/', createSessionsRoutes(() => engine))
    const body = JSON.stringify({ host: 'localhost', port: 5173, machineId: 'attacker-choice' })
    const good = await app.request('/sessions/own/preview', { method: 'POST', body, headers: { 'Content-Type': 'application/json' } })
    expect(good.status).toBe(200); expect(good.headers.get('cache-control')).toBe('no-store')
    expect(calls).toEqual([{ machineId: 'machine-a', input: { host: 'localhost', port: 5173, sessionId: 'own' } }])
    expect((await app.request('/sessions/other/preview', { method: 'POST', body, headers: { 'Content-Type': 'application/json' } })).status).toBe(403)
    expect(calls.length).toBe(1)
    expect((await app.request('/sessions/own/preview', { method: 'POST', body: JSON.stringify({ host: 'example.com', port: 5173 }), headers: { 'Content-Type': 'application/json' } })).status).toBe(400)
})
