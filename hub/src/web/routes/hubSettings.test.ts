import { afterEach, describe, expect, it } from 'bun:test'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Hono } from 'hono'
import { STOCK_PEER_SPAWN_DEFAULTS } from '@hapi/protocol/peerSpawnDefaults'
import type { WebAppEnv } from '../middleware/auth'
import { createHubSettingsRoutes } from './hubSettings'
import { writeSessionSummaryContractEnabled } from '../../config/sessionSummaryContract'
import { writeSessionSummaryInChatEnabled } from '../../config/sessionSummaryInChat'
import { getSettingsFile, writeSettings } from '../../config/settings'

const directories: string[] = []
const stockPeerSpawnDefaults = {
    ...STOCK_PEER_SPAWN_DEFAULTS,
    permissionMode: 'bypassPermissions' as const
}

afterEach(async () => {
    await Promise.all(directories.splice(0).map((path) => rm(path, { recursive: true, force: true })))
})

describe('GET/PUT /api/hub-settings', () => {
    async function createApp(namespace = 'default') {
        const dataDir = await mkdtemp(join(tmpdir(), 'hapi-hub-settings-'))
        directories.push(dataDir)
        const app = new Hono<WebAppEnv>()
        app.use('*', async (c, next) => {
            c.set('namespace', namespace)
            await next()
        })
        app.route('/api', createHubSettingsRoutes(dataDir))
        return { app, dataDir }
    }

    it('returns default off for emit, chat display, and stock peer spawn defaults', async () => {
        const { app } = await createApp()
        const response = await app.request('/api/hub-settings')
        expect(response.status).toBe(200)
        expect(response.headers.get('cache-control')).toBe('no-store')
        expect(await response.json()).toEqual({
            sessionSummaryContract: false,
            sessionSummaryInChat: false,
            peerSpawnDefaults: stockPeerSpawnDefaults
        })
    })

    it('persists assistant profile and restores developer mode without leaking private settings', async () => {
        const { app } = await createApp()
        const profile = { mode: 'assistant', defaultAgent: 'agy', defaultPermissionMode: 'auto',
            defaultDirectory: '/workspace', quickActions: [{ id: 'company', title: '企业核查', prompt: '核查企业' }] }
        const update = (clientProfile: unknown) => app.request('/api/hub-settings', {
            method: 'PUT', headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ clientProfile })
        })
        expect((await update(profile)).status).toBe(200)
        const response = await (await app.request('/api/hub-settings')).json() as Record<string, unknown>
        expect(response.clientProfile).toEqual(profile)
        expect(response.cliApiToken).toBeUndefined()
        expect((await update({ mode: 'unexpected' })).status).toBe(400)
        expect((await update({ mode: 'assistant', defaultAgent: 'bad' })).status).toBe(400)
        expect((await update({ mode: 'developer' })).status).toBe(200)
        expect((await (await app.request('/api/hub-settings')).json() as Record<string, unknown>).clientProfile)
            .toEqual({ mode: 'developer' })
    })

    it('persists emit toggle for owner without changing display', async () => {
        const { app } = await createApp()
        const put = await app.request('/api/hub-settings', {
            method: 'PUT',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ sessionSummaryContract: true })
        })
        expect(put.status).toBe(200)
        expect(await put.json()).toEqual({
            sessionSummaryContract: true,
            sessionSummaryInChat: false,
            peerSpawnDefaults: stockPeerSpawnDefaults
        })

        const get = await app.request('/api/hub-settings')
        expect(await get.json()).toEqual({
            sessionSummaryContract: true,
            sessionSummaryInChat: false,
            peerSpawnDefaults: stockPeerSpawnDefaults
        })
    })

    it('persists chat display toggle for owner without changing emit', async () => {
        const { app, dataDir } = await createApp()
        await writeSessionSummaryContractEnabled(dataDir, true)

        const put = await app.request('/api/hub-settings', {
            method: 'PUT',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ sessionSummaryInChat: true })
        })
        expect(put.status).toBe(200)
        expect(await put.json()).toEqual({
            sessionSummaryContract: true,
            sessionSummaryInChat: true,
            peerSpawnDefaults: stockPeerSpawnDefaults
        })
    })

    it('persists peer spawn defaults', async () => {
        const { app } = await createApp()
        const put = await app.request('/api/hub-settings', {
            method: 'PUT',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({
                peerSpawnDefaults: {
                    agent: 'cursor',
                    permissionMode: 'yolo',
                    models: { cursor: 'auto' }
                }
            })
        })
        expect(put.status).toBe(200)
        expect(await put.json()).toEqual({
            sessionSummaryContract: false,
            sessionSummaryInChat: false,
            peerSpawnDefaults: {
                agent: 'cursor',
                permissionMode: 'yolo',
                models: {
                    claude: 'sonnet',
                    cursor: 'auto'
                }
            }
        })
    })

    it('clears a saved peer spawn model override with an empty string', async () => {
        const { app } = await createApp()
        await app.request('/api/hub-settings', {
            method: 'PUT',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({
                peerSpawnDefaults: {
                    agent: 'codex',
                    permissionMode: 'default',
                    models: { codex: 'gpt-5' }
                }
            })
        })

        const clear = await app.request('/api/hub-settings', {
            method: 'PUT',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({
                peerSpawnDefaults: {
                    agent: 'codex',
                    permissionMode: 'default',
                    models: { codex: '' }
                }
            })
        })
        expect(clear.status).toBe(200)
        expect(await clear.json()).toEqual({
            sessionSummaryContract: false,
            sessionSummaryInChat: false,
            peerSpawnDefaults: {
                agent: 'codex',
                permissionMode: 'default',
                models: {
                    claude: 'sonnet'
                }
            }
        })
    })

    it('rejects invalid body', async () => {
        const { app } = await createApp()
        const response = await app.request('/api/hub-settings', {
            method: 'PUT',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ sessionSummaryContract: 'yes' })
        })
        expect(response.status).toBe(400)
    })

    it('rejects retired gemini as peer spawn default agent', async () => {
        const { app } = await createApp()
        const response = await app.request('/api/hub-settings', {
            method: 'PUT',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({
                peerSpawnDefaults: { agent: 'gemini' }
            })
        })
        expect(response.status).toBe(400)
    })

    it('rejects empty body', async () => {
        const { app } = await createApp()
        const response = await app.request('/api/hub-settings', {
            method: 'PUT',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({})
        })
        expect(response.status).toBe(400)
    })

    it('rejects non-default namespaces for PUT but allows GET', async () => {
        const { app, dataDir } = await createApp('default')
        await writeSessionSummaryInChatEnabled(dataDir, true)

        const tenantApp = new Hono<WebAppEnv>()
        tenantApp.use('*', async (c, next) => {
            c.set('namespace', 'tenant')
            await next()
        })
        tenantApp.route('/api', createHubSettingsRoutes(dataDir))

        const get = await tenantApp.request('/api/hub-settings')
        expect(get.status).toBe(200)
        expect(await get.json()).toEqual({
            sessionSummaryContract: false,
            sessionSummaryInChat: true,
            peerSpawnDefaults: stockPeerSpawnDefaults
        })

        const put = await tenantApp.request('/api/hub-settings', {
            method: 'PUT',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ sessionSummaryContract: true })
        })
        expect(put.status).toBe(403)
    })

    it('survives a prior write via settings helpers', async () => {
        const { app, dataDir } = await createApp()
        await writeSessionSummaryContractEnabled(dataDir, true)
        await writeSessionSummaryInChatEnabled(dataDir, true)
        const response = await app.request('/api/hub-settings')
        expect(await response.json()).toEqual({
            sessionSummaryContract: true,
            sessionSummaryInChat: true,
            peerSpawnDefaults: stockPeerSpawnDefaults
        })
    })

    it('resolves per-namespace clientProfile without leaking namespace tokens', async () => {
        const { app: defaultApp, dataDir } = await createApp('default')
        const complianceProfile = {
            mode: 'assistant' as const,
            appTitle: '琪琪工作',
            defaultAgent: 'agy' as const,
            defaultPermissionMode: 'always-proceed' as const,
            defaultDirectory: '/Users/sage/compliance-workspace'
        }
        const householdProfile = {
            mode: 'assistant' as const,
            appTitle: 'MyDots 家庭助手'
        }
        await writeSettings(getSettingsFile(dataDir), {
            namespaces: {
                compliance: {
                    token: 'super-secret-compliance-token',
                    clientProfile: complianceProfile
                },
                household: {
                    token: 'super-secret-household-token',
                    clientProfile: householdProfile
                }
            }
        })

        const mountFor = (ns: string) => {
            const tenantApp = new Hono<WebAppEnv>()
            tenantApp.use('*', async (c, next) => {
                c.set('namespace', ns)
                await next()
            })
            tenantApp.route('/api', createHubSettingsRoutes(dataDir))
            return tenantApp
        }

        const defaultRes = await (await defaultApp.request('/api/hub-settings')).json() as Record<string, unknown>
        expect(defaultRes.clientProfile).toBeUndefined()
        expect(defaultRes.namespaces).toBeUndefined()

        const complianceRes = await (await mountFor('compliance').request('/api/hub-settings')).json() as Record<string, unknown>
        expect(complianceRes.clientProfile).toEqual(complianceProfile)
        expect(complianceRes.namespaces).toBeUndefined()

        const householdRes = await (await mountFor('household').request('/api/hub-settings')).json() as Record<string, unknown>
        expect(householdRes.clientProfile).toEqual(householdProfile)
        expect(householdRes.namespaces).toBeUndefined()
    })
})
