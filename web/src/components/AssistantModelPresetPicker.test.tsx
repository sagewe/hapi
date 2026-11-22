import { cleanup, render, fireEvent, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ApiClient } from '@/api/client'
import type { Session } from '@/types/api'
import { AssistantChatModelPicker } from './AssistantModelPresetPicker'
afterEach(cleanup)
it('hot-switches both model and effort and waits for server state to mark selection', async () => {
    const setModel = vi.fn().mockResolvedValue(undefined)
    const query = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const profile = { mode: 'assistant' as const, modelPresets: [
        { id: 'quick', label: '快速', model: 'gemini-4-hydrogen-medium', effort: 'medium' },
        { id: 'deep', label: '深度', model: 'gemini-4-neon-high', effort: 'high', isDefault: true }
    ] }
    render(<QueryClientProvider client={query}><AssistantChatModelPicker profile={profile}
        api={{ setModel } as unknown as ApiClient}
        session={{ id: 'case', active: true, model: 'gemini-4-neon', effort: 'high' } as Session} /></QueryClientProvider>)
    expect(screen.getByRole('button', { name: '深度' })).toHaveAttribute('aria-pressed', 'true')
    fireEvent.click(screen.getByRole('button', { name: '快速' }))
    await waitFor(() => expect(setModel).toHaveBeenCalledWith('case', 'gemini-4-hydrogen-medium', { effort: 'medium' }))
    expect(screen.getByRole('button', { name: '快速' })).toHaveAttribute('aria-pressed', 'false')
    expect(screen.queryByText(/gemini-4/)).toBeNull()
    query.clear()
})
