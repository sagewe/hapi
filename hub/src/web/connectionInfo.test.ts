import { describe, it, expect } from 'bun:test'
import { mkdtempSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { hubIdentity, privateConnectionURL } from './connectionInfo'

describe('Hub connection identity', () => {
    it('persists a public identity independently of credentials and addresses', () => {
        const root = mkdtempSync(join(tmpdir(), 'hapi-connection-'))
        try {
            const id = hubIdentity(root)
            expect(hubIdentity(root)).toBe(id)
            expect(id).toMatch(/^[a-f0-9-]{36}$/)
            expect(statSync(join(root, 'connection-id')).mode & 0o777).toBe(0o600)
        } finally { rmSync(root, { recursive: true }) }
    })
    it('advertises only a credential-free HTTPS origin', () => {
        expect(privateConnectionURL('https://host.example.test/')).toBe('https://host.example.test')
        for (const value of ['', 'http://host', 'https://a:b@host', 'https://host/path', 'https://host/?key=private']) {
            expect(privateConnectionURL(value)).toBeNull()
        }
    })
})
