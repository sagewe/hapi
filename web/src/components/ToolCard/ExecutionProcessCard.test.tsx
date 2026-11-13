import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { ApiClient } from '@/api/client'
import type { ToolGroupBlock } from '@/chat/toolGroups'
import { buildExecutionProcessBlocks } from '@/chat/executionProcess'
import { HappyChatProvider } from '@/components/AssistantChat/context'
import { I18nProvider } from '@/lib/i18n-context'
import { ExecutionProcessCard } from './ExecutionProcessCard'
vi.mock('@/components/MarkdownRenderer', () => ({ MarkdownRenderer: ({ content }: { content: string }) => <p>{content}</p> }))
afterEach(cleanup)
const follow = vi.fn()
const value = { api: {} as ApiClient, sessionId: 'session', metadata: null, terminalToolDisplayMode: 'compact' as const,
    showSessionSummaryInChat: false, disabled: false, onRefresh: vi.fn(), hasMoreMessages: false,
    isSyncingTail: false, isLoadingMoreMessages: false, onNestedScrollFollowChange: follow,
    loadOlderMessagesPreservingScroll: async () => 'terminal-stop' as const }
function group(text: string): ToolGroupBlock {
    return buildExecutionProcessBlocks([
        { kind: 'agent-text', id: 'progress', localId: null, createdAt: 1, text, meta: { assistantPhase: 'progress' } },
        { kind: 'agent-text', id: 'answer', localId: null, createdAt: 2, text: 'answer', meta: { assistantPhase: 'final' } }
    ], { completedRounds: new Set(['initial']), isRunning: false, hasMoreMessages: false })[0] as ToolGroupBlock
}
function tree(block: ToolGroupBlock | null) {
    return <I18nProvider><HappyChatProvider value={value}>{block ? <ExecutionProcessCard block={block} /> : null}</HappyChatProvider></I18nProvider>
}
it('retains user expansion across stream updates and recycled cards', () => {
    const view = render(tree(group('Earlier progress')))
    expect(screen.queryByText('Earlier progress')).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Execution process' }))
    expect(follow).toHaveBeenCalledWith(false)
    expect(screen.getByText('Earlier progress')).toBeVisible()
    view.rerender(tree(null))
    view.rerender(tree(group('Updated progress')))
    expect(screen.getByRole('button', { name: 'Execution process' })).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByText('Updated progress')).toBeVisible()
    fireEvent.click(screen.getByRole('button', { name: 'Execution process' }))
    expect(screen.queryByText('Updated progress')).not.toBeInTheDocument()
})
