import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { SessionSummary } from '@/types/api'
import { I18nProvider } from '@/lib/i18n-context'
import { ToastProvider } from '@/lib/toast-context'
import { SessionList } from './SessionList'

afterEach(() => cleanup())

function makeSession(overrides: Partial<SessionSummary> & { id: string }): SessionSummary {
    return {
        active: true,
        thinking: false,
        activeAt: 100,
        updatedAt: 100,
        lastUserMessageAt: 100,
        hasConversationContent: true,
        metadata: { path: '/work/project', name: overrides.id, machineId: 'machine-1', flavor: 'claude' },
        metadataVersion: 0,
        agentStateVersion: 0,
        todosUpdatedAt: 0,
        todoProgress: null,
        pendingRequestsCount: 0,
        pendingRequestKinds: [],
        pendingRequests: [],
        backgroundTaskCount: 0,
        futureScheduledMessageCount: 0,
        nextScheduledAt: null,
        model: null,
        effort: null,
        ...overrides,
    }
}

function renderList(sessions: SessionSummary[]) {
    const queryClient = new QueryClient({
        defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
    })
    return render(
        <QueryClientProvider client={queryClient}>
            <ToastProvider>
                <I18nProvider>
                    <SessionList
                        sessions={sessions}
                        selectedSessionId={null}
                        onSelect={vi.fn()}
                        onNewSession={vi.fn()}
                        onRefresh={vi.fn()}
                        isLoading={false}
                        renderHeader={true}
                        api={null}
                        machineLabelsById={{ 'machine-1': 'Mac' }}
                    />
                </I18nProvider>
            </ToastProvider>
        </QueryClientProvider>
    )
}

describe('SessionList quick status summary bar and left status stripes', () => {
    beforeEach(() => window.localStorage.clear())

    it('hides the quick status bar when all sessions are idle or offline', () => {
        const { container } = renderList([
            makeSession({ id: 'idle-connected', active: true }),
            makeSession({ id: 'offline-session', active: false }),
        ])

        expect(screen.queryByTestId('session-quick-status-bar')).toBeNull()
        expect(container.querySelectorAll('[data-testid="session-status-stripe"]')).toHaveLength(0)
    })

    it('renders status stripes and filters via quick status pills without hiding peer counts or reordering', () => {
        const { container } = renderList([
            makeSession({
                id: 'First idle',
                active: true,
                lastUserMessageAt: 400,
            }),
            makeSession({
                id: 'Second running',
                active: true,
                thinking: true,
                lastUserMessageAt: 300,
            }),
            makeSession({
                id: 'Third approval',
                active: true,
                pendingRequestsCount: 1,
                pendingRequestKinds: ['permission'],
                lastUserMessageAt: 200,
            }),
            makeSession({
                id: 'Fourth background',
                active: true,
                backgroundTaskCount: 2,
                lastUserMessageAt: 100,
            }),
        ])

        expect(screen.getByTestId('session-quick-status-bar')).toBeInTheDocument()
        expect(screen.getByTestId('session-quick-status-attention')).toHaveTextContent('Needs action1')
        expect(screen.getByTestId('session-quick-status-running')).toHaveTextContent('Running1')
        expect(screen.getByTestId('session-quick-status-background')).toHaveTextContent('Background1')

        // 3 active status stripes (approval, running, background); connected-idle has none
        expect(container.querySelectorAll('[data-testid="session-status-stripe"]')).toHaveLength(3)

        // Preserves existing list order when unfiltered
        const initialTitles = Array.from(container.querySelectorAll('[data-session-scroll-anchor] [title]'))
            .map((el) => el.getAttribute('title'))
            .filter((t): t is string => Boolean(t && ['First idle', 'Second running', 'Third approval', 'Fourth background'].includes(t)))
        expect(initialTitles).toEqual(['First idle', 'Second running', 'Third approval', 'Fourth background'])

        // Clicking Running filters to running only while keeping Needs action & Background peer pills visible
        fireEvent.click(screen.getByTestId('session-quick-status-running'))
        expect(screen.getByText('Second running')).toBeInTheDocument()
        expect(screen.queryByText('First idle')).toBeNull()
        expect(screen.queryByText('Third approval')).toBeNull()
        expect(screen.getByTestId('session-quick-status-attention')).toHaveTextContent('Needs action1')
        expect(screen.getByTestId('session-quick-status-background')).toHaveTextContent('Background1')

        // Toggling Running off restores all sessions
        fireEvent.click(screen.getByTestId('session-quick-status-running'))
        expect(screen.getByText('First idle')).toBeInTheDocument()
        expect(screen.getByText('Third approval')).toBeInTheDocument()
    })
})
