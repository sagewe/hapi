import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { SessionSummary } from '@/types/api'
import { I18nProvider } from '@/lib/i18n-context'
import { ToastProvider } from '@/lib/toast-context'
import { markSessionSeen } from '@/lib/sessionLastSeen'
import { SessionList } from './SessionList'

afterEach(() => cleanup())

function makeSession(overrides: Partial<SessionSummary> & { id: string }): SessionSummary {
    return {
        active: false,
        thinking: false,
        activeAt: 0,
        updatedAt: 0,
        metadata: null,
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
        contentRevision: overrides.updatedAt ?? 0,
        ...overrides
    }
}

function renderWithProviders(children: ReactNode) {
    return render(
        <QueryClientProvider client={new QueryClient({
            defaultOptions: {
                queries: { retry: false },
                mutations: { retry: false },
            }
        })}>
            <ToastProvider>
                <I18nProvider>{children}</I18nProvider>
            </ToastProvider>
        </QueryClientProvider>
    )
}

function renderSessionList(sessions: SessionSummary[], headerActions?: ReactNode) {
    return renderWithProviders(
        <SessionList
            sessions={sessions}
            selectedSessionId={null}
            onSelect={vi.fn()}
            onNewSession={vi.fn()}
            onRefresh={vi.fn()}
            isLoading={false}
            renderHeader
            headerActions={headerActions}
            api={null}
        />
    )
}

function seedReads(values: Record<string, number>) {
    for (const [id, revision] of Object.entries(values)) markSessionSeen(id, revision)
}

describe('SessionList unread visibility', () => {
    beforeEach(() => {
        localStorage.clear()
    })

    it('keeps unread rows of a collapsed project visible and folds the read ones', () => {
        seedReads({ read: 1000, unread: 1000 })
        renderSessionList([
            makeSession({ id: 'read', updatedAt: 1000, metadata: { path: '/work/quiet', name: 'Read row' } }),
            makeSession({ id: 'unread', updatedAt: 2000, metadata: { path: '/work/quiet', name: 'Unread row' } })
        ])

        // Inactive projects start collapsed; only the unread row peeks out.
        expect(screen.getByTestId('session-group-unread-peek')).toBeInTheDocument()
        expect(screen.getByRole('button', { name: /Unread row/ })).toBeInTheDocument()
        expect(screen.queryByRole('button', { name: /Read row/ })).toBeNull()

        fireEvent.click(screen.getByTitle('/work/quiet'))
        expect(screen.queryByTestId('session-group-unread-peek')).toBeNull()
        expect(screen.getByRole('button', { name: /Unread row/ })).toBeInTheDocument()
        expect(screen.getByRole('button', { name: /Read row/ })).toBeInTheDocument()
    })

    it('shows nothing under a collapsed project once everything is read', () => {
        seedReads({ read: 1000 })
        renderSessionList([
            makeSession({ id: 'read', updatedAt: 1000, metadata: { path: '/work/quiet', name: 'Read row' } })
        ])

        expect(screen.queryByTestId('session-group-unread-peek')).toBeNull()
        expect(screen.queryByRole('button', { name: /Read row/ })).toBeNull()
    })
})

describe('SessionList toolbar order', () => {
    beforeEach(() => {
        localStorage.clear()
    })

    const slotIds = () => Array.from(document.querySelectorAll('[data-testid^="session-toolbar-slot-"]'))
        .map(node => node.getAttribute('data-testid')?.replace('session-toolbar-slot-', ''))

    it('groups list controls, then New, then navigation, with mark all read last', () => {
        seedReads({ unread: 1000 })
        renderSessionList(
            [makeSession({ id: 'unread', updatedAt: 2000, metadata: { path: '/work/unread', name: 'Unread' } })],
            <button type="button">Settings</button>
        )

        expect(slotIds()).toEqual(['view', 'new', 'header-actions', 'mark-all'])
    })

    it('keeps the other controls in place when there is nothing unread', () => {
        seedReads({ read: 1000 })
        renderSessionList(
            [makeSession({ id: 'read', updatedAt: 1000, metadata: { path: '/work/read', name: 'Read' } })],
            <button type="button">Settings</button>
        )

        expect(slotIds()).toEqual(['view', 'new', 'header-actions'])
    })
})

describe('personal filters with upstream list controls', () => {
    beforeEach(() => localStorage.clear())

    it('hides only explicitly archived sessions and can include them from the new menu', () => {
        renderSessionList([
            makeSession({ id: 'offline', updatedAt: 2000, metadata: { path: '/work/offline', name: 'Offline visible' } }),
            makeSession({ id: 'archived', updatedAt: 2000, metadata: { path: '/work/archive', name: 'Archive hidden', lifecycleState: 'archived' } })
        ])
        expect(screen.getByRole('button', { name: /Offline visible/ })).toBeInTheDocument()
        expect(screen.queryByRole('button', { name: /Archive hidden/ })).toBeNull()
        fireEvent.click(screen.getByRole('button', { name: 'Sort and filter' }))
        fireEvent.click(screen.getByRole('menuitemcheckbox', { name: 'Show archived sessions' }))
        expect(screen.getByRole('button', { name: /Archive hidden/ })).toBeInTheDocument()
        fireEvent.click(screen.getByRole('menuitemradio', { name: 'Archived only' }))
        expect(screen.queryByRole('button', { name: /Offline visible/ })).toBeNull()
        expect(screen.getByRole('button', { name: /Archive hidden/ })).toBeInTheDocument()
    })

    it('combines inclusive local date filtering with status and reset', () => {
        const day = (value: number) => new Date(2026, 10, value, 23, 59).getTime()
        renderSessionList([
            makeSession({ id: 'early', active: true, updatedAt: day(3), metadata: { path: '/work/dates', name: 'Early result' } }),
            makeSession({ id: 'late', active: true, updatedAt: day(4), metadata: { path: '/work/dates', name: 'Late result' } })
        ])
        fireEvent.click(screen.getByRole('button', { name: 'Sort and filter' }))
        fireEvent.change(screen.getByLabelText('Select start date'), { target: { value: '2026-11-04' } })
        fireEvent.change(screen.getByLabelText('Select end date'), { target: { value: '2026-11-04' } })
        expect(screen.queryByRole('button', { name: /Early result/ })).toBeNull()
        expect(screen.getByRole('button', { name: /Late result/ })).toBeInTheDocument()
        fireEvent.click(screen.getByRole('menuitem', { name: 'Reset to default' }))
        expect(screen.getByRole('button', { name: /Early result/ })).toBeInTheDocument()
    })
})
