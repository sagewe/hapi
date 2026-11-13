import { SESSION_LIFECYCLE_IDLE, compareDescWithKeyTiebreak } from '@hapi/protocol'
import type { SessionSummary } from '@/types/api'
import type { SessionListView } from '@/hooks/useSessionListView'
import { createSessionComparator, getSessionSortKey } from '@/lib/sessionListOrder'
import { getSessionProjectLabel, getSessionProjectPath } from '@/lib/sessionProjectLabel'
import { getSessionTitle } from '@/lib/sessionTitle'

export type RunningBucketKey = 'working' | 'pending' | 'active' | 'idle'

export type SessionHierarchyGroup = {
    key: string
    directory: string
    displayName: string
    machineId: string | null
    sessions: SessionSummary[]
    latestOrderAt: number
    hasActiveSession: boolean
    hasPinnedSession: boolean
}

export type SessionTreeConnector = {
    visualDepth: 1 | 2
    continuesAtLevel1: boolean
    isLastChild: boolean
    isDepthCapped: boolean
}

export type SessionRowHierarchyMeta = {
    depth: number
    visualDepth: 0 | 1 | 2
    rootSessionId: string
    connector: SessionTreeConnector | null
    parentHint: string | null
}

type TreeNode = {
    session: SessionSummary
    children: TreeNode[]
    subtreeOrderAt: number
    subtreeHasActive: boolean
}

export type TreeUnit = {
    root: SessionSummary
    nodes: SessionSummary[]
    subtreeOrderAt: number
    subtreeHasActive: boolean
}

const DEFAULT_ORDER: Pick<SessionListView, 'sort' | 'activeFirst'> = {
    sort: 'last-message',
    activeFirst: false
}

const UNKNOWN_MACHINE_KEY = '__unknown__'

export function buildSessionTitleMap(sessions: readonly SessionSummary[]): Map<string, string> {
    const map = new Map<string, string>()
    for (const session of sessions) {
        map.set(session.id, getSessionTitle(session))
    }
    return map
}

export function resolveParentDisplayTitle(
    parentSessionId: string,
    titleById: ReadonlyMap<string, string>
): string {
    const trimmed = parentSessionId.trim()
    return titleById.get(trimmed) ?? trimmed.slice(0, 8)
}

function getRawParentId(session: SessionSummary): string | null {
    const raw = session.metadata?.parentSessionId
    if (typeof raw !== 'string') return null
    const trimmed = raw.trim()
    return trimmed.length > 0 && trimmed !== session.id ? trimmed : null
}

function classifyTreeRunningBucket(nodes: readonly SessionSummary[]): RunningBucketKey | null {
    let hasPending = false
    let hasActiveReady = false
    let hasActiveIdle = false

    for (const session of nodes) {
        if (!session.active) continue
        if (session.thinking || (session.backgroundTaskCount ?? 0) > 0) {
            return 'working'
        }
        if ((session.pendingRequestsCount ?? 0) > 0) {
            hasPending = true
        } else if (session.metadata?.lifecycleState === SESSION_LIFECYCLE_IDLE) {
            hasActiveIdle = true
        } else {
            hasActiveReady = true
        }
    }

    if (hasPending) return 'pending'
    if (hasActiveReady) return 'active'
    if (hasActiveIdle) return 'idle'
    return null
}

function getPinTier(session: SessionSummary): 0 | 1 | 2 {
    if (session.globalPinned) return 2
    if (session.pinned) return 1
    return 0
}

function buildForestUnits(
    pool: readonly SessionSummary[],
    options: {
        order: Pick<SessionListView, 'sort' | 'activeFirst'>
        titleById: ReadonlyMap<string, string>
        metaOut: Map<string, SessionRowHierarchyMeta>
    }
): TreeUnit[] {
    const { order, titleById, metaOut } = options
    const sessionCompare = createSessionComparator(order)
    const byId = new Map<string, SessionSummary>()
    for (const s of pool) {
        byId.set(s.id, s)
    }

    const canAttach = (child: SessionSummary, _parent: SessionSummary): boolean => {
        return getPinTier(child) === 0
    }

    // Resolve cycle-safe in-pool parent for each session in O(N) time with zero recursion.
    const candidateParentById = new Map<string, string>()
    for (const s of pool) {
        const rawParentId = getRawParentId(s)
        if (!rawParentId) continue
        const parent = byId.get(rawParentId)
        if (!parent || !canAttach(s, parent)) continue
        candidateParentById.set(s.id, parent.id)
    }

    const visitState = new Map<string, 1 | 2>()
    const reachesCycle = new Map<string, boolean>()
    for (const s of pool) {
        if (visitState.get(s.id) === 2) continue
        const chain: string[] = []
        let cursor: string | undefined = s.id
        let hitCycle = false
        while (cursor !== undefined) {
            const state = visitState.get(cursor)
            if (state === 1) {
                hitCycle = true
                break
            }
            if (state === 2) {
                hitCycle = reachesCycle.get(cursor) ?? false
                break
            }
            visitState.set(cursor, 1)
            chain.push(cursor)
            cursor = candidateParentById.get(cursor)
        }
        for (const id of chain) {
            visitState.set(id, 2)
            reachesCycle.set(id, hitCycle)
        }
    }

    const resolvedParentById = new Map<string, string>()
    for (const [id, parentId] of candidateParentById) {
        if (!reachesCycle.get(id)) {
            resolvedParentById.set(id, parentId)
        }
    }

    const nodeById = new Map<string, TreeNode>()
    for (const s of pool) {
        nodeById.set(s.id, {
            session: s,
            children: [],
            subtreeOrderAt: getSessionSortKey(s, order.sort),
            subtreeHasActive: s.active
        })
    }

    const roots: TreeNode[] = []
    for (const s of pool) {
        const node = nodeById.get(s.id)!
        const parentId = resolvedParentById.get(s.id)
        if (parentId) {
            nodeById.get(parentId)!.children.push(node)
        } else {
            roots.push(node)
        }
    }

    const compareTreeNodes = (a: TreeNode, b: TreeNode): number => {
        if (order.activeFirst && a.subtreeHasActive !== b.subtreeHasActive) {
            return a.subtreeHasActive ? -1 : 1
        }
        return (b.subtreeOrderAt - a.subtreeOrderAt) || sessionCompare(a.session, b.session)
    }

    const finalizeStack: Array<{ node: TreeNode; expanded: boolean }> = []
    for (let i = roots.length - 1; i >= 0; i -= 1) {
        finalizeStack.push({ node: roots[i]!, expanded: false })
    }
    while (finalizeStack.length > 0) {
        const frame = finalizeStack[finalizeStack.length - 1]!
        if (!frame.expanded) {
            frame.expanded = true
            const children = frame.node.children
            for (let i = children.length - 1; i >= 0; i -= 1) {
                finalizeStack.push({ node: children[i]!, expanded: false })
            }
        } else {
            finalizeStack.pop()
            const node = frame.node
            for (const child of node.children) {
                if (child.subtreeOrderAt > node.subtreeOrderAt) {
                    node.subtreeOrderAt = child.subtreeOrderAt
                }
                if (child.subtreeHasActive) {
                    node.subtreeHasActive = true
                }
            }
            if (node.children.length > 1) {
                node.children.sort(compareTreeNodes)
            }
        }
    }
    roots.sort(compareTreeNodes)

    const units: TreeUnit[] = []
    for (const root of roots) {
        const flatNodes: SessionSummary[] = []
        const rootRawParent = getRawParentId(root.session)
        metaOut.set(root.session.id, {
            depth: 0,
            visualDepth: 0,
            rootSessionId: root.session.id,
            connector: null,
            parentHint: rootRawParent ? resolveParentDisplayTitle(rootRawParent, titleById) : null
        })
        flatNodes.push(root.session)

        if (root.children.length > 0) {
            const walkStack: Array<{
                children: readonly TreeNode[]
                index: number
                depth: number
                directParentId: string
                level1AncestorHasNextSibling: boolean
            }> = [{
                children: root.children,
                index: 0,
                depth: 1,
                directParentId: root.session.id,
                level1AncestorHasNextSibling: false
            }]

            while (walkStack.length > 0) {
                const frame = walkStack[walkStack.length - 1]!
                if (frame.index >= frame.children.length) {
                    walkStack.pop()
                    continue
                }
                const idx = frame.index
                frame.index += 1
                const child = frame.children[idx]!
                const isLastChild = idx === frame.children.length - 1
                const visualDepth: 1 | 2 = frame.depth === 1 ? 1 : 2
                const isDepthCapped = frame.depth >= 3
                const continuesAtLevel1 = frame.depth >= 2 ? frame.level1AncestorHasNextSibling : false

                metaOut.set(child.session.id, {
                    depth: frame.depth,
                    visualDepth,
                    rootSessionId: root.session.id,
                    connector: {
                        visualDepth,
                        continuesAtLevel1,
                        isLastChild: isDepthCapped ? true : isLastChild,
                        isDepthCapped
                    },
                    parentHint: isDepthCapped
                        ? resolveParentDisplayTitle(frame.directParentId, titleById)
                        : null
                })
                flatNodes.push(child.session)

                if (child.children.length > 0) {
                    const nextLevel1HasSibling = frame.depth === 1
                        ? !isLastChild
                        : frame.level1AncestorHasNextSibling
                    walkStack.push({
                        children: child.children,
                        index: 0,
                        depth: frame.depth + 1,
                        directParentId: child.session.id,
                        level1AncestorHasNextSibling: nextLevel1HasSibling
                    })
                }
            }
        }

        units.push({
            root: root.session,
            nodes: flatNodes,
            subtreeOrderAt: root.subtreeOrderAt,
            subtreeHasActive: root.subtreeHasActive
        })
    }

    return units
}

export function buildFlatHierarchyMetadata(
    sessions: readonly SessionSummary[],
    titleById: ReadonlyMap<string, string>
): Map<string, SessionRowHierarchyMeta> {
    const meta = new Map<string, SessionRowHierarchyMeta>()
    for (const s of sessions) {
        const rawParentId = getRawParentId(s)
        meta.set(s.id, {
            depth: 0,
            visualDepth: 0,
            rootSessionId: s.id,
            connector: null,
            parentHint: rawParentId ? resolveParentDisplayTitle(rawParentId, titleById) : null
        })
    }
    return meta
}

export function buildWebDefaultBrowseHierarchy(params: {
    sessions: readonly SessionSummary[]
    allKnownSessions: readonly SessionSummary[]
    pinInProgressSessions: boolean
    order?: Pick<SessionListView, 'sort' | 'activeFirst'>
}): {
    globalPinnedSessions: SessionSummary[]
    runningSessions: Record<RunningBucketKey, SessionSummary[]>
    groups: SessionHierarchyGroup[]
    metaBySessionId: Map<string, SessionRowHierarchyMeta>
    unitsByGroupKey: Map<string, TreeUnit[]>
} {
    const order = params.order ?? DEFAULT_ORDER
    const sessionCompare = createSessionComparator(order)
    const titleById = buildSessionTitleMap(params.allKnownSessions)
    const metaBySessionId = new Map<string, SessionRowHierarchyMeta>()

    const allUnits = buildForestUnits(params.sessions, {
        order,
        titleById,
        metaOut: metaBySessionId
    })

    const compareUnits = (a: TreeUnit, b: TreeUnit): number => {
        if (order.activeFirst && a.subtreeHasActive !== b.subtreeHasActive) {
            return a.subtreeHasActive ? -1 : 1
        }
        return (b.subtreeOrderAt - a.subtreeOrderAt) || sessionCompare(a.root, b.root)
    }

    const globalPinnedUnits: TreeUnit[] = []
    const restUnits: TreeUnit[] = []
    for (const unit of allUnits) {
        if (unit.root.globalPinned) {
            globalPinnedUnits.push(unit)
        } else {
            restUnits.push(unit)
        }
    }
    globalPinnedUnits.sort(compareUnits)
    const globalPinnedSessions = globalPinnedUnits.flatMap((u) => u.nodes)

    const runningUnitBuckets: Record<RunningBucketKey, TreeUnit[]> = {
        working: [],
        pending: [],
        active: [],
        idle: []
    }
    const directoryUnitsMap = new Map<string, {
        directory: string
        machineId: string | null
        units: TreeUnit[]
    }>()

    for (const unit of restUnits) {
        if (!unit.root.pinned && params.pinInProgressSessions) {
            const runningKey = classifyTreeRunningBucket(unit.nodes)
            if (runningKey) {
                runningUnitBuckets[runningKey].push(unit)
                continue
            }
        }

        const directory = getSessionProjectPath(unit.root.metadata) ?? 'Other'
        const machineId = unit.root.metadata?.machineId ?? null
        const key = `${machineId ?? UNKNOWN_MACHINE_KEY}::${directory}`
        let entry = directoryUnitsMap.get(key)
        if (!entry) {
            entry = { directory, machineId, units: [] }
            directoryUnitsMap.set(key, entry)
        }
        entry.units.push(unit)
    }

    const runningSessions: Record<RunningBucketKey, SessionSummary[]> = {
        working: runningUnitBuckets.working.sort(compareUnits).flatMap((u) => u.nodes),
        pending: runningUnitBuckets.pending.sort(compareUnits).flatMap((u) => u.nodes),
        active: runningUnitBuckets.active.sort(compareUnits).flatMap((u) => u.nodes),
        idle: runningUnitBuckets.idle.sort(compareUnits).flatMap((u) => u.nodes)
    }

    const unitsByGroupKey = new Map<string, TreeUnit[]>()
    const groups: SessionHierarchyGroup[] = Array.from(directoryUnitsMap.entries())
        .map(([key, entry]) => {
            const sortedUnits = [...entry.units].sort((a, b) => {
                if (Boolean(a.root.pinned) !== Boolean(b.root.pinned)) {
                    return a.root.pinned ? -1 : 1
                }
                return compareUnits(a, b)
            })
            unitsByGroupKey.set(key, sortedUnits)
            const flatSessions = sortedUnits.flatMap((u) => u.nodes)
            const latestOrderAt = sortedUnits.reduce((max, u) => Math.max(max, u.subtreeOrderAt), -Infinity)
            const hasActiveSession = sortedUnits.some((u) => u.subtreeHasActive)
            const hasPinnedSession = sortedUnits.some((u) => Boolean(u.root.pinned))
            return {
                key,
                directory: entry.directory,
                displayName: getSessionProjectLabel(entry.directory),
                machineId: entry.machineId,
                sessions: flatSessions,
                latestOrderAt,
                hasActiveSession,
                hasPinnedSession
            }
        })
        .sort((a, b) => {
            if (a.hasPinnedSession !== b.hasPinnedSession) {
                return a.hasPinnedSession ? -1 : 1
            }
            if (order.activeFirst && a.hasActiveSession !== b.hasActiveSession) {
                return a.hasActiveSession ? -1 : 1
            }
            return compareDescWithKeyTiebreak(
                { key: a.key, order: a.latestOrderAt },
                { key: b.key, order: b.latestOrderAt }
            )
        })

    return {
        globalPinnedSessions,
        runningSessions,
        groups,
        metaBySessionId,
        unitsByGroupKey
    }
}

export function getVisibleHierarchyUnitsPreview(
    units: readonly TreeUnit[],
    totalSessionsCount: number,
    options: {
        expanded?: boolean
        selectedSessionId?: string | null
        limit: number
        isUnread?: (session: SessionSummary) => boolean
    }
): SessionSummary[] {
    if (options.expanded || totalSessionsCount <= options.limit) {
        return units.flatMap((u) => u.nodes)
    }

    const isUnitRequired = (unit: TreeUnit): boolean => {
        return unit.nodes.some((session) => (
            (session.active && session.pendingRequestsCount > 0)
            || Boolean(options.isUnread?.(session))
            || (options.selectedSessionId != null && session.id === options.selectedSessionId)
        ))
    }

    const kept: TreeUnit[] = []
    let count = 0
    for (const unit of units) {
        const required = isUnitRequired(unit)
        if (count < options.limit || required) {
            kept.push(unit)
            count += unit.nodes.length
        }
    }

    return kept.flatMap((unit) => unit.nodes)
}

export function shouldShowHierarchyPinnedDivider(
    sessions: readonly SessionSummary[],
    index: number,
    metaBySessionId?: ReadonlyMap<string, SessionRowHierarchyMeta>
): boolean {
    if (index <= 0 || index >= sessions.length) return false
    const current = sessions[index]!
    const prev = sessions[index - 1]!
    if (!metaBySessionId) {
        return Boolean(prev.pinned) && !current.pinned
    }
    const currentMeta = metaBySessionId.get(current.id)
    if (currentMeta && currentMeta.depth > 0) {
        return false
    }
    const prevMeta = metaBySessionId.get(prev.id)
    const prevRootId = prevMeta?.rootSessionId ?? prev.id
    const prevRoot = prevRootId === prev.id
        ? prev
        : sessions.find((s) => s.id === prevRootId) ?? prev
    return Boolean(prevRoot.pinned) && !current.pinned
}
