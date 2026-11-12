import type { PendingRequestKind, Session, SessionSummary } from '@/types/api'

export type SessionQuickStatusLens = 'attention' | 'running' | 'background'

export type SessionVisualStatus =
    | { tier: 'approval'; count: number; lens: 'attention' }
    | { tier: 'reply'; count: number; lens: 'attention' }
    | { tier: 'attention'; count: number; lens: 'attention' }
    | { tier: 'running'; lens: 'running' }
    | { tier: 'background'; count: number; lens: 'background' }
    | { tier: 'online' }
    | { tier: 'archived' }
    | { tier: 'offline' }

const INPUT_REQUEST_TOOLS = new Set([
    'AskUserQuestion',
    'ask_user_question',
    'ask_question',
    'Run ask_question',
    'ExitPlanMode',
    'exit_plan_mode',
    'request_user_input',
])

function resolvePendingTier(
    kinds: readonly PendingRequestKind[],
    count: number
): SessionVisualStatus {
    const hasPermission = kinds.includes('permission')
    const hasInput = kinds.includes('input')
    if (hasInput && !hasPermission) {
        return { tier: 'reply', count, lens: 'attention' }
    }
    if (hasPermission && !hasInput) {
        return { tier: 'approval', count, lens: 'attention' }
    }
    return { tier: 'attention', count, lens: 'attention' }
}

export function classifySessionRowVisualStatus(summary: SessionSummary): SessionVisualStatus {
    const pendingCount = summary.pendingRequestsCount ?? 0
    if (summary.active && pendingCount > 0) {
        return resolvePendingTier(summary.pendingRequestKinds ?? [], pendingCount)
    }
    if (summary.active && summary.thinking) {
        return { tier: 'running', lens: 'running' }
    }
    const bgCount = summary.backgroundTaskCount ?? 0
    if (summary.active && bgCount > 0) {
        return { tier: 'background', count: bgCount, lens: 'background' }
    }
    if (summary.active) {
        return { tier: 'online' }
    }
    if (summary.metadata?.lifecycleState === 'archived') {
        return { tier: 'archived' }
    }
    return { tier: 'offline' }
}

export function classifySessionDetailVisualStatus(session: Session): SessionVisualStatus {
    const requests = session.agentState?.requests
    const entries = requests ? Object.values(requests) : []
    if (session.active && entries.length > 0) {
        const kinds: PendingRequestKind[] = []
        for (const req of entries) {
            const kind: PendingRequestKind = INPUT_REQUEST_TOOLS.has(req.tool) ? 'input' : 'permission'
            if (!kinds.includes(kind)) {
                kinds.push(kind)
            }
        }
        return resolvePendingTier(kinds, entries.length)
    }
    if (session.active && session.thinking) {
        return { tier: 'running', lens: 'running' }
    }
    const bgCount = session.backgroundTaskCount ?? 0
    if (session.active && bgCount > 0) {
        return { tier: 'background', count: bgCount, lens: 'background' }
    }
    if (session.active) {
        return { tier: 'online' }
    }
    if (session.metadata?.lifecycleState === 'archived') {
        return { tier: 'archived' }
    }
    return { tier: 'offline' }
}

export function getSessionRowQuickLens(summary: SessionSummary): SessionQuickStatusLens | null {
    const status = classifySessionRowVisualStatus(summary)
    return 'lens' in status ? status.lens : null
}
