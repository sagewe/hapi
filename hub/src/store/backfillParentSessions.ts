import type { Database } from 'bun:sqlite'
import { isObject, unwrapRoleWrappedRecordEnvelope } from '@hapi/protocol'
import { decodeMessageContent } from './contentCodec'
import { getSessions, updateSessionMetadata } from './sessions'
import { isUserInputMessage } from './sessionUserActivity'

export type BackfillCandidate = {
    childSessionId: string
    childTitle: string | null
    parentSessionId: string
    parentTitle: string | null
    namespace: string
    createdAt: number
    firstUserMessageId: string
}

export type BackfillSkippedEntry = {
    sessionId: string
    title: string | null
    namespace: string
    reason:
        | 'invalid_metadata'
        | 'already_has_parent'
        | 'forked_or_imported_session'
        | 'non_canonical_parent_stamp'
        | 'ambiguous_parent_chips'
        | 'self_parent'
        | 'parent_not_found_in_namespace'
        | 'cycle_detected'
    detail?: string
}

export type HistoricalParentBackfillPlan = {
    scannedSessions: number
    candidates: BackfillCandidate[]
    skipped: BackfillSkippedEntry[]
}

export type HistoricalParentBackfillApplyResult = HistoricalParentBackfillPlan & {
    appliedSessionIds: string[]
}

const CANONICAL_PARENT_HEADER = '## Parent'
const CANONICAL_ORCHESTRATOR_PREFIX = '- Orchestrator chip (mandatory): '
const CANONICAL_NOTE_LINE = '  Title is decoration and may change mid-flight - address parent by UUID only; never invent nicknames.'
const CANONICAL_AGENT_ID_LINE_RE = /^- agentSessionId: `[^`\n]+`$/
const EXACT_SINGLE_CHIP_RE = /^\[(?:\\.|[^\\\]])*\]\(\/sessions\/([^/?#)\s]+)\)$/
const SESSION_CHIP_RE = /\[(?:\\.|[^\\\]])*\]\((?:[^)\s]*\/)?sessions\/([^/?#)\s]+)\)/g

function extractRawUserMessageText(decoded: unknown): string | null {
    if (!isUserInputMessage(decoded)) return null
    const record = unwrapRoleWrappedRecordEnvelope(decoded)
    if (!record || record.role !== 'user') return null
    const content = record.content
    if (typeof content === 'string') {
        return content
    }
    const blocks = Array.isArray(content) ? content : [content]
    const parts: string[] = []
    for (const block of blocks) {
        if (isObject(block) && block.type === 'text' && typeof block.text === 'string') {
            parts.push(block.text)
        }
    }
    return parts.length > 0 ? parts.join('\n') : null
}

function resolveSessionDisplayTitle(metadata: Record<string, unknown> | null): string | null {
    if (!metadata) return null
    if (typeof metadata.name === 'string' && metadata.name.trim().length > 0) {
        return metadata.name.trim()
    }
    if (isObject(metadata.summary) && typeof metadata.summary.text === 'string' && metadata.summary.text.trim().length > 0) {
        return metadata.summary.text.trim()
    }
    if (typeof metadata.promptTitle === 'string' && metadata.promptTitle.trim().length > 0) {
        return metadata.promptTitle.trim()
    }
    return null
}

function decodeChipTarget(raw: string): string {
    try {
        return decodeURIComponent(raw).trim()
    } catch {
        return raw.trim()
    }
}

export function parseStrictCanonicalParentStamp(
    rawText: string
): { ok: true; parentSessionId: string } | { ok: false; reason: 'none' | 'non_canonical_parent_stamp' | 'ambiguous_parent_chips' } {
    const normalized = rawText.replace(/\r\n/g, '\n').trimStart()
    if (!normalized) {
        return { ok: false, reason: 'none' }
    }

    const blankLineIndex = normalized.indexOf('\n\n')
    const headerBlock = blankLineIndex >= 0 ? normalized.slice(0, blankLineIndex) : normalized
    const lines = headerBlock.split('\n')

    if (lines[0] !== CANONICAL_PARENT_HEADER) {
        return /^##\s*Parent\b/im.test(normalized)
            ? { ok: false, reason: 'non_canonical_parent_stamp' }
            : { ok: false, reason: 'none' }
    }

    const orchestratorLine = lines[1] ?? ''
    if (!orchestratorLine.startsWith(CANONICAL_ORCHESTRATOR_PREFIX)) {
        return { ok: false, reason: 'non_canonical_parent_stamp' }
    }

    const allHeaderChips: string[] = []
    for (const match of headerBlock.matchAll(SESSION_CHIP_RE)) {
        const raw = match[1]
        if (raw) {
            const decoded = decodeChipTarget(raw)
            if (decoded) allHeaderChips.push(decoded)
        }
    }
    if (allHeaderChips.length > 1) {
        return { ok: false, reason: 'ambiguous_parent_chips' }
    }

    const chipPart = orchestratorLine.slice(CANONICAL_ORCHESTRATOR_PREFIX.length).trim()
    const exactMatch = EXACT_SINGLE_CHIP_RE.exec(chipPart)
    if (!exactMatch || !exactMatch[1]) {
        return { ok: false, reason: 'non_canonical_parent_stamp' }
    }

    if (lines[2] !== CANONICAL_NOTE_LINE) {
        return { ok: false, reason: 'non_canonical_parent_stamp' }
    }

    if (lines.length === 4) {
        if (!CANONICAL_AGENT_ID_LINE_RE.test(lines[3]!)) {
            return { ok: false, reason: 'non_canonical_parent_stamp' }
        }
    } else if (lines.length !== 3) {
        return { ok: false, reason: 'non_canonical_parent_stamp' }
    }

    const parentSessionId = decodeChipTarget(exactMatch[1])
    if (!parentSessionId) {
        return { ok: false, reason: 'non_canonical_parent_stamp' }
    }

    return { ok: true, parentSessionId }
}

function wouldIntroduceCycleInMap(
    parentByChild: ReadonlyMap<string, string>,
    childId: string,
    candidateParentId: string
): boolean {
    if (childId === candidateParentId) return true
    const visited = new Set<string>([childId])
    let cursor: string | undefined = candidateParentId
    while (cursor) {
        if (visited.has(cursor)) return true
        visited.add(cursor)
        cursor = parentByChild.get(cursor)
    }
    return false
}

export function findHistoricalParentBackfillCandidates(db: Database): HistoricalParentBackfillPlan {
    const sessions = getSessions(db).sort((a, b) => (a.createdAt - b.createdAt) || a.id.localeCompare(b.id))
    const sessionById = new Map(sessions.map((session) => [session.id, session]))

    const parentGraphByNamespace = new Map<string, Map<string, string>>()
    for (const session of sessions) {
        const metadata = isObject(session.metadata) ? session.metadata : null
        const existingParent = typeof metadata?.parentSessionId === 'string' && metadata.parentSessionId.trim().length > 0
            ? metadata.parentSessionId.trim()
            : undefined
        if (existingParent) {
            let map = parentGraphByNamespace.get(session.namespace)
            if (!map) {
                map = new Map<string, string>()
                parentGraphByNamespace.set(session.namespace, map)
            }
            map.set(session.id, existingParent)
        }
    }

    const firstUserMsgStmt = db.prepare(`
        SELECT id, content
        FROM messages
        WHERE session_id = ?
        ORDER BY seq ASC, created_at ASC, rowid ASC
    `)

    const candidates: BackfillCandidate[] = []
    const skipped: BackfillSkippedEntry[] = []

    for (const session of sessions) {
        const metadata = isObject(session.metadata) ? session.metadata : null
        const childTitle = resolveSessionDisplayTitle(metadata)
        if (!metadata) {
            skipped.push({
                sessionId: session.id,
                title: childTitle,
                namespace: session.namespace,
                reason: 'invalid_metadata'
            })
            continue
        }

        if (typeof metadata.parentSessionId === 'string' && metadata.parentSessionId.trim().length > 0) {
            skipped.push({
                sessionId: session.id,
                title: childTitle,
                namespace: session.namespace,
                reason: 'already_has_parent',
                detail: metadata.parentSessionId.trim()
            })
            continue
        }

        const hasForkLineage = (typeof metadata.forkedFrom === 'string' && metadata.forkedFrom.trim().length > 0)
            || (typeof metadata.codexSourceSessionId === 'string' && metadata.codexSourceSessionId.trim().length > 0)
            || Boolean(metadata.codexArchivedFork)
        if (hasForkLineage) {
            let firstUserText: string | null = null
            for (const row of firstUserMsgStmt.iterate(session.id) as Iterable<{ id: string; content: string | Uint8Array }>) {
                const decoded = decodeMessageContent(row.content)
                if (!isUserInputMessage(decoded)) {
                    continue
                }
                firstUserText = extractRawUserMessageText(decoded)
                break
            }
            if (firstUserText && /^##\s*Parent\b/im.test(firstUserText)) {
                skipped.push({
                    sessionId: session.id,
                    title: childTitle,
                    namespace: session.namespace,
                    reason: 'forked_or_imported_session'
                })
            }
            continue
        }

        let firstUserMessage: { id: string; text: string } | null = null
        for (const row of firstUserMsgStmt.iterate(session.id) as Iterable<{ id: string; content: string | Uint8Array }>) {
            const decoded = decodeMessageContent(row.content)
            if (!isUserInputMessage(decoded)) {
                continue
            }
            const text = extractRawUserMessageText(decoded)
            if (text !== null) {
                firstUserMessage = { id: row.id, text }
            }
            break
        }
        if (!firstUserMessage) {
            continue
        }

        const parsedStamp = parseStrictCanonicalParentStamp(firstUserMessage.text)
        if (!parsedStamp.ok) {
            if (parsedStamp.reason !== 'none') {
                skipped.push({
                    sessionId: session.id,
                    title: childTitle,
                    namespace: session.namespace,
                    reason: parsedStamp.reason
                })
            }
            continue
        }

        const targetParentId = parsedStamp.parentSessionId
        if (targetParentId === session.id) {
            skipped.push({
                sessionId: session.id,
                title: childTitle,
                namespace: session.namespace,
                reason: 'self_parent'
            })
            continue
        }

        const parentSession = sessionById.get(targetParentId)
        if (!parentSession || parentSession.namespace !== session.namespace) {
            skipped.push({
                sessionId: session.id,
                title: childTitle,
                namespace: session.namespace,
                reason: 'parent_not_found_in_namespace',
                detail: targetParentId
            })
            continue
        }

        let nsGraph = parentGraphByNamespace.get(session.namespace)
        if (!nsGraph) {
            nsGraph = new Map<string, string>()
            parentGraphByNamespace.set(session.namespace, nsGraph)
        }
        if (wouldIntroduceCycleInMap(nsGraph, session.id, targetParentId)) {
            skipped.push({
                sessionId: session.id,
                title: childTitle,
                namespace: session.namespace,
                reason: 'cycle_detected',
                detail: targetParentId
            })
            continue
        }

        nsGraph.set(session.id, targetParentId)
        const parentMetadata = isObject(parentSession.metadata) ? parentSession.metadata : null
        candidates.push({
            childSessionId: session.id,
            childTitle,
            parentSessionId: targetParentId,
            parentTitle: resolveSessionDisplayTitle(parentMetadata),
            namespace: session.namespace,
            createdAt: session.createdAt,
            firstUserMessageId: firstUserMessage.id
        })
    }

    return {
        scannedSessions: sessions.length,
        candidates,
        skipped
    }
}

export function applyHistoricalParentBackfill(db: Database): HistoricalParentBackfillApplyResult {
    return db.transaction((): HistoricalParentBackfillApplyResult => {
        const plan = findHistoricalParentBackfillCandidates(db)
        const appliedSessionIds: string[] = []
        const sessionRows = new Map(getSessions(db).map((s) => [s.id, s]))

        for (const candidate of plan.candidates) {
            const current = sessionRows.get(candidate.childSessionId)
            if (!current || !isObject(current.metadata)) continue
            const result = updateSessionMetadata(
                db,
                candidate.childSessionId,
                {
                    ...current.metadata,
                    parentSessionId: candidate.parentSessionId
                },
                current.metadataVersion,
                candidate.namespace,
                {
                    touchUpdatedAt: false,
                    allowParentSessionUpdate: true
                }
            )
            if (result.result !== 'success') {
                throw new Error(`Failed to apply parentSessionId backfill for session ${candidate.childSessionId}: ${result.result}`)
            }
            appliedSessionIds.push(candidate.childSessionId)
        }

        return {
            ...plan,
            appliedSessionIds
        }
    })()
}
