import { describe, expect, it } from 'vitest'
import type { SessionSummary } from '@/types/api'
import {
    buildFlatHierarchyMetadata,
    buildSessionTitleMap,
    buildWebDefaultBrowseHierarchy,
    getVisibleHierarchyUnitsPreview,
    shouldShowHierarchyPinnedDivider
} from './sessionHierarchy'
import { sameSessionSummaryMetadata } from '@/hooks/useSSE'

function makeSession(overrides: Partial<SessionSummary> & { id: string }): SessionSummary {
    const { id, metadata, ...rest } = overrides
    return {
        id,
        active: false,
        thinking: false,
        activeAt: 1_000,
        createdAt: 1_000,
        updatedAt: 1_000,
        lastUserMessageAt: 1_000,
        pendingRequestsCount: 0,
        futureScheduledMessageCount: 0,
        metadata: {
            path: '/repo/main',
            name: id,
            ...metadata
        },
        ...rest
    } as SessionSummary
}

describe('web sessionHierarchy', () => {
    it('floats an entire parent-child tree unit to Running when a child is working, keeping truthful row states', () => {
        const parent = makeSession({
            id: 'parent-1',
            active: true,
            thinking: false,
            lastUserMessageAt: 2_000,
            metadata: { path: '/repo/main', name: 'Main Orchestrator' }
        })
        const childWorking = makeSession({
            id: 'child-1',
            active: true,
            thinking: true,
            lastUserMessageAt: 5_000,
            metadata: {
                path: '/repo/worktree-1',
                name: 'Codex Reviewer',
                parentSessionId: 'parent-1'
            }
        })

        const result = buildWebDefaultBrowseHierarchy({
            sessions: [parent, childWorking],
            allKnownSessions: [parent, childWorking],
            pinInProgressSessions: true
        })

        expect(result.runningSessions.working.map((s) => s.id)).toEqual(['parent-1', 'child-1'])
        expect(result.runningSessions.active).toEqual([])
        expect(result.groups).toEqual([])

        const parentMeta = result.metaBySessionId.get('parent-1')!
        const childMeta = result.metaBySessionId.get('child-1')!
        expect(parentMeta.visualDepth).toBe(0)
        expect(parentMeta.connector).toBeNull()
        expect(childMeta.visualDepth).toBe(1)
        expect(childMeta.connector).toEqual({
            visualDepth: 1,
            continuesAtLevel1: false,
            isLastChild: true,
            isDepthCapped: false
        })
        expect(childMeta.parentHint).toBeNull()
    })

    it('detaches a globalPinned child into Pinned with parentHint and does not duplicate it under unpinned parent', () => {
        const parent = makeSession({
            id: 'p-1',
            active: true,
            metadata: { path: '/repo/main', name: 'Orchestrator' }
        })
        const pinnedChild = makeSession({
            id: 'c-pinned',
            active: true,
            globalPinned: true,
            metadata: { path: '/repo/main', name: 'Pinned Subsession', parentSessionId: 'p-1' }
        })

        const result = buildWebDefaultBrowseHierarchy({
            sessions: [parent, pinnedChild],
            allKnownSessions: [parent, pinnedChild],
            pinInProgressSessions: true
        })

        expect(result.globalPinnedSessions.map((s) => s.id)).toEqual(['c-pinned'])
        expect(result.runningSessions.active.map((s) => s.id)).toEqual(['p-1'])
        expect(result.metaBySessionId.get('c-pinned')?.parentHint).toBe('Orchestrator')
        expect(result.metaBySessionId.get('c-pinned')?.connector).toBeNull()
    })

    it('detaches a project-pinned child from an unpinned directory parent and preserves divider boundaries', () => {
        const parent = makeSession({
            id: 'p-dir',
            pinned: false,
            lastUserMessageAt: 3_000,
            metadata: { path: '/repo/main', name: 'Dir Parent' }
        })
        const projectPinnedChild = makeSession({
            id: 'c-dir-pinned',
            pinned: true,
            lastUserMessageAt: 1_500,
            metadata: { path: '/repo/main', name: 'Dir Pinned Child', parentSessionId: 'p-dir' }
        })

        const result = buildWebDefaultBrowseHierarchy({
            sessions: [parent, projectPinnedChild],
            allKnownSessions: [parent, projectPinnedChild],
            pinInProgressSessions: false
        })

        expect(result.groups).toHaveLength(1)
        expect(result.groups[0]!.sessions.map((s) => s.id)).toEqual(['c-dir-pinned', 'p-dir'])
        expect(result.metaBySessionId.get('c-dir-pinned')?.parentHint).toBe('Dir Parent')
        expect(shouldShowHierarchyPinnedDivider(result.groups[0]!.sessions, 1, result.metaBySessionId)).toBe(true)
    })

    it('caps visual indentation at depth 2 and emits direct parentHint + capped corner for depth >= 3', () => {
        const d0 = makeSession({ id: 'd0', metadata: { path: '/repo', name: 'Root' } })
        const d1 = makeSession({ id: 'd1', metadata: { path: '/repo', name: 'Child L1', parentSessionId: 'd0' } })
        const d2 = makeSession({ id: 'd2', metadata: { path: '/repo', name: 'Child L2', parentSessionId: 'd1' } })
        const d3 = makeSession({ id: 'd3', metadata: { path: '/repo', name: 'Child L3', parentSessionId: 'd2' } })

        const result = buildWebDefaultBrowseHierarchy({
            sessions: [d0, d1, d2, d3],
            allKnownSessions: [d0, d1, d2, d3],
            pinInProgressSessions: false
        })

        expect(result.groups[0]!.sessions.map((s) => s.id)).toEqual(['d0', 'd1', 'd2', 'd3'])
        expect(result.metaBySessionId.get('d2')?.visualDepth).toBe(2)
        expect(result.metaBySessionId.get('d2')?.parentHint).toBeNull()
        expect(result.metaBySessionId.get('d3')?.visualDepth).toBe(2)
        expect(result.metaBySessionId.get('d3')?.connector?.isDepthCapped).toBe(true)
        expect(result.metaBySessionId.get('d3')?.parentHint).toBe('Child L2')
    })

    it('resolves orphan parentHint from allKnownSessions when parent is archived and guards cycles', () => {
        const archivedParent = makeSession({
            id: 'archived-p',
            metadata: { path: '/repo', name: 'Archived Orchestrator', lifecycleState: 'archived' }
        })
        const activeChild = makeSession({
            id: 'active-c',
            active: true,
            metadata: { path: '/repo', name: 'Live Subsession', parentSessionId: 'archived-p' }
        })
        const cycle1 = makeSession({
            id: 'cyc-1',
            metadata: { path: '/repo', name: 'Cycle 1', parentSessionId: 'cyc-2' }
        })
        const cycle2 = makeSession({
            id: 'cyc-2',
            metadata: { path: '/repo', name: 'Cycle 2', parentSessionId: 'cyc-1' }
        })

        const result = buildWebDefaultBrowseHierarchy({
            sessions: [activeChild, cycle1, cycle2],
            allKnownSessions: [archivedParent, activeChild, cycle1, cycle2],
            pinInProgressSessions: true
        })

        expect(result.metaBySessionId.get('active-c')?.parentHint).toBe('Archived Orchestrator')
        expect(result.groups[0]!.sessions.map((s) => s.id)).toContain('cyc-1')
        expect(result.groups[0]!.sessions.map((s) => s.id)).toContain('cyc-2')

        const flatMeta = buildFlatHierarchyMetadata([activeChild], buildSessionTitleMap([archivedParent, activeChild]))
        expect(flatMeta.get('active-c')?.parentHint).toBe('Archived Orchestrator')
    })

    it('keeps whole tree units intact in getVisibleHierarchyUnitsPreview and detects parentSessionId changes in SSE', () => {
        const r1 = makeSession({ id: 'r1', lastUserMessageAt: 5_000 })
        const r1c = makeSession({ id: 'r1c', lastUserMessageAt: 4_000, metadata: { path: '/repo/main', parentSessionId: 'r1' } })
        const r2 = makeSession({ id: 'r2', lastUserMessageAt: 3_000 })
        const r3 = makeSession({ id: 'r3', lastUserMessageAt: 2_000 })

        const built = buildWebDefaultBrowseHierarchy({
            sessions: [r1, r1c, r2, r3],
            allKnownSessions: [r1, r1c, r2, r3],
            pinInProgressSessions: false
        })
        const units = built.unitsByGroupKey.get(built.groups[0]!.key)!
        const preview = getVisibleHierarchyUnitsPreview(units, 4, { limit: 1 })
        // Even with limit=1, r1 and r1c stay together as one unit
        expect(preview.map((s) => s.id)).toEqual(['r1', 'r1c'])

        expect(
            sameSessionSummaryMetadata(
                { path: '/repo', parentSessionId: 'p1' },
                { path: '/repo', parentSessionId: 'p2' }
            )
        ).toBe(false)
    })

    it('keeps unpinned children under a globalPinned parent and carries unpinned grandchildren with a globalPinned child', () => {
        const gpParent = makeSession({
            id: 'gp-parent',
            globalPinned: true,
            lastUserMessageAt: 2_000,
            metadata: { path: '/repo/a', name: 'Global Pinned Orchestrator' }
        })
        const gpParentChild = makeSession({
            id: 'gp-parent-child',
            globalPinned: false,
            lastUserMessageAt: 5_000,
            metadata: { path: '/repo/a', name: 'Unpinned Child Of GP', parentSessionId: 'gp-parent' }
        })
        const unpinnedRoot = makeSession({
            id: 'unpinned-root',
            lastUserMessageAt: 1_000,
            metadata: { path: '/repo/b', name: 'Unpinned Orchestrator' }
        })
        const gpChild = makeSession({
            id: 'gp-child',
            globalPinned: true,
            lastUserMessageAt: 3_000,
            metadata: { path: '/repo/b', name: 'Globally Pinned Child', parentSessionId: 'unpinned-root' }
        })
        const gpGrandchild = makeSession({
            id: 'gp-grandchild',
            globalPinned: false,
            lastUserMessageAt: 6_000,
            metadata: { path: '/repo/b', name: 'Unpinned Grandchild', parentSessionId: 'gp-child' }
        })

        const built = buildWebDefaultBrowseHierarchy({
            sessions: [gpParent, gpParentChild, unpinnedRoot, gpChild, gpGrandchild],
            allKnownSessions: [gpParent, gpParentChild, unpinnedRoot, gpChild, gpGrandchild],
            pinInProgressSessions: true
        })

        // gp-child subtreeOrderAt is 6_000 > gp-parent subtreeOrderAt 5_000
        expect(built.globalPinnedSessions.map((s) => s.id)).toEqual([
            'gp-child',
            'gp-grandchild',
            'gp-parent',
            'gp-parent-child'
        ])
        expect(built.metaBySessionId.get('gp-child')?.parentHint).toBe('Unpinned Orchestrator')
        expect(built.metaBySessionId.get('gp-grandchild')?.visualDepth).toBe(1)
        expect(built.metaBySessionId.get('gp-parent-child')?.visualDepth).toBe(1)
        expect(built.groups.map((g) => g.sessions.map((s) => s.id))).toEqual([['unpinned-root']])
    })

    it('detaches explicitly pinned children even when their parent is also pinned or globalPinned', () => {
        const pinnedParentA = makeSession({
            id: 'pinned-parent-a',
            pinned: true,
            lastUserMessageAt: 2_000,
            metadata: { path: '/repo/a', name: 'Pinned Parent A' }
        })
        const pinnedChildB = makeSession({
            id: 'pinned-child-b',
            pinned: true,
            lastUserMessageAt: 4_000,
            metadata: { path: '/repo/b', name: 'Pinned Child B', parentSessionId: 'pinned-parent-a' }
        })
        const gpParent = makeSession({
            id: 'gp-parent-2',
            globalPinned: true,
            lastUserMessageAt: 5_000,
            metadata: { path: '/repo/a', name: 'Global Parent' }
        })
        const projectPinnedChildOfGp = makeSession({
            id: 'proj-pinned-child',
            pinned: true,
            lastUserMessageAt: 3_000,
            metadata: { path: '/repo/b', name: 'Project Pinned Child', parentSessionId: 'gp-parent-2' }
        })

        const built = buildWebDefaultBrowseHierarchy({
            sessions: [pinnedParentA, pinnedChildB, gpParent, projectPinnedChildOfGp],
            allKnownSessions: [pinnedParentA, pinnedChildB, gpParent, projectPinnedChildOfGp],
            pinInProgressSessions: false
        })

        // Global pinned only contains gpParent; projectPinnedChildOfGp detached into /repo/b!
        expect(built.globalPinnedSessions.map((s) => s.id)).toEqual(['gp-parent-2'])
        const groupA = built.groups.find((g) => g.directory === '/repo/a')!
        const groupB = built.groups.find((g) => g.directory === '/repo/b')!
        expect(groupA.sessions.map((s) => s.id)).toEqual(['pinned-parent-a'])
        expect(groupB.sessions.map((s) => s.id)).toEqual(['pinned-child-b', 'proj-pinned-child'])
        expect(built.metaBySessionId.get('pinned-child-b')?.parentHint).toBe('Pinned Parent A')
        expect(built.metaBySessionId.get('proj-pinned-child')?.parentHint).toBe('Global Parent')
    })

    it('treats preview limit as a soft unit budget (3+3 with limit=5 keeps 6) and handles 5000-deep chains iteratively', () => {
        const u1r = makeSession({ id: 'u1r', lastUserMessageAt: 9_000 })
        const u1c1 = makeSession({ id: 'u1c1', lastUserMessageAt: 8_900, metadata: { path: '/repo/main', parentSessionId: 'u1r' } })
        const u1c2 = makeSession({ id: 'u1c2', lastUserMessageAt: 8_800, metadata: { path: '/repo/main', parentSessionId: 'u1r' } })
        const u2r = makeSession({ id: 'u2r', lastUserMessageAt: 7_000 })
        const u2c1 = makeSession({ id: 'u2c1', lastUserMessageAt: 6_900, metadata: { path: '/repo/main', parentSessionId: 'u2r' } })
        const u2c2 = makeSession({ id: 'u2c2', lastUserMessageAt: 6_800, metadata: { path: '/repo/main', parentSessionId: 'u2r' } })
        const u3r = makeSession({ id: 'u3r', lastUserMessageAt: 5_000 })
        const u3c1 = makeSession({ id: 'u3c1', lastUserMessageAt: 4_900, metadata: { path: '/repo/main', parentSessionId: 'u3r' } })
        const u3c2 = makeSession({ id: 'u3c2', lastUserMessageAt: 4_800, metadata: { path: '/repo/main', parentSessionId: 'u3r' } })
        const nine = [u1r, u1c1, u1c2, u2r, u2c1, u2c2, u3r, u3c1, u3c2]

        const builtNine = buildWebDefaultBrowseHierarchy({
            sessions: nine,
            allKnownSessions: nine,
            pinInProgressSessions: false
        })
        const units = builtNine.unitsByGroupKey.get(builtNine.groups[0]!.key)!
        const softPreview = getVisibleHierarchyUnitsPreview(units, 9, { limit: 5 })
        expect(softPreview.map((s) => s.id)).toEqual(['u1r', 'u1c1', 'u1c2', 'u2r', 'u2c1', 'u2c2'])

        // 5,000-deep chain must complete fast with zero call-stack overflow
        const deepChain = Array.from({ length: 5_000 }, (_, i) =>
            makeSession({
                id: `deep-${i}`,
                lastUserMessageAt: i + 1,
                metadata: {
                    path: '/repo/deep',
                    name: `Node ${i}`,
                    ...(i > 0 ? { parentSessionId: `deep-${i - 1}` } : {})
                }
            })
        )
        const deepBuilt = buildWebDefaultBrowseHierarchy({
            sessions: deepChain,
            allKnownSessions: deepChain,
            pinInProgressSessions: false
        })
        expect(deepBuilt.groups).toHaveLength(1)
        expect(deepBuilt.groups[0]!.sessions).toHaveLength(5_000)
        expect(deepBuilt.metaBySessionId.get('deep-4999')?.visualDepth).toBe(2)
        expect(deepBuilt.metaBySessionId.get('deep-4999')?.parentHint).toBe('Node 4998')
    })
})
