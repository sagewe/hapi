import { AssistantRuntimeProvider, useLocalRuntime } from '@assistant-ui/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { ApiClient } from '@/api/client'
import { HappyComposer } from './HappyComposer'

vi.mock('@/lib/client-profile', () => ({ useClientProfile: () => ({ mode: 'assistant', modelPresets: [
    { id: 'quick', label: '快速', model: 'gemini-4-hydrogen-medium', effort: 'medium' },
    { id: 'deep', label: '深度', model: 'gemini-4-neon-high', effort: 'high', isDefault: true },
] }) }))
vi.mock('@/hooks/useComposerDraft', () => ({ useComposerDraft: () => ({ sessionId: 'case', complete: true, restoredAny: false, hasStoredAttachments: false }) }))
vi.mock('@/components/AssistantChat/StatusBar', () => ({ StatusBar: () => null }))
vi.mock('@/lib/use-translation', () => ({ useTranslation: () => ({ t: (key: string) => key }) }))
afterEach(cleanup)

function Composer({ api, flavor = 'agy' }: { api: ApiClient; flavor?: string }) {
    const runtime = useLocalRuntime({ async *run() {} })
    return <AssistantRuntimeProvider runtime={runtime}><HappyComposer sessionId="case" assistantApi={api}
        active agentFlavor={flavor} model="gemini-4-neon" effort="high" /></AssistantRuntimeProvider>
}

it('shows and hot-switches the composer capsule outside the message context provider', async () => {
    const setModel = vi.fn().mockResolvedValue(undefined)
    const query = new QueryClient()
    render(<QueryClientProvider client={query}><Composer api={{ setModel } as unknown as ApiClient} /></QueryClientProvider>)
    const capsule = screen.getByRole('button', { name: '切换调查档位' })
    expect(capsule).toHaveTextContent('深度')
    fireEvent.click(capsule)
    await waitFor(() => expect(setModel).toHaveBeenCalledWith('case', 'gemini-4-hydrogen-medium', { effort: 'medium' }))
    query.clear()
})

it('keeps only a quiet cross-check badge for Codex', () => {
    const query = new QueryClient()
    render(<QueryClientProvider client={query}><Composer api={{} as ApiClient} flavor="codex" /></QueryClientProvider>)
    expect(screen.getByText('交叉核验')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '切换调查档位' })).toBeNull()
    query.clear()
})
