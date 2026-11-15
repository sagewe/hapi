import { describe, expect, it } from 'bun:test'
import { AgentSessionTagsRequestSchema, AgentSessionTagsResultSchema, SessionTagsContextSchema } from './apiTypes'

describe('agent session tags protocol', () => {
    it('trims and deduplicates case-insensitively while retaining first spelling/order', () => {
        expect(AgentSessionTagsRequestSchema.parse({ tags: [' Work ', 'work', '家庭'] })).toEqual({ tags: ['Work', '家庭'] })
    })
    it.each([[], [''], ['   '], ['x'.repeat(65)], ['a','b','c','d']])('rejects invalid suggestion array %j', tags => {
        expect(AgentSessionTagsRequestSchema.safeParse({ tags }).success).toBe(false)
    })
    it('does not permit raw title/lock fields in append requests', () => {
        expect(AgentSessionTagsRequestSchema.safeParse({ tags: ['work'], titleLocked: false }).success).toBe(false)
    })
    it('bounds context and result arrays', () => {
        expect(SessionTagsContextSchema.safeParse({ tags: [], availableTags: Array.from({ length: 201 }, (_, i) => `t${i}`), titleLocked: false, truncated: true }).success).toBe(false)
        expect(AgentSessionTagsResultSchema.parse({ tags: ['Manual'], added: [], skipped: ['Suggestion'], limitReached: true }).tags).toEqual(['Manual'])
    })
})
