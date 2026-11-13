import { describe, expect, it } from 'bun:test'
import { Hono } from 'hono'
import { formatParentStampBlock, toSessionSummaryMetadata } from '@hapi/protocol'
import { Store } from './index'
import {
    applyHistoricalParentBackfill,
    findHistoricalParentBackfillCandidates,
    parseStrictCanonicalParentStamp
} from './backfillParentSessions'
import { machineSpawnPreallocTag } from './sessions'
import { SessionCache } from '../sync/sessionCache'
import { EventPublisher } from '../sync/eventPublisher'

function makeEventPublisher(): EventPublisher {
    return new EventPublisher({ broadcast: () => {} } as never, () => 'default')
}

function insertUserMessage(store: Store, sessionId: string, text: string, createdAt = 1000, localId?: string): void {
    store.messages.addMessage(
        sessionId,
        {
            role: 'user',
            content: { type: 'text', text }
        },
        localId ?? `msg-${Math.random()}`,
        createdAt
    )
}

describe('parentSessionId write protection & protocol projection', () => {
    it('projects trimmed parentSessionId in toSessionSummaryMetadata', () => {
        const projected = toSessionSummaryMetadata({
            path: '/repo',
            host: 'mac',
            parentSessionId: '  parent-123  '
        })
        expect(projected?.parentSessionId).toBe('parent-123')

        const blank = toSessionSummaryMetadata({
            path: '/repo',
            host: 'mac',
            parentSessionId: '   '
        })
        expect(blank?.parentSessionId).toBeUndefined()
    })

    it('prevents unprivileged updateSessionMetadata and adoptPreallocatedSession from forging, altering, or clearing parentSessionId', () => {
        const store = new Store(':memory:')
        try {
            const parent = store.sessions.getOrCreateSession(
                'parent-tag',
                { path: '/repo', host: 'mac', name: 'Parent' },
                null,
                'default'
            )
            const childId = '22222222-2222-4222-8222-222222222222'
            const stub = store.sessions.getOrCreateSession(
                machineSpawnPreallocTag(childId),
                {
                    path: '/repo',
                    host: 'mac',
                    flavor: 'codex',
                    startedBy: 'runner',
                    startedFromRunner: true,
                    parentSessionId: parent.id
                },
                null,
                'default',
                undefined,
                undefined,
                undefined,
                childId
            )

            // Adopt attempts to spoof a different parentSessionId — must preserve Hub-preallocated parent.id
            const adopted = store.sessions.adoptPreallocatedSession(
                stub.id,
                'live-child-tag',
                { path: '/repo', host: 'mac', flavor: 'codex', parentSessionId: 'spoofed-parent' },
                null,
                'default'
            )
            expect((adopted.metadata as Record<string, unknown>)?.parentSessionId).toBe(parent.id)

            // Sparse CLI metadata replacement omits parentSessionId — must preserve parent.id
            const sparseRes = store.sessions.updateSessionMetadata(
                stub.id,
                { path: '/repo', host: 'mac', lifecycleState: 'archived' },
                adopted.metadataVersion,
                'default'
            )
            expect(sparseRes.result).toBe('success')
            const afterSparse = store.sessions.getSession(stub.id)!
            expect((afterSparse.metadata as Record<string, unknown>)?.parentSessionId).toBe(parent.id)

            // Explicit null or spoofed replacement without allowParentSessionUpdate — must preserve parent.id
            const nullAttempt = store.sessions.updateSessionMetadata(
                stub.id,
                { path: '/repo', host: 'mac', parentSessionId: null },
                afterSparse.metadataVersion,
                'default'
            )
            expect(nullAttempt.result).toBe('success')
            const afterNullAttempt = store.sessions.getSession(stub.id)!
            expect((afterNullAttempt.metadata as Record<string, unknown>)?.parentSessionId).toBe(parent.id)

            // Unparented session cannot acquire parentSessionId via unprivileged updateSessionMetadata
            const standalone = store.sessions.getOrCreateSession(
                'standalone-tag',
                { path: '/repo', host: 'mac' },
                null,
                'default'
            )
            store.sessions.updateSessionMetadata(
                standalone.id,
                { path: '/repo', host: 'mac', parentSessionId: parent.id },
                standalone.metadataVersion,
                'default'
            )
            const afterStandalone = store.sessions.getSession(standalone.id)!
            expect((afterStandalone.metadata as Record<string, unknown>)?.parentSessionId).toBeUndefined()

            // Non-object metadata payloads (null, [], 42) must NEVER wipe parentSessionId on update or adopt
            for (const nonObject of [null, ['unexpected'], 42] as const) {
                const current = store.sessions.getSession(stub.id)!
                const res = store.sessions.updateSessionMetadata(
                    stub.id,
                    nonObject,
                    current.metadataVersion,
                    'default'
                )
                expect(res.result).toBe('success')
                const reloaded = store.sessions.getSession(stub.id)!
                expect((reloaded.metadata as Record<string, unknown>)?.parentSessionId).toBe(parent.id)
                expect((reloaded.metadata as Record<string, unknown>)?.path).toBe('/repo')
            }

            const adoptNullId = '23232323-2323-4323-8323-232323232323'
            store.sessions.getOrCreateSession(
                machineSpawnPreallocTag(adoptNullId),
                { path: '/repo', host: 'mac', flavor: 'codex', parentSessionId: parent.id },
                null,
                'default',
                undefined,
                undefined,
                undefined,
                adoptNullId
            )
            const adoptedWithNull = store.sessions.adoptPreallocatedSession(
                adoptNullId,
                'adopted-null-tag',
                null,
                null,
                'default'
            )
            expect((adoptedWithNull.metadata as Record<string, unknown>)?.parentSessionId).toBe(parent.id)
        } finally {
            store.close()
        }
    })
})

describe('identity merge vs history merge parent lineage', () => {
    it('inherits parent and repoints children on mergeSessions (deleteOldSession: true), but leaves both untouched on mergeSessionHistory', async () => {
        const store = new Store(':memory:')
        try {
            const publisher = makeEventPublisher()
            const cache = new SessionCache(store, publisher)

            const root = cache.getOrCreateSession('root', { path: '/repo', host: 'mac', name: 'Root' }, null, 'default')
            const midOldId = '33333333-3333-4333-8333-333333333333'
            const midOld = cache.getOrCreateSession(
                machineSpawnPreallocTag(midOldId),
                { path: '/repo', host: 'mac', name: 'MidOld', parentSessionId: root.id },
                null,
                'default',
                undefined,
                undefined,
                undefined,
                midOldId
            )
            const leafId = '44444444-4444-4444-8444-444444444444'
            const leaf = cache.getOrCreateSession(
                machineSpawnPreallocTag(leafId),
                { path: '/repo', host: 'mac', name: 'Leaf', parentSessionId: midOld.id },
                null,
                'default',
                undefined,
                undefined,
                undefined,
                leafId
            )

            // Non-destructive history copy must NOT copy parentSessionId or repoint leaf
            const historyCopy = cache.getOrCreateSession('history-copy', { path: '/repo', host: 'mac' }, null, 'default')
            await cache.mergeSessionHistory(midOld.id, historyCopy.id, 'default')
            expect(cache.getSession(historyCopy.id)?.metadata?.parentSessionId).toBeUndefined()
            expect(cache.getSession(leaf.id)?.metadata?.parentSessionId).toBe(midOld.id)

            // Destructive identity consolidation MUST inherit root.id and repoint leaf -> midNew.id
            const midNew = cache.getOrCreateSession('mid-new', { path: '/repo', host: 'mac' }, null, 'default')
            await cache.mergeSessions(midOld.id, midNew.id, 'default')

            expect(cache.getSession(midOld.id)).toBeUndefined()
            expect(cache.getSession(midNew.id)?.metadata?.parentSessionId).toBe(root.id)
            expect(cache.getSession(leaf.id)?.metadata?.parentSessionId).toBe(midNew.id)
            // Preallocated stub tag on leaf must remain intact after internal repoint
            expect(store.sessions.getSession(leaf.id)?.tag).toBe(machineSpawnPreallocTag(leafId))

            // Multi-hop ancestor-into-descendant contraction: root -> ancOld -> midHop -> descNew
            const ancOld = cache.getOrCreateSession(
                machineSpawnPreallocTag('55555555-5555-4555-8555-555555555555'),
                { path: '/repo', host: 'mac', name: 'AncOld', parentSessionId: root.id },
                null,
                'default',
                undefined,
                undefined,
                undefined,
                '55555555-5555-4555-8555-555555555555'
            )
            const midHop = cache.getOrCreateSession(
                machineSpawnPreallocTag('66666666-6666-4666-8666-666666666666'),
                { path: '/repo', host: 'mac', name: 'MidHop', parentSessionId: ancOld.id },
                null,
                'default',
                undefined,
                undefined,
                undefined,
                '66666666-6666-4666-8666-666666666666'
            )
            const descNew = cache.getOrCreateSession(
                machineSpawnPreallocTag('77777777-7777-4777-8777-777777777777'),
                { path: '/repo', host: 'mac', name: 'DescNew', parentSessionId: midHop.id },
                null,
                'default',
                undefined,
                undefined,
                undefined,
                '77777777-7777-4777-8777-777777777777'
            )

            await cache.mergeSessions(ancOld.id, descNew.id, 'default')
            expect(cache.getSession(ancOld.id)).toBeUndefined()
            expect(cache.getSession(descNew.id)?.metadata?.parentSessionId).toBe(root.id)
            expect(cache.getSession(midHop.id)?.metadata?.parentSessionId).toBe(descNew.id)
            expect(store.sessions.wouldCreateParentCycle('default', midHop.id, descNew.id)).toBe(false)
        } finally {
            store.close()
        }
    })
})

describe('strict one-time historical parent backfill', () => {
    it('parses canonical Parent stamp blocks and rejects non-canonical or ambiguous variants', () => {
        const canonical = `${formatParentStampBlock({
            sessionId: 'c9ff2d9a-0e95-48bf-a879-9728df0040c6',
            name: 'Main [Session]',
            agentSessionId: 'agy-1'
        })}\n\nPlease inspect [Other](/sessions/bc492857-4a22-4130-8096-1c7c4c4c82bd).`
        expect(parseStrictCanonicalParentStamp(canonical)).toEqual({
            ok: true,
            parentSessionId: 'c9ff2d9a-0e95-48bf-a879-9728df0040c6'
        })

        // Mid-body Parent block must be rejected
        const midBody = `Intro text first\n\n${canonical}`
        expect(parseStrictCanonicalParentStamp(midBody)).toEqual({
            ok: false,
            reason: 'non_canonical_parent_stamp'
        })

        // Two chips on orchestrator line must be rejected as ambiguous
        const twoChips = [
            '## Parent',
            '- Orchestrator chip (mandatory): [A](/sessions/11111111-1111-4111-8111-111111111111) [B](/sessions/22222222-2222-4222-8222-222222222222)',
            '  Title is decoration and may change mid-flight - address parent by UUID only; never invent nicknames.'
        ].join('\n')
        expect(parseStrictCanonicalParentStamp(twoChips)).toEqual({
            ok: false,
            reason: 'ambiguous_parent_chips'
        })

        // External hub URL chip must be rejected as non-canonical
        const externalUrlStamp = [
            '## Parent',
            '- Orchestrator chip (mandatory): [Remote](https://different-hub.example/sessions/c9ff2d9a-0e95-48bf-a879-9728df0040c6)',
            '  Title is decoration and may change mid-flight - address parent by UUID only; never invent nicknames.'
        ].join('\n')
        expect(parseStrictCanonicalParentStamp(externalUrlStamp)).toEqual({
            ok: false,
            reason: 'non_canonical_parent_stamp'
        })
    })

    it('backfills only strict canonical non-forked children in the same namespace and is idempotent', () => {
        const store = new Store(':memory:')
        try {
            const parent = store.sessions.getOrCreateSession(
                'p-tag',
                { path: '/repo', host: 'mac', name: 'Parent Session' },
                null,
                'default'
            )
            const validChild = store.sessions.getOrCreateSession(
                'c-valid',
                { path: '/repo/sub', host: 'mac', name: 'Valid Child' },
                null,
                'default'
            )
            insertUserMessage(
                store,
                validChild.id,
                `${formatParentStampBlock({ sessionId: parent.id, name: 'Parent Session' })}\n\nReview [Ref](/sessions/99999999-9999-4999-8999-999999999999)`
            )

            // Forked session copying validChild's first message MUST be skipped
            const forkedChild = store.sessions.getOrCreateSession(
                'c-forked',
                { path: '/repo/sub', host: 'mac', name: 'Forked Copy', forkedFrom: validChild.id },
                null,
                'default'
            )
            insertUserMessage(
                store,
                forkedChild.id,
                `${formatParentStampBlock({ sessionId: parent.id, name: 'Parent Session' })}\n\nReview`
            )

            // Cross-namespace child MUST be skipped
            const otherNsChild = store.sessions.getOrCreateSession(
                'c-other-ns',
                { path: '/repo/sub', host: 'mac', name: 'Cross NS' },
                null,
                'other-ns'
            )
            insertUserMessage(
                store,
                otherNsChild.id,
                `${formatParentStampBlock({ sessionId: parent.id, name: 'Parent Session' })}\n\nHello`
            )

            // Mutual cycle between two legacy sessions MUST reject the second edge
            const cycleA = store.sessions.getOrCreateSession(
                'cycle-a',
                { path: '/repo', host: 'mac', name: 'Cycle A' },
                null,
                'default'
            )
            const cycleB = store.sessions.getOrCreateSession(
                'cycle-b',
                { path: '/repo', host: 'mac', name: 'Cycle B' },
                null,
                'default'
            )
            insertUserMessage(store, cycleA.id, `${formatParentStampBlock({ sessionId: cycleB.id })}\n\nWork A`)
            insertUserMessage(store, cycleB.id, `${formatParentStampBlock({ sessionId: cycleA.id })}\n\nWork B`)

            // Session whose VERY FIRST user message has no text (e.g. image-only) followed by a
            // later user message containing a canonical Parent stamp MUST NOT be backfilled.
            const imageFirstSession = store.sessions.getOrCreateSession(
                'c-image-first',
                { path: '/repo/sub', host: 'mac', name: 'Image First' },
                null,
                'default'
            )
            store.messages.addMessage(
                imageFirstSession.id,
                {
                    role: 'user',
                    content: [{ type: 'image', source: { type: 'url', url: 'https://example.com/a.png' } }]
                },
                'msg-img-1',
                900
            )
            insertUserMessage(
                store,
                imageFirstSession.id,
                `${formatParentStampBlock({ sessionId: parent.id, name: 'Parent Session' })}\n\nPasted stamp in 2nd turn`,
                1000,
                'msg-img-2'
            )

            const plan = findHistoricalParentBackfillCandidates((store as unknown as { db: import('bun:sqlite').Database }).db)
            expect(plan.candidates.map((c) => c.childSessionId)).toContain(validChild.id)
            expect(plan.candidates.map((c) => c.childSessionId)).not.toContain(imageFirstSession.id)
            expect(plan.candidates.map((c) => c.childSessionId)).not.toContain(forkedChild.id)
            expect(plan.candidates.map((c) => c.childSessionId)).not.toContain(otherNsChild.id)
            expect(plan.skipped.some((s) => s.sessionId === forkedChild.id && s.reason === 'forked_or_imported_session')).toBe(true)
            expect(plan.skipped.some((s) => s.sessionId === otherNsChild.id && s.reason === 'parent_not_found_in_namespace')).toBe(true)
            expect(plan.skipped.some((s) => s.reason === 'cycle_detected')).toBe(true)

            const beforeUpdatedAt = store.sessions.getSession(validChild.id)!.updatedAt
            const applied = applyHistoricalParentBackfill((store as unknown as { db: import('bun:sqlite').Database }).db)
            expect(applied.appliedSessionIds).toContain(validChild.id)

            const afterChild = store.sessions.getSession(validChild.id)!
            expect((afterChild.metadata as Record<string, unknown>)?.parentSessionId).toBe(parent.id)
            expect(afterChild.updatedAt).toBe(beforeUpdatedAt)

            // Idempotent second run applies nothing
            const secondRun = applyHistoricalParentBackfill((store as unknown as { db: import('bun:sqlite').Database }).db)
            expect(secondRun.appliedSessionIds).toEqual([])
        } finally {
            store.close()
        }
    })
})
