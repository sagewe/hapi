import type { UserTextBlock } from './types'
import type { VisibleChatBlock } from './toolGroups'

export type InitialResponseState = 'sending' | 'waiting' | 'thinking'

/** Ephemeral feedback, never a persisted assistant message or a tool activity. */
export function initialResponseState(blocks: readonly VisibleChatBlock[], options: {
    isSending: boolean
    isRunning: boolean
    isActive: boolean
    activeTurnStartedAt?: number | null
    completedRounds?: ReadonlySet<string>
    isHistory?: boolean
    isHydrating?: boolean
}): InitialResponseState | null {
    if (options.isHistory) return null
    if (options.isSending) return 'sending'
    if (!options.isActive || options.isHydrating) return null
    const flat = blocks.flatMap(block => block.kind === 'tool-group' ? block.processBlocks ?? block.tools : [block])
    const userIndex = flat.findLastIndex(block => block.kind === 'user-text')
    const user = userIndex >= 0 ? flat[userIndex] as UserTextBlock : undefined
    const start = options.activeTurnStartedAt
    const belongsToRun = user && (start == null || (user.invokedAt ?? user.createdAt) >= start)
    if (user?.status === 'failed' && (!options.isRunning || belongsToRun)) return null
    const hasOutput = flat.slice(userIndex + 1).some(block => {
        if (block.kind === 'agent-event' || block.kind === 'user-text') return false
        if ((block.kind === 'agent-text' || block.kind === 'agent-reasoning') && !block.text.trim()) return false
        return !options.isRunning || start == null || (block.invokedAt ?? block.createdAt) >= start
    })
    // Materialized output is authoritative, including when reopening a live chat.
    if (hasOutput) return null
    if (options.isRunning) return belongsToRun && user.invokedAt != null ? 'thinking' : 'waiting'
    if (!user || user.invokedAt != null || options.completedRounds?.has(user.id)) return null
    if (user.status === 'sending') return 'sending'
    if (user.localId && (user.status === 'sent' || user.status === 'queued')) return 'waiting'
    return null
}
