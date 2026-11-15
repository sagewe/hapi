import { render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { describe, expect, it } from 'vitest'
import type { AgentState } from '@/types/api'
import { I18nProvider } from '@/lib/i18n-context'
import { StatusBar } from './StatusBar'

function status(requests: AgentState['requests']) {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    return render(<QueryClientProvider client={client}><I18nProvider>
        <StatusBar active thinking={false} agentFlavor="codex" agentState={{ requests }} />
    </I18nProvider></QueryClientProvider>)
}

describe('StatusBar pending attention semantics', () => {
    it('keeps optional questions answerable without claiming they block execution', () => {
        status({ optional: { tool: 'request_user_input', arguments: { isBlocking: false } } })
        expect(screen.queryByText('permission required')).toBeNull()
        expect(screen.getByText('online')).toBeInTheDocument()
    })

    it.each(['AskUserQuestion', 'request_user_input', 'CursorAskQuestion'])('distinguishes pending %s answers from tool approvals', (tool) => {
        status({ input: { tool, arguments: {} } })
        expect(screen.queryByText('permission required')).toBeNull()
        expect(screen.getByText('Needs reply')).toBeInTheDocument()
    })

    it('keeps actual approvals prominent even if arguments claim isBlocking false', () => {
        status({
            optional: { tool: 'request_user_input', arguments: { isBlocking: false } },
            permission: { tool: 'Bash', arguments: { isBlocking: false } }
        })
        expect(screen.getByText('permission required')).toBeInTheDocument()
        expect(screen.queryByText('online')).toBeNull()
    })
})
