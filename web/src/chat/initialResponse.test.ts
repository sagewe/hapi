import { describe, expect, it } from 'vitest'
import { initialResponseState } from './initialResponse'
import type { ChatBlock, UserTextBlock } from './types'
const idle = { isSending: false, isRunning: false, isActive: true }
const user = (status: UserTextBlock['status'] = 'sent', invokedAt: number | null = null): UserTextBlock => ({
    kind: 'user-text', id: 'u', localId: 'local', text: 'hello', createdAt: 1000, invokedAt, status
})
const reply: ChatBlock = { kind: 'agent-text', id: 'a', localId: null, text: 'First reply', createdAt: 2000 }
describe('initial response feedback', () => {
    it('bridges sending, accepted, invoked and first output without creating messages', () => {
        expect(initialResponseState([], { ...idle, isSending: true })).toBe('sending')
        expect(initialResponseState([user()], idle)).toBe('waiting')
        expect(initialResponseState([user('queued')], { ...idle, isRunning: true })).toBe('waiting')
        expect(initialResponseState([user('sent', 1100)], { ...idle, isRunning: true, activeTurnStartedAt: 1000 })).toBe('thinking')
        expect(initialResponseState([user('sent', 1100), reply], { ...idle, isRunning: true })).toBeNull()
    })
    it('removes feedback on failure, cancellation, disconnection and history navigation', () => {
        expect(initialResponseState([user('failed')], idle)).toBeNull()
        expect(initialResponseState([user('sent', 1100)], idle)).toBeNull()
        expect(initialResponseState([user()], { ...idle, completedRounds: new Set(['u']) })).toBeNull()
        expect(initialResponseState([user()], { ...idle, isRunning: true, isActive: false })).toBeNull()
        expect(initialResponseState([user()], { ...idle, isRunning: true, isHistory: true })).toBeNull()
        expect(initialResponseState([user()], { ...idle, isRunning: true, isHydrating: true })).toBeNull()
        expect(initialResponseState([], idle)).toBeNull()
    })
    it('does not mistake a previous response for output from the new run', () => {
        expect(initialResponseState([user('sent', 100), { ...reply, createdAt: 500 }], {
            ...idle, isRunning: true, activeTurnStartedAt: 1000, awaitingOutput: true
        })).toBe('waiting')
        expect(initialResponseState([user('sent', 1100), { ...reply, text: '   ' }], { ...idle, isRunning: true })).toBe('thinking')
    })
})
