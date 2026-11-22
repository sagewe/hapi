import { describe, expect, it } from 'bun:test'
import { ClientProfileSchema, UpdateHubSettingsRequestSchema } from './apiTypes'

describe('client profile contract', () => {
    it('defaults omitted mode to developer and accepts assistant-only updates', () => {
        expect(ClientProfileSchema.parse({}).mode).toBe('developer')
        expect(UpdateHubSettingsRequestSchema.parse({ clientProfile: { mode: 'assistant' } }).clientProfile?.mode).toBe('assistant')
    })
    it('rejects invalid defaults and unbounded action lists', () => {
        expect(ClientProfileSchema.safeParse({ mode: 'other' }).success).toBe(false)
        expect(ClientProfileSchema.safeParse({ defaultPermissionMode: 'invalid' }).success).toBe(false)
        expect(ClientProfileSchema.safeParse({ quickActions: [{ id: 'one', title: 'test', prompt: '' }] }).success).toBe(false)
    })
})
