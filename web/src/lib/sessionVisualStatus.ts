import { computePendingRequestKinds, computePendingRequestsCount } from '@hapi/protocol'
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
    const count = computePendingRequestsCount(session.agentState)
    if (session.active && count > 0) {
        return resolvePendingTier(computePendingRequestKinds(session.agentState), count)
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
