import { describe, expect, it } from 'bun:test'
import { authenticateAccessToken, DEFAULT_NAMESPACE, parseAccessToken } from './accessToken'

describe('parseAccessToken', () => {
    it('defaults namespace when missing', () => {
        const parsed = parseAccessToken('token')
        expect(parsed).toEqual({ baseToken: 'token', namespace: DEFAULT_NAMESPACE })
    })

    it('parses namespace suffix', () => {
        const parsed = parseAccessToken('token:alice')
        expect(parsed).toEqual({ baseToken: 'token', namespace: 'alice' })
    })

    it('rejects empty namespace', () => {
        expect(parseAccessToken('token:')).toBeNull()
    })

    it('rejects missing base token', () => {
        expect(parseAccessToken(':alice')).toBeNull()
    })

    it('rejects whitespace inside namespace', () => {
        expect(parseAccessToken('token: alice')).toBeNull()
    })
})

describe('authenticateAccessToken', () => {
    const options = {
        cliApiToken: 'owner-secret-token',
        namespaces: {
            compliance: { token: 'compliance-independent-secret' },
            household: { token: 'household-independent-secret' },
            default: { token: 'ignored-default-override' },
            badColon: { token: 'invalid:token' }
        }
    }

    it('authenticates owner token for default and explicit namespaces', () => {
        expect(authenticateAccessToken('owner-secret-token', options)).toEqual({
            namespace: 'default',
            isOwnerToken: true
        })
        expect(authenticateAccessToken('owner-secret-token:compliance', options)).toEqual({
            namespace: 'compliance',
            isOwnerToken: true
        })
    })

    it('authenticates dedicated namespace tokens strictly into their own namespace', () => {
        expect(authenticateAccessToken('compliance-independent-secret', options)).toEqual({
            namespace: 'compliance',
            isOwnerToken: false
        })
        expect(authenticateAccessToken('household-independent-secret', options)).toEqual({
            namespace: 'household',
            isOwnerToken: false
        })
    })

    it('prevents namespace token escalation via :namespace suffix', () => {
        expect(authenticateAccessToken('compliance-independent-secret:default', options)).toBeNull()
        expect(authenticateAccessToken('compliance-independent-secret:household', options)).toBeNull()
        expect(authenticateAccessToken('compliance-independent-secret:compliance', options)).toBeNull()
    })

    it('ignores default override and malformed namespace tokens', () => {
        expect(authenticateAccessToken('ignored-default-override', options)).toBeNull()
        expect(authenticateAccessToken('invalid:token', options)).toBeNull()
        expect(authenticateAccessToken('wrong-token', options)).toBeNull()
    })
})
