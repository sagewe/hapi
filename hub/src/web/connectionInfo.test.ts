import { describe, it, expect } from 'bun:test'
import { mkdtempSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { hubIdentity, privateConnectionURL, connectionOrigins } from './connectionInfo'

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

describe('LAN discovery', () => {
    it('keeps LAN distinct from the existing tailnet endpoint', () => {
        expect(connectionOrigins('https://tail.example', '')).toEqual({ privateUrl: 'https://tail.example', lanUrl: null })
        expect(connectionOrigins('https://tail.example', 'https://home.example:8443')).toEqual({ privateUrl: 'https://tail.example', lanUrl: 'https://home.example:8443' })
        expect(connectionOrigins('https://tail.example', 'https://tail.example/').lanUrl).toBeNull()
        expect(connectionOrigins('', 'http://192.168.1.2').lanUrl).toBeNull()
        expect(connectionOrigins('', 'https://user:secret@home.example').lanUrl).toBeNull()
    })
})
