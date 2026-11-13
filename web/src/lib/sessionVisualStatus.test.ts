import { describe, expect, it } from 'vitest'
import { toSessionSummary } from '@hapi/protocol'
import type { Session } from '@/types/api'
import { classifySessionDetailVisualStatus, classifySessionRowVisualStatus } from './sessionVisualStatus'

function session(thinking: boolean, blocking = false): Session {
    return {
        id: 'session', namespace: 'default', seq: 0, createdAt: 1000, active: true, activeAt: 1000,
        updatedAt: 1000, metadata: null, metadataVersion: 0, agentStateVersion: 0,
        thinking, thinkingAt: 1000, model: null, effort: null, modelReasoningEffort: null, serviceTier: null,
        agentState: { requests: {
            optional: { tool: 'request_user_input', arguments: { isBlocking: false } },
            ...(blocking ? { approval: { tool: 'Bash', arguments: { isBlocking: false } } } : {})
        } }
    }
}

describe('non-blocking question status', () => {
    it.each([true, false])('preserves real activity in row and detail when thinking=%s', (thinking) => {
        const value = session(thinking)
        const expected = thinking ? { tier: 'running', lens: 'running' } : { tier: 'online' }
        expect(classifySessionDetailVisualStatus(value)).toEqual(expected)
        expect(classifySessionRowVisualStatus(toSessionSummary(value))).toEqual(expected)
        expect(value.agentState?.requests?.optional).toBeDefined()
    })
    it('still prioritizes real permission requests', () => {
        const value = session(true, true)
        const expected = { tier: 'approval', count: 1, lens: 'attention' }
        expect(classifySessionDetailVisualStatus(value)).toEqual(expected)
        expect(classifySessionRowVisualStatus(toSessionSummary(value))).toEqual(expected)
    })
})
