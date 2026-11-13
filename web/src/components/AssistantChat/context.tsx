import type { ReactNode } from 'react'
import { createContext, useContext, useState } from 'react'
import type { ApiClient } from '@/api/client'
import type { TerminalToolDisplayMode } from '@/hooks/useToolCardDisplayMode'
import type { SessionMetadataSummary } from '@/types/api'

export type OlderHistoryLoadResult = 'loaded' | 'transient-stop' | 'terminal-stop'

export type HappyChatContextValue = {
    api: ApiClient
    sessionId: string
    metadata: SessionMetadataSummary | null
    terminalToolDisplayMode: TerminalToolDisplayMode
    /** Hub-wide AGENT_NOTIFY_SUMMARY chat display; polled once at chat shell. */
    showSessionSummaryInChat: boolean
    disabled: boolean
    allowInactiveFork?: boolean
    onRefresh: () => void
    onExecutionInspect?: (id: string) => void
    openExecutionProcesses?: ReadonlySet<string>
    setExecutionProcessOpen?: (id: string, open: boolean) => void
    codexPlanProposalId?: string | null
    onContinuePlan?: (planId: string) => void
    continuedPlanIds?: ReadonlySet<string>
    onRetryMessage?: (localId: string) => void
    historyActionPending?: boolean
    onForkConversation?: (messageLocalId?: string) => Promise<void>
    onRewindConversation?: (messageLocalId: string) => Promise<void>
    isLatestCompletedBoundary?: (messageId: string) => boolean
    onShareTurn?: (
        messageElement: HTMLElement | string | null,
        clientY?: number,
        fallbackSnapshot?: { html: string; text: string; role?: 'user' | 'assistant' }
    ) => void
    hasMoreMessages: boolean
    isSyncingTail: boolean
    isLoadingMoreMessages: boolean
    onNestedScrollFollowChange?: (followLatest: boolean) => void
    loadOlderMessagesPreservingScroll: () => Promise<OlderHistoryLoadResult>
}

const HappyChatContext = createContext<HappyChatContextValue | null>(null)

export function HappyChatProvider(props: { value: HappyChatContextValue; children: ReactNode }) {
    // Keep dismissal outside virtualized cards so recycling cannot revive a menu.
    const [continued, setContinued] = useState<{ sessionId: string; ids: ReadonlySet<string> }>({
        sessionId: props.value.sessionId, ids: new Set()
    })
    const ids = continued.sessionId === props.value.sessionId ? continued.ids : new Set<string>()
    const [processState, setProcessState] = useState<{ sessionId: string; ids: ReadonlySet<string> }>({ sessionId: props.value.sessionId, ids: new Set() })
    const processIds = processState.sessionId === props.value.sessionId ? processState.ids : new Set<string>()
    const value: HappyChatContextValue = {
        ...props.value,
        openExecutionProcesses: processIds,
        setExecutionProcessOpen: (id, open) => setProcessState(previous => {
            const ids = new Set(previous.sessionId === props.value.sessionId ? previous.ids : [])
            if (open) ids.add(id); else ids.delete(id)
            return { sessionId: props.value.sessionId, ids }
        }),
        continuedPlanIds: ids,
        onContinuePlan: props.value.onContinuePlan ? (planId) => {
            if (props.value.disabled || props.value.codexPlanProposalId !== planId || ids.has(planId)) return
            setContinued({ sessionId: props.value.sessionId, ids: new Set([...ids, planId]) })
            props.value.onContinuePlan?.(planId)
        } : undefined
    }
    return (
        <HappyChatContext.Provider value={value}>
            {props.children}
        </HappyChatContext.Provider>
    )
}

export function useOptionalHappyChatContext(): HappyChatContextValue | null {
    return useContext(HappyChatContext)
}

export function useHappyChatContext(): HappyChatContextValue {
    const ctx = useOptionalHappyChatContext()
    if (!ctx) {
        throw new Error('HappyChatContext is missing')
    }
    return ctx
}
