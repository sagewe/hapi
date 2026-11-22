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

it('round-trips optional model presets without changing old profiles', () => {
    const modelPresets = [{ id: 'quick', label: '快速', model: 'gemini-4-hydrogen-medium', effort: 'medium' },
        { id: 'deep', label: '深度', model: 'gemini-4-neon-high', effort: 'high', isDefault: true }]
    expect(ClientProfileSchema.parse({ mode: 'assistant', modelPresets }).modelPresets).toEqual(modelPresets)
    expect(ClientProfileSchema.parse({}).modelPresets).toBeUndefined()
    expect(ClientProfileSchema.safeParse({ modelPresets: [{ id: 'broken', label: '深度' }] }).success).toBe(false)
})
