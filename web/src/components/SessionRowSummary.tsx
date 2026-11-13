import { useMemo, useSyncExternalStore } from 'react'
import type { SessionSummary } from '@/types/api'
import { AgentFlavorIcon } from '@/components/AgentFlavorIcon'
import { InfoIcon, ScheduleIcon } from '@/components/icons'
import { HoverTooltip, SESSION_ROW_TOOLTIP_FOCUS_CLASS, useSessionRowTooltipIds } from '@/components/HoverTooltip'
import { getAttentionLabel, SessionAttentionIndicator, SessionRequestIcon } from '@/components/SessionAttentionIndicator'
import { classifySessionAttention, sessionIsUnread } from '@/lib/sessionAttention'
import { classifySessionRowVisualStatus } from '@/lib/sessionVisualStatus'
import { getSessionLastSeenAt, getSessionManualUnreadAt } from '@/lib/sessionLastSeen'
import { formatRelativeTime } from '@/lib/relativeTime'
import { formatScheduledTooltipDetail } from '@/lib/scheduledTime'
import { getCodexImportedAt, subscribeCodexImportedSessions } from '@/lib/codexImportedSessions'
import { useMinuteTick } from '@/hooks/useMinuteTick'
import { getSessionTitle } from '@/lib/sessionTitle'
import { useTranslation } from '@/lib/use-translation'
import { getWorktreeSessionLabel } from '@/lib/sessionWorktreeLabel'

function BulbIcon(props: { className?: string }) {
    return (
        <svg
            xmlns="http://www.w3.org/2000/svg"
            width="24"
            height="24"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            className={props.className}
        >
            <path d="M9 18h6" />
            <path d="M10 22h4" />
            <path d="M12 2a7 7 0 0 0-4 12c.6.6 1 1.2 1 2h6c0-.8.4-1.4 1-2a7 7 0 0 0-4-12Z" />
        </svg>
    )
}

function getTodoProgress(session: SessionSummary): { completed: number; total: number } | null {
    if (!session.todoProgress) return null
    if (session.todoProgress.completed === session.todoProgress.total) return null
    return session.todoProgress
}

function formatCodexImportedRelativeTime(
    value: number,
    t: (key: string, params?: Record<string, string | number>) => string
): string | null {
    const ms = value < 1_000_000_000_000 ? value * 1000 : value
    if (!Number.isFinite(ms)) return null
    const delta = Date.now() - ms
    if (delta < 60_000) return t('session.time.importedFromCodex.justNow')
    const minutes = Math.floor(delta / 60_000)
    if (minutes < 60) return t('session.time.importedFromCodex.minutesAgo', { n: minutes })
    const hours = Math.floor(minutes / 60)
    if (hours < 24) return t('session.time.importedFromCodex.hoursAgo', { n: hours })
    const days = Math.floor(hours / 24)
    if (days < 7) return t('session.time.importedFromCodex.daysAgo', { n: days })
    return formatRelativeTime(value, t)
}

function getSessionTimeLabel(
    session: SessionSummary,
    importedAt: number | null,
    t: (key: string, params?: Record<string, string | number>) => string
): string | null {
    if (importedAt !== null) {
        return formatCodexImportedRelativeTime(importedAt, t)
    }
    return formatRelativeTime(session.updatedAt, t)
}

/**
 * Presentational session row — same chrome as the sidebar SessionItem body
 * (flavor icon with presence badge, title, request/schedule symbols, todos,
 * relative time, path). Visual language matches the native apps: no dimmed
 * rows or spinners; unread sessions have a separate accent dot.
 * Used by the session list and by rich-composer mention chip tooltips.
 */
export function SessionRowSummary(props: {
    session: SessionSummary
    showPath?: boolean
    showDetailedStatus?: boolean
    selected?: boolean
    /**
     * When false, attention is a bare colored dot (no nested HoverTooltip).
     * Use false inside an already-open chip tooltip portal.
     */
    nestedTooltips?: boolean
    /** Pass from parent when the parent owns `aria-describedby` (session list). */
    attentionTooltipId?: string
    /** Recompute local unread attention when the session-list watermark changes. */
    lastSeenVersion?: number
    scheduleTooltipId?: string
    className?: string
    /** Rows inside the pinned "in progress" section skip the text label (dot only). */
    inRunningSection?: boolean
    /** Short project name shown under the title (pinned "in progress" rows). */
    projectLabel?: string
    /** Machine label shown next to the project name (pinned "in progress" rows). */
    machineLabel?: string
    /** Read-only parent session title hint when not visually nested under direct parent. */
    parentHint?: string | null
    /** Context returned by the opt-in session message-content search. */
    contentSnippet?: string
    /** The indexed message exceeded the search index budget. */
    contentSearchTruncated?: boolean
    /** Extra classes for the right-hand time/progress cluster (e.g. to yield to hover actions). */
    trailingClassName?: string
}) {
    const {
        session: s,
        showPath = true,
        showDetailedStatus = true,
        selected = false,
        nestedTooltips = true,
        attentionTooltipId: attentionTooltipIdProp,
        lastSeenVersion,
        scheduleTooltipId: scheduleTooltipIdProp,
        className,
        inRunningSection: _inRunningSection = false,
        projectLabel,
        machineLabel,
        parentHint,
        contentSnippet,
        contentSearchTruncated = false,
        trailingClassName,
    } = props
    const { t } = useTranslation()
    const sessionName = getSessionTitle(s)
    const worktreeLabel = getWorktreeSessionLabel(s)
    const todoProgress = getTodoProgress(s)
    const attention = useMemo(
        () => showDetailedStatus
            ? classifySessionAttention(s, {
                selected,
                lastSeenAt: getSessionLastSeenAt(s.id),
                manualUnreadAt: getSessionManualUnreadAt(s.id, s.readState),
            })
            : null,
        [s, selected, showDetailedStatus, lastSeenVersion]
    )
    const attentionLabel = attention ? getAttentionLabel(attention, t) : null
    const urgentAttention = attention !== null
        && (attention.kind === 'permission' || attention.kind === 'input')
    const scheduledLabel = s.futureScheduledMessageCount > 1
        ? t('session.item.scheduledMessages', { count: s.futureScheduledMessageCount })
        : t('session.item.scheduledMessage')
    const hasScheduleTooltip = showDetailedStatus && s.futureScheduledMessageCount > 0
    const ownedIds = useSessionRowTooltipIds(
        Boolean(attention) && nestedTooltips && !attentionTooltipIdProp,
        hasScheduleTooltip && nestedTooltips && !scheduleTooltipIdProp
    )
    const attentionId = attentionTooltipIdProp ?? ownedIds.attentionId
    const scheduleId = scheduleTooltipIdProp ?? ownedIds.scheduleId
    // Rows are memoized, so the label keeps itself current.
    useMinuteTick()
    const codexSessionId = s.metadata?.flavor === 'codex' ? s.metadata?.agentSessionId : null
    const importedAt = useSyncExternalStore(subscribeCodexImportedSessions, () => getCodexImportedAt(codexSessionId))
    const timeLabel = getSessionTimeLabel(s, importedAt, t)

    const visualStatus = classifySessionRowVisualStatus(s)
    const isRunning = visualStatus.tier === 'running'
    const isBackgroundOnly = visualStatus.tier === 'background'
    const isAttentionTier = visualStatus.tier === 'approval' || visualStatus.tier === 'reply' || visualStatus.tier === 'attention'
    const isDisconnected = !s.active
    const isUnread = sessionIsUnread(s, {
        lastSeenAt: getSessionLastSeenAt(s.id),
        manualUnreadAt: getSessionManualUnreadAt(s.id, s.readState),
    })
    const requestKind = urgentAttention
        ? attention.kind as 'permission' | 'input'
        : isAttentionTier
            ? (visualStatus.tier === 'reply' ? 'input' : 'permission')
            : null

    const presenceColorClass = isAttentionTier
        ? 'bg-amber-500'
        : isBackgroundOnly
            ? 'bg-sky-400 animate-pulse'
            : 'bg-[var(--app-badge-success-text)]'

    const agentIcon = (
        <span className="relative inline-flex h-6 w-6 shrink-0 items-center justify-center">
            {isRunning ? (
                <span
                    data-testid="session-running-ring"
                    aria-hidden="true"
                    className="pointer-events-none absolute -inset-1 rounded-full border-2 border-emerald-500/20 border-t-emerald-500 border-r-emerald-500/75 animate-spin"
                />
            ) : isAttentionTier ? (
                <span
                    aria-hidden="true"
                    className="pointer-events-none absolute -inset-0.5 rounded-full ring-1 ring-amber-500/55"
                />
            ) : null}
            <AgentFlavorIcon
                flavor={s.metadata?.flavor}
                className={`h-6 w-6 transition-opacity ${isDisconnected ? 'opacity-50' : ''}`}
            />
            {s.active ? (
                <span
                    data-testid="session-presence"
                    className={`absolute -bottom-0.5 -right-0.5 h-2.5 w-2.5 rounded-full ring-2 ring-[var(--app-bg)] ${presenceColorClass} ${isRunning ? 'animate-pulse' : ''}`}
                />
            ) : null}
        </span>
    )

    const rawStatusPill = (() => {
        if (isAttentionTier && requestKind) {
            const badgeKey = visualStatus.tier === 'approval'
                ? 'session.badge.approval'
                : visualStatus.tier === 'reply'
                    ? 'session.badge.reply'
                    : 'session.badge.attention'
            return (
                <span
                    data-testid="session-status-pill"
                    data-status-tier={visualStatus.tier}
                    className="inline-flex shrink-0 items-center gap-1 rounded-full border border-amber-500/35 bg-amber-500/15 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-[var(--app-badge-warning-text)]"
                >
                    <SessionRequestIcon
                        kind={requestKind}
                        label={attentionLabel ?? t(badgeKey)}
                    />
                    <span>{t(badgeKey)}</span>
                    {visualStatus.count > 1 ? (
                        <span className="tabular-nums">· {visualStatus.count}</span>
                    ) : null}
                </span>
            )
        }
        if (isRunning) {
            return (
                <span
                    data-testid="session-status-pill"
                    data-status-tier="running"
                    className="inline-flex shrink-0 items-center gap-1 rounded-full border border-emerald-500/30 bg-emerald-500/15 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-[var(--app-badge-success-text)]"
                >
                    <span
                        aria-hidden="true"
                        className="h-2.5 w-2.5 shrink-0 rounded-full border-[1.5px] border-current border-r-transparent animate-spin"
                    />
                    <span>{t('session.badge.running')}</span>
                </span>
            )
        }
        if (isBackgroundOnly) {
            return (
                <span
                    data-testid="session-status-pill"
                    data-status-tier="background"
                    className="inline-flex shrink-0 items-center gap-1 rounded-full border border-sky-400/30 bg-sky-500/15 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-sky-600 dark:text-sky-400"
                >
                    <span>{t('session.badge.background')}</span>
                    <span className="tabular-nums">· {visualStatus.count}</span>
                </span>
            )
        }
        if (visualStatus.tier === 'archived') {
            return (
                <span
                    data-testid="session-status-pill"
                    data-status-tier="archived"
                    className="inline-flex shrink-0 items-center rounded-full bg-[var(--app-subtle-bg)] px-1.5 py-0.5 text-[11px] font-medium leading-none text-[var(--app-hint)]"
                >
                    {t('session.badge.archived')}
                </span>
            )
        }
        return null
    })()

    const statusPillNode = rawStatusPill && nestedTooltips && attentionId && (
        (urgentAttention && isAttentionTier) || (attention?.kind === 'background' && isBackgroundOnly)
    ) ? (
        <SessionAttentionIndicator
            attention={attention}
            summary={s}
            label={attentionLabel ?? ''}
            tooltipId={attentionId}
            target={rawStatusPill}
        />
    ) : rawStatusPill

    const parentHintLabel = parentHint?.trim() || null
    const parentHintTooltip = parentHintLabel
        ? t('session.item.parentSession', { title: parentHintLabel })
        : undefined

    const secondaryText = projectLabel || machineLabel
        ? [projectLabel, machineLabel].filter(Boolean).join(' · ')
        : (showPath || worktreeLabel)
            ? (worktreeLabel ?? s.metadata?.path ?? s.id)
            : null
    const secondaryTitle = projectLabel || machineLabel
        ? [projectLabel, machineLabel].filter(Boolean).join(' · ')
        : worktreeLabel
            ? (s.metadata?.worktree?.worktreePath ?? s.metadata?.path)
            : undefined

    return (
        <div className={`flex w-full min-w-0 items-center gap-2.5 ${className ?? ''}`}>
            {agentIcon}
            <div className="flex min-w-0 flex-1 flex-col gap-0.5">
                <div className="grid grid-cols-[minmax(8rem,1fr)_minmax(0,max-content)] items-center gap-2">
                    <div className="flex min-w-0 items-center gap-2">
                        <div
                            className={`min-w-0 flex-1 truncate text-sm text-[var(--app-fg)] ${isUnread ? 'font-semibold' : isDisconnected ? 'font-normal opacity-80' : 'font-normal'}`}
                            title={sessionName}
                        >
                            {sessionName}
                        </div>
                        {isUnread ? (
                            <>
                                <span data-testid="session-unread" className="h-2 w-2 shrink-0 rounded-full bg-blue-500" aria-hidden="true" />
                                <span id={attention?.kind === 'unread' && nestedTooltips ? attentionId : undefined} className="sr-only">
                                    {t('session.item.newActivity')}
                                </span>
                            </>
                        ) : null}
                        {hasScheduleTooltip && nestedTooltips && scheduleId ? (
                            <HoverTooltip
                                id={scheduleId}
                                target={<ScheduleIcon className="h-3.5 w-3.5 text-[var(--app-hint)]" />}
                                side="bottom"
                                align="start"
                                className="shrink-0"
                                revealOnParentFocusClass={SESSION_ROW_TOOLTIP_FOCUS_CLASS}
                            >
                                <span className="block">
                                    <span className="block font-medium">{scheduledLabel}</span>
                                    <span className="mt-1 block text-[var(--app-hint)]">
                                        {formatScheduledTooltipDetail(s, t)}
                                    </span>
                                </span>
                            </HoverTooltip>
                        ) : hasScheduleTooltip ? (
                            <span className="shrink-0" aria-label={scheduledLabel} title={scheduledLabel}>
                                <ScheduleIcon className="h-3.5 w-3.5 text-[var(--app-hint)]" />
                            </span>
                        ) : null}
                    </div>
                    <div className={`flex min-w-0 items-center justify-end gap-2 overflow-hidden text-xs ${trailingClassName ?? ''}`}>
                        {todoProgress ? (
                            <span className="flex shrink-0 items-center gap-1 text-[var(--app-hint)]">
                                <BulbIcon className="h-3 w-3" />
                                {todoProgress.completed}/{todoProgress.total}
                            </span>
                        ) : null}
                        {timeLabel ? (
                            <span className={`min-w-0 truncate whitespace-nowrap tabular-nums ${
                                isUnread ? 'font-semibold text-[var(--app-link)]' : 'text-[var(--app-hint)]'
                            }`}>{timeLabel}</span>
                        ) : null}
                    </div>
                </div>
                {contentSnippet ? (
                    <div
                        className="line-clamp-2 text-xs text-[var(--app-fg)]/80"
                        title={contentSearchTruncated
                            ? `${contentSnippet}\n${t('sessions.search.content.truncated')}`
                            : contentSnippet}
                    >
                        {contentSnippet}
                        {contentSearchTruncated ? (
                            <span
                                className="ml-1 inline-flex align-[-2px] text-[var(--app-badge-warning-text)]"
                                title={t('sessions.search.content.truncated')}
                                aria-label={t('sessions.search.content.truncated')}
                            >
                                <InfoIcon className="h-3 w-3" />
                            </span>
                        ) : null}
                    </div>
                ) : null}
                {(secondaryText !== null || parentHintLabel !== null || statusPillNode !== null) ? (
                    <div className="flex min-w-0 items-center justify-between gap-2">
                        <div className="flex min-w-0 flex-1 items-center gap-1.5 overflow-hidden text-xs text-[var(--app-hint)]">
                            {parentHintLabel ? (
                                <span
                                    data-testid="session-parent-hint"
                                    className="inline-flex max-w-[11rem] min-w-0 shrink items-center gap-0.5 truncate text-[var(--app-hint)]"
                                    title={parentHintTooltip}
                                >
                                    <span aria-hidden="true" className="shrink-0 opacity-75">↳</span>
                                    <span className="truncate">{parentHintLabel}</span>
                                </span>
                            ) : null}
                            {parentHintLabel && secondaryText !== null ? (
                                <span aria-hidden="true" className="shrink-0 opacity-60">·</span>
                            ) : null}
                            {secondaryText !== null ? (
                                <span className="min-w-0 flex-1 truncate" title={secondaryTitle}>
                                    {secondaryText}
                                </span>
                            ) : null}
                        </div>
                        {statusPillNode}
                    </div>
                ) : null}
            </div>
        </div>
    )
}
