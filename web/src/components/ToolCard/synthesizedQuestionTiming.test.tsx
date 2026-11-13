import { act, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ApiClient } from '@/api/client'
import type { ToolCallBlock } from '@/chat/types'
import { I18nProvider } from '@/lib/i18n-context'
import { ToolCard } from './ToolCard'

function question(askedAt?: number, state: 'pending' | 'completed' = 'pending'): ToolCallBlock {
    return {
        kind: 'tool-call', id: 'synth-q', localId: null, createdAt: 40_000,
        tool: {
            id: 'synth-q', name: 'AskUserQuestion', state,
            input: { questions: [{ header: 'Database', question: 'Which database?', multiSelect: false, options: [{ label: 'SQLite', description: 'Local' }] }] },
            createdAt: 40_000, startedAt: null, completedAt: state === 'completed' ? 45_000 : null,
            execStartedAt: null, execCompletedAt: null, description: null,
            permission: { id: 'request-q', status: state === 'pending' ? 'pending' : 'resolved', ...(askedAt === undefined ? {} : { createdAt: askedAt }) }
        }, children: []
    }
}

function card(block: ToolCallBlock) {
    return <I18nProvider><ToolCard api={{} as ApiClient} sessionId="test-session"
        metadata={null} terminalToolDisplayMode="compact" disabled={false}
        onDone={() => {}} block={block} /></I18nProvider>
}

function elapsed() {
    return screen.queryByText('Duration')?.parentElement?.lastElementChild?.textContent ?? null
}

afterEach(() => vi.useRealTimers())

describe('synthesized pending question timing', () => {
    it('counts from the request creation time and advances while waiting without transcript timing', () => {
        vi.useFakeTimers()
        vi.setSystemTime(45_000)
        const { unmount } = render(card(question(40_000)))
        expect(elapsed()).toBe('5.0s')
        act(() => vi.advanceTimersByTime(2_000))
        expect(elapsed()).toBe('7.0s')
        expect(screen.queryByText('Finished')).toBeNull()
        unmount()
        expect(vi.getTimerCount()).toBe(0)
    })

    it('does not fabricate a zero wait when the request carries no timestamp', () => {
        render(card(question()))
        expect(elapsed()).toBeNull()
    })

    it('stops its waiting timer after the answer resolves', () => {
        vi.useFakeTimers()
        vi.setSystemTime(45_000)
        const { rerender } = render(card(question(40_000)))
        expect(elapsed()).toBe('5.0s')
        rerender(card(question(40_000, 'completed')))
        expect(vi.getTimerCount()).toBe(0)
    })
})
