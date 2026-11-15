import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, relative } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { resolveUsageCredentials, type ResolvedUsageCredentials } from './credentials'
import { queryCodexNativeRateLimits } from './execute'

const limits = { rateLimits: { primary: { usedPercent: 37, windowDurationMins: 300 }, planType: 'pro' } }
const account = (id: string) => ({ account: { type: 'chatgpt', id, email: 'same@example.test' } })
const identity = (id: string, fingerprint = id): ResolvedUsageCredentials => ({
    baseUrl: 'https://chatgpt.com/backend-api', apiKey: id,
    apiKeySource: 'config', baseUrlSource: 'config',
    identityFingerprint: fingerprint, codexHome: '/isolated/codex-home', codexAccount: { id, email: 'same@example.test' }
})
function fakeClient(handler: (method: string) => Promise<unknown>) {
    return {
        connect: vi.fn(async () => {}), initialize: vi.fn(async () => ({})),
        request: vi.fn(async <T = unknown>(method: string): Promise<T> => await handler(method) as T),
        disconnect: vi.fn(async () => {})
    }
}

describe('Codex quota account provenance', () => {
    let root: string | undefined
    afterEach(async () => {
        vi.unstubAllEnvs()
        if (root) await rm(root, { recursive: true, force: true })
        root = undefined
    })

    it('binds credential identity to account, token rotation, selected home and profile config', async () => {
        root = await mkdtemp(join(tmpdir(), 'hapi-codex-quota-'))
        const homeA = join(root, 'a'); const homeB = join(root, 'b')
        await mkdir(homeA); await mkdir(homeB)
        const auth = (id: string, token: string) => JSON.stringify({ auth_mode: 'chatgpt', tokens: {
            account_id: id, access_token: token,
            id_token: `header.${Buffer.from(JSON.stringify({ email: 'same@example.test' })).toString('base64url')}.signature`
        } })
        const resolve = () => resolveUsageCredentials('codex', { CODEX_HOME: homeA })
        await writeFile(join(homeA, 'auth.json'), auth('account-a', 'token-one'))
        const a = await resolve()
        expect(a.codexAccount).toEqual({ id: 'account-a', email: 'same@example.test' })
        await writeFile(join(homeA, 'auth.json'), auth('account-b', 'token-two'))
        const b = await resolve()
        expect(b.identityFingerprint).not.toBe(a.identityFingerprint)
        await writeFile(join(homeA, 'auth.json'), auth('account-b', 'token-three'))
        const refreshed = await resolve()
        expect(refreshed.identityFingerprint).not.toBe(b.identityFingerprint)
        await writeFile(join(homeA, 'config.toml'), 'profile = "work"\n[profiles.work]\nmodel = "example"\n')
        const profile = await resolve()
        expect(profile.identityFingerprint).not.toBe(refreshed.identityFingerprint)
        await writeFile(join(homeB, 'auth.json'), auth('account-b', 'token-three'))
        await writeFile(join(homeB, 'config.toml'), 'profile = "work"\n[profiles.work]\nmodel = "example"\n')
        expect((await resolveUsageCredentials('codex', { CODEX_HOME: homeB })).identityFingerprint)
            .not.toBe(profile.identityFingerprint)
        const overridden = await resolveUsageCredentials('codex', { CODEX_HOME: homeA, OPENAI_BASE_URL: 'https://proxy.example.test' })
        expect(overridden.identityFingerprint).not.toBe(profile.identityFingerprint)
        const apiKeyMode = await resolveUsageCredentials('codex', { CODEX_HOME: homeA, OPENAI_API_KEY: 'api-key-fixture' })
        expect(apiKeyMode.identityFingerprint).toBeUndefined()
        expect(apiKeyMode.codexAccount).toBeUndefined()
        expect(JSON.stringify(profile)).not.toContain('token-three')
    })

    it('returns live account A data only after account and snapshot checks on both sides', async () => {
        const credentials = identity('account-a')
        const client = fakeClient(async (method) => method === 'account/read' ? account('account-a') : limits)
        const result = await queryCodexNativeRateLimits(1000, credentials, { client, resolveCredentials: async () => credentials })
        expect(result).toMatchObject({ fiveHour: { usedPercent: 37 }, planType: 'pro' })
        expect(client.request.mock.calls.map(([method]) => method))
            .toEqual(['account/read', 'account/rateLimits/read', 'account/read'])
        expect(client.disconnect).toHaveBeenCalledOnce()
    })

    it('supports current email-only account responses with stable account-id snapshots', async () => {
        const credentials = identity('account-a')
        const client = fakeClient(async (method) => method === 'account/read'
            ? { account: { type: 'chatgpt', email: 'same@example.test' } } : limits)
        expect((await queryCodexNativeRateLimits(1000, credentials, { client, resolveCredentials: async () => credentials }))
            .fiveHour?.usedPercent).toBe(37)
    })

    it('does not use account A JSONL logs when account B live probe fails', async () => {
        root = await mkdtemp(join(tmpdir(), 'hapi-codex-quota-'))
        vi.stubEnv('CODEX_HOME', root)
        await mkdir(join(root, 'sessions'))
        const log = join(root, 'sessions', 'old-account-a.jsonl')
        const bytes = `${JSON.stringify({ type: 'session_meta', payload: { id: 'session-a', model_provider: 'openai' } })}\n${JSON.stringify({ type: 'event_msg', payload: { type: 'token_count', rate_limits: { primary: { used_percent: 99, window_minutes: 300 } } } })}\n`
        await writeFile(log, bytes)
        const credentials = identity('account-b')
        const client = fakeClient(async () => { throw new Error('private-native-error') })
        await expect(queryCodexNativeRateLimits(1000, credentials, { client, resolveCredentials: async () => credentials }))
            .rejects.toThrow('historical logs have no account proof')
        expect(await readFile(log, 'utf8')).toBe(bytes)
    })

    it('rejects changed accounts even when they share the same email', async () => {
        const credentials = identity('account-a')
        let current = credentials
        const client = fakeClient(async (method) => {
            if (method === 'account/rateLimits/read') { current = identity('account-b'); return limits }
            return { account: { type: 'chatgpt', email: 'same@example.test' } }
        })
        await expect(queryCodexNativeRateLimits(1000, credentials, { client, resolveCredentials: async () => current }))
            .rejects.toThrow('account changed during query')
    })

    it('rejects token rotation during the probe, not only an account-id change', async () => {
        const credentials = identity('account-a', 'token-one')
        let current = credentials
        const client = fakeClient(async (method) => {
            if (method === 'account/rateLimits/read') { current = identity('account-a', 'token-two'); return limits }
            return account('account-a')
        })
        await expect(queryCodexNativeRateLimits(1000, credentials, { client, resolveCredentials: async () => current }))
            .rejects.toThrow('account changed during query')
    })

    it('rejects unauthenticated, mismatched or unprovable native accounts without exposing identifiers', async () => {
        const credentials = identity('account-a')
        for (const response of [{ account: null }, account('account-b'), { account: { type: 'apiKey' } }, { account: { type: 'chatgpt' } }]) {
            const client = fakeClient(async () => response)
            await expect(queryCodexNativeRateLimits(1000, credentials, { client, resolveCredentials: async () => credentials }))
                .rejects.toThrow('identity could not be verified')
            expect(client.request).toHaveBeenCalledTimes(1)
        }
    })

    it('does not start a native process when no current OAuth identity exists', async () => {
        const client = fakeClient(async () => limits)
        await expect(queryCodexNativeRateLimits(1000, { ...identity('a'), codexAccount: undefined }, { client }))
            .rejects.toThrow('current OAuth account cannot be verified')
        expect(client.connect).not.toHaveBeenCalled()
    })

    it('refuses native proof for a relative home before starting a same-email account process', async () => {
        root = await mkdtemp(join(tmpdir(), 'hapi-codex-relative-home-'))
        await writeFile(join(root, 'auth.json'), JSON.stringify({ auth_mode: 'chatgpt', tokens: {
            account_id: 'account-a', access_token: 'token-fixture',
            id_token: `header.${Buffer.from(JSON.stringify({ email: 'same@example.test' })).toString('base64url')}.signature`
        } }))
        const relativeHome = relative(process.cwd(), root)
        const credentials = await resolveUsageCredentials('codex', { CODEX_HOME: relativeHome })
        expect(credentials).toMatchObject({ codexHome: relativeHome, apiKey: 'account-a', codexAccount: { id: 'account-a' } })
        const client = fakeClient(async (method) => method === 'account/read'
            ? { account: { type: 'chatgpt', email: 'same@example.test' } } : limits)
        await expect(queryCodexNativeRateLimits(1000, credentials, { client, resolveCredentials: async () => credentials }))
            .rejects.toThrow('CODEX_HOME must be absolute')
        expect(client.connect).not.toHaveBeenCalled()
        expect(client.request).not.toHaveBeenCalled()
    })

    it('stops issuing follow-up RPCs after a quota request times out', async () => {
        const credentials = identity('account-a')
        let release!: (value: unknown) => void
        const client = fakeClient(async (method) => method === 'account/read'
            ? account('account-a') : await new Promise((resolve) => { release = resolve }))
        await expect(queryCodexNativeRateLimits(10, credentials, { client, resolveCredentials: async () => credentials }))
            .rejects.toThrow('timed out')
        release(limits)
        await new Promise((resolve) => setTimeout(resolve, 0))
        expect(client.request.mock.calls.map(([method]) => method)).toEqual(['account/read', 'account/rateLimits/read'])
        expect(client.disconnect).toHaveBeenCalledOnce()
    })

    it('does not initialize after a late connection finishes beyond its deadline', async () => {
        const credentials = identity('account-a')
        let release!: () => void
        const client = fakeClient(async () => limits)
        client.connect.mockImplementation(async () => await new Promise<void>((resolve) => { release = resolve }))
        await expect(queryCodexNativeRateLimits(10, credentials, { client, resolveCredentials: async () => credentials }))
            .rejects.toThrow('timed out')
        release()
        await new Promise((resolve) => setTimeout(resolve, 0))
        expect(client.initialize).not.toHaveBeenCalled()
        expect(client.request).not.toHaveBeenCalled()
    })
})
