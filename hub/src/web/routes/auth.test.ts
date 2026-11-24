import { afterEach, describe, expect, it } from 'bun:test'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Hono } from 'hono'
import { jwtVerify } from 'jose'
import { createConfiguration } from '../../configuration'
import { __resetSettingsReadCacheForTests, writeSettings } from '../../config/settings'
import { Store } from '../../store'
import { createAuthRoutes } from './auth'

const dirs: string[] = []

afterEach(async () => {
    __resetSettingsReadCacheForTests()
    await Promise.all(dirs.splice(0).map((d) => rm(d, { recursive: true, force: true })))
})

describe('POST /api/auth multi-namespace access tokens', () => {
    it('issues namespace-scoped JWTs for dedicated namespace tokens and blocks escalation', async () => {
        const config = await createConfiguration()
        const prevToken = config.cliApiToken
        const prevSettingsFile = config.settingsFile
        const dir = await mkdtemp(join(tmpdir(), 'hapi-auth-ns-'))
        dirs.push(dir)

        const settingsPath = join(dir, 'settings.json')
        await writeSettings(settingsPath, {
            cliApiToken: 'owner-token-secret-123456',
            namespaces: {
                compliance: { token: 'compliance-token-secret-999' },
                household: { token: 'household-token-secret-888' }
            }
        })

        config._setCliApiToken('owner-token-secret-123456', 'file', false)
        ;(config as unknown as { settingsFile: string }).settingsFile = settingsPath

        try {
            const secret = new TextEncoder().encode('test-jwt-secret-key-for-auth-routes')
            const store = new Store(':memory:')
            const app = new Hono()
            app.route('/api', createAuthRoutes(secret, store))

            const postAuth = (accessToken: string) => app.request('/api/auth', {
                method: 'POST',
                headers: { 'content-type': 'application/json' },
                body: JSON.stringify({ accessToken })
            })

            // 1. Owner token -> default
            const ownerRes = await postAuth('owner-token-secret-123456')
            expect(ownerRes.status).toBe(200)
            const ownerPayload = (await jwtVerify((await ownerRes.json() as { token: string }).token, secret)).payload
            expect(ownerPayload.ns).toBe('default')

            // 2. Dedicated compliance token -> compliance
            const compRes = await postAuth('compliance-token-secret-999')
            expect(compRes.status).toBe(200)
            const compPayload = (await jwtVerify((await compRes.json() as { token: string }).token, secret)).payload
            expect(compPayload.ns).toBe('compliance')

            // 3. Dedicated household token -> household
            const homeRes = await postAuth('household-token-secret-888')
            expect(homeRes.status).toBe(200)
            const homePayload = (await jwtVerify((await homeRes.json() as { token: string }).token, secret)).payload
            expect(homePayload.ns).toBe('household')

            // 4. Escalation attempts blocked
            expect((await postAuth('compliance-token-secret-999:default')).status).toBe(401)
            expect((await postAuth('household-token-secret-888:compliance')).status).toBe(401)
            expect((await postAuth('wrong-token')).status).toBe(401)
        } finally {
            config._setCliApiToken(prevToken, 'file', false)
            ;(config as unknown as { settingsFile: string }).settingsFile = prevSettingsFile
        }
    })
})
