import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { SessionSummary, Machine } from '@/types/api'
import { I18nProvider } from '@/lib/i18n-context'
import { ToastProvider } from '@/lib/toast-context'
import { SessionList } from './SessionList'

const SEARCH_LABEL = 'Search sessions (title, path, Agent, machine name, ID, and more)'
const SEARCH_PLACEHOLDER = 'Search title/path/Agent/machine/ID…'

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
        ...overrides
    }
}

function renderWithProviders(children: ReactNode) {
    const queryClient = new QueryClient({
        defaultOptions: {
            queries: { retry: false },
            mutations: { retry: false },
        }
    })

    return render(
        <QueryClientProvider client={queryClient}>
            <ToastProvider>
                <I18nProvider>
                    {children}
                </I18nProvider>
            </ToastProvider>
        </QueryClientProvider>
    )
}

function renderSessionList(sessions: SessionSummary[], machinesById?: Record<string, Machine>) {
    return renderWithProviders(
        <SessionList
            sessions={sessions}
            selectedSessionId={null}
            onSelect={vi.fn()}
            onNewSession={vi.fn()}
            onRefresh={vi.fn()}
            isLoading={false}
            renderHeader={false}
            api={null}
            machineLabelsById={{ 'machine-1': 'Mint', 'machine-2': 'Teemo' }}
            machinesById={machinesById}
        />
    )
}

function archiveToggle() {
    const recovery = screen.queryAllByRole('button', { name: 'Show archived sessions' }).find(button => !button.closest('[inert]'))
    if (recovery) return recovery
    let menu = screen.queryAllByRole('button', { name: 'Sort and filter' }).find(button => !button.closest('[inert]'))
    if (!menu) {
        fireEvent.click(screen.getByTestId('session-list-header-overflow'))
        menu = screen.getByRole('button', { name: 'Sort and filter' })
    }
    fireEvent.click(menu)
    return screen.getByRole('menuitemcheckbox', { name: 'Show archived sessions' })
}

describe('archived session visibility', () => {
    beforeEach(() => window.localStorage.clear())
    const archived = makeSession({ id: 'old', hasConversationContent: true, metadata: { path: '/work', name: 'Old history', machineId: 'machine-1', lifecycleState: 'archived' } })
    const offline = makeSession({ id: 'offline', hasConversationContent: true, metadata: { path: '/work', name: 'Offline work', machineId: 'machine-1' } })

    it('hides archives, preserves inactive history and offers a persistent toggle', () => {
        renderSessionList([archived, offline])
        expect(screen.queryByText('Old history')).toBeNull()
        fireEvent.click(screen.getByTitle('/work'))
        expect(screen.getByText('Offline work')).toBeTruthy()
        const toggle = archiveToggle()
        fireEvent.click(toggle)
        expect(screen.getByText('Old history')).toBeTruthy()
        expect(window.localStorage.getItem('hapi-show-archived-sessions')).toBe('true')
        cleanup()
        renderSessionList([archived, offline])
        if (!screen.queryByText('Old history')) fireEvent.click(screen.getByTitle('/work'))
        expect(screen.getByText('Old history')).toBeTruthy()
    })

    it('keeps the selected archive visible and responds to lifecycle changes', () => {
        const props = { sessions: [archived, offline], selectedSessionId: 'old', onSelect: vi.fn(), onNewSession: vi.fn(), onRefresh: vi.fn(), isLoading: false, api: null }
        const view = renderWithProviders(<SessionList {...props} />)
        expect(screen.getByText('Old history')).toBeTruthy()
        view.rerender(<QueryClientProvider client={new QueryClient()}><ToastProvider><I18nProvider><SessionList {...props} selectedSessionId={null} /></I18nProvider></ToastProvider></QueryClientProvider>)
        expect(screen.queryByText('Old history')).toBeNull()
    })

    it('finds hidden history from search without exposing unrelated archives', () => {
        renderSessionList([archived, offline])
        fireEvent.click(screen.getByRole('button', { name: SEARCH_LABEL }))
        fireEvent.change(screen.getByPlaceholderText(SEARCH_PLACEHOLDER), { target: { value: 'Old history' } })
        expect(screen.queryByText('Old history')).toBeNull()
        fireEvent.click(screen.getByRole('button', { name: 'Include archived sessions in search' }))
        expect(screen.getByText('Old history')).toBeTruthy()
        expect(screen.queryByText('Offline work')).toBeNull()
    })

    it('offers recovery when every session is archived', () => {
        renderSessionList([archived])
        expect(screen.queryByText('Old history')).toBeNull()
        fireEvent.click(archiveToggle())
        fireEvent.click(screen.getByTitle('/work'))
        expect(screen.getByText('Old history')).toBeTruthy()
    })
})
