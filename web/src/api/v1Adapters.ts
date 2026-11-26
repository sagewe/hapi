import type {
    AgyModelsResponse,
    AuthResponse,
    DecryptedMessage,
    Machine,
    MessageContextResponse,
    MessagesResponse,
    Session,
    SessionContentMatch,
    SessionContentMatchesResponse,
    SessionContentSearchResponse,
    SessionSummary,
    SpawnResponse,
    SyncEvent
} from '@/types/api'
import type { HubSettingsResponse } from '@hapi/protocol/apiTypes'
import type { ScratchlistAttachmentMetadata, SessionReadState, SessionReadStateRequest } from '@hapi/protocol'

type UnknownRecord = Record<string, unknown>

function isRecord(value: unknown): value is UnknownRecord {
    return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asString(value: unknown): string | undefined {
    return typeof value === 'string' ? value : undefined
}

function asNumber(value: unknown): number | undefined {
    return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function asBoolean(value: unknown): boolean | undefined {
    return typeof value === 'boolean' ? value : undefined
}

/**
 * Build the native Reins v1 PTY WebSocket URL (`/v1/sessions/{id}/terminal?token=...`).
 */
export function buildV1TerminalWsUrl(baseUrl: string, sessionId: string, token: string): string {
    const path = `/v1/sessions/${encodeURIComponent(sessionId)}/terminal?token=${encodeURIComponent(token)}`
    const fallbackOrigin = typeof window !== 'undefined' && window.location?.origin
        ? window.location.origin
        : 'http://localhost'
    let url: URL
    try {
        url = new URL(path, baseUrl || fallbackOrigin)
    } catch {
        url = new URL(path, fallbackOrigin)
    }
    if (url.protocol === 'https:') {
        url.protocol = 'wss:'
    } else if (url.protocol === 'http:') {
        url.protocol = 'ws:'
    }
    return url.toString()
}

export function adaptV1AuthResponse(raw: unknown): AuthResponse {
    if (!isRecord(raw)) {
        return raw as AuthResponse
    }
    const token = asString(raw.token) ?? ''
    if (isRecord(raw.user) && typeof raw.user.id === 'number') {
        return raw as unknown as AuthResponse
    }
    const namespace = asString(raw.namespace) ?? 'default'
    return {
        token,
        user: {
            id: 0,
            username: namespace,
            firstName: namespace
        }
    }
}

export function adaptV1HubSettingsResponse(raw: unknown): HubSettingsResponse {
    if (!isRecord(raw)) {
        return raw as HubSettingsResponse
    }
    if ('sessionSummaryContract' in raw || 'peerSpawnDefaults' in raw) {
        return raw as unknown as HubSettingsResponse
    }
    const peerRaw = isRecord(raw.peer_spawn_defaults) ? raw.peer_spawn_defaults : undefined
    const result: UnknownRecord = {
        sessionSummaryContract: asBoolean(raw.session_summary_contract) ?? false,
        sessionSummaryInChat: asBoolean(raw.session_summary_in_chat) ?? false,
        ...(peerRaw ? {
            peerSpawnDefaults: {
                agent: asString(peerRaw.agent) ?? 'claude',
                model: asString(peerRaw.model) ?? 'sonnet',
                permissionMode: asString(peerRaw.permission_mode) ?? asString(peerRaw.permissionMode) ?? 'yolo'
            }
        } : {}),
        ...(raw.client_profile !== undefined ? { clientProfile: raw.client_profile } : {})
    }
    return result as unknown as HubSettingsResponse
}

export function adaptV1ReadStateRequest(state: SessionReadStateRequest): {
    readRevision?: number
    manualUnread?: boolean
    expectedVersion?: number
} {
    if (state.type === 'read') {
        return {
            readRevision: state.readRevision,
            manualUnread: false,
            expectedVersion: state.expectedVersion
        }
    }
    return {
        manualUnread: true,
        expectedVersion: state.expectedVersion
    }
}

export function adaptV1ReadStateResponse(raw: unknown): { readState: SessionReadState } {
    if (!isRecord(raw)) {
        return raw as { readState: SessionReadState }
    }
    if (isRecord(raw.readState)) {
        return raw as unknown as { readState: SessionReadState }
    }
    return {
        readState: {
            readRevision: asNumber(raw.readRevision ?? raw.read_revision) ?? 0,
            manualUnread: asBoolean(raw.manualUnread ?? raw.manual_unread) ?? false,
            version: asNumber(raw.readStateVersion ?? raw.read_state_version ?? raw.version) ?? 0
        }
    }
}

/**
 * Detect whether a session payload is a Reins Native v1 `Session` (snake_case)
 * rather than an already-adapted HAPI `Session` / `SessionSummary`.
 */
function isV1SessionPayload(raw: UnknownRecord): boolean {
    return (
        'machine_id' in raw
        || 'created_at' in raw
        || 'updated_at' in raw
        || 'meta_rev' in raw
        || 'content_rev' in raw
        || 'pin_mode' in raw
    )
}

export function adaptV1Session(raw: unknown): Session {
    if (!isRecord(raw) || !isV1SessionPayload(raw)) {
        return raw as Session
    }
    const updatedAt = asNumber(raw.updated_at) ?? Date.now()
    const createdAt = asNumber(raw.created_at) ?? updatedAt
    const archived = asBoolean(raw.archived) ?? raw.status === 'archived'
    const thinking = raw.status === 'thinking'
    const title = asString(raw.title) ?? ''
    const machineId = asString(raw.machine_id) ?? ''
    const directory = asString(raw.directory) ?? ''
    const agent = asString(raw.agent) ?? 'claude'
    const pinMode = asString(raw.pin_mode) ?? (raw.pinned ? 'project' : 'none')

    const metadata: UnknownRecord = isRecord(raw.metadata) ? { ...raw.metadata } : {}
    metadata.name = title
    metadata.machineId = machineId
    metadata.path = directory
    if (metadata.host === undefined) metadata.host = 'mac-studio'
    if (metadata.flavor === undefined) metadata.flavor = agent
    if (raw.title_locked !== undefined) metadata.titleLocked = Boolean(raw.title_locked)
    if (asString(raw.prompt_title)) metadata.promptTitle = raw.prompt_title
    if (typeof metadata.summary === 'string') {
        metadata.summary = { text: metadata.summary, updatedAt }
    } else if (isRecord(metadata.summary) && metadata.summary.updatedAt === undefined) {
        metadata.summary = { ...metadata.summary, updatedAt }
    }
    if (archived) {
        metadata.lifecycleState = 'archived'
        if (metadata.archivedBy === undefined) metadata.archivedBy = 'user'
    } else {
        metadata.lifecycleState = 'running'
    }

    const agentState: UnknownRecord = isRecord(raw.pending_requests) ? raw.pending_requests : {}
    const pendingRequestsVec: Array<{ id: string; kind: 'permission' | 'input'; tool: string; since: number }> = []
    const pendingKinds: Array<'permission' | 'input'> = []
    let pendingCount = 0

    if (isRecord(agentState.requests)) {
        const entries = Object.entries(agentState.requests)
        pendingCount = entries.length
        entries.sort(([, a], [, b]) => {
            const aAt = isRecord(a) ? (asNumber(a.createdAt) ?? updatedAt) : updatedAt
            const bAt = isRecord(b) ? (asNumber(b.createdAt) ?? updatedAt) : updatedAt
            return aAt - bAt
        })
        for (const [reqId, entry] of entries.slice(0, 5)) {
            const tool = isRecord(entry) ? (asString(entry.tool) ?? 'Tool') : 'Tool'
            const kind: 'permission' | 'input' = tool === 'AskUserQuestion' ? 'input' : 'permission'
            if (!pendingKinds.includes(kind)) {
                pendingKinds.push(kind)
            }
            const since = isRecord(entry) ? (asNumber(entry.createdAt) ?? updatedAt) : updatedAt
            pendingRequestsVec.push({ id: reqId, kind, tool, since })
        }
    }

    const lastPreview = asString(raw.last_preview)
    const readRev = asNumber(raw.read_rev) ?? 0
    const readStateVer = asNumber(raw.read_state_ver) ?? 0
    const manualUnread = asBoolean(raw.manual_unread) ?? false

    const adapted: UnknownRecord = {
        id: asString(raw.id) ?? '',
        namespace: asString(raw.namespace) ?? 'default',
        seq: asNumber(raw.seq) ?? 0,
        model: asString(raw.model) ?? null,
        effort: asString(raw.effort) ?? null,
        agent,
        permissionMode: asString(raw.permission_mode) ?? null,
        active: !archived,
        activeAt: updatedAt,
        thinking,
        thinkingAt: updatedAt,
        pinned: Boolean(raw.pinned),
        globalPinned: pinMode === 'global',
        pinMode,
        createdAt,
        updatedAt,
        messageCount: asNumber(raw.message_count) ?? 0,
        metadataVersion: asNumber(raw.meta_rev) ?? 0,
        agentStateVersion: asNumber(raw.state_rev) ?? 0,
        todosUpdatedAt: 0,
        pendingRequestsCount: pendingCount,
        pendingRequestKinds: pendingKinds,
        pendingRequests: pendingRequestsVec,
        backgroundTaskCount: 0,
        futureScheduledMessageCount: 0,
        nextScheduledAt: null,
        agentState,
        contentRevision: asNumber(raw.content_rev) ?? 0,
        readRevision: readRev,
        readStateVersion: readStateVer,
        manualUnread,
        readState: {
            readRevision: readRev,
            manualUnread,
            version: readStateVer
        },
        metadata,
        lastMessagePreview: lastPreview ? { text: lastPreview } : undefined
    }

    return adapted as unknown as Session
}

export function adaptV1SessionSummary(raw: unknown): SessionSummary {
    return adaptV1Session(raw) as unknown as SessionSummary
}

export function adaptV1Machine(raw: unknown): Machine {
    if (!isRecord(raw) || !('last_seen_at' in raw)) {
        return raw as Machine
    }
    const lastSeen = asNumber(raw.last_seen_at) ?? Date.now()
    const active = asBoolean(raw.active) ?? false
    const adapted: UnknownRecord = {
        id: asString(raw.id) ?? '',
        namespace: asString(raw.namespace) ?? 'default',
        seq: 1,
        createdAt: lastSeen,
        updatedAt: lastSeen,
        active,
        activeAt: lastSeen,
        metadataVersion: 1,
        runnerStateVersion: 1,
        runnerState: { status: active ? 'running' : 'stopped' },
        metadata: {
            host: asString(raw.name) ?? asString(raw.id) ?? '',
            platform: asString(raw.platform) ?? 'unknown',
            happyCliVersion: '0.34.3',
            capabilities: raw.capabilities ?? {}
        }
    }
    return adapted as unknown as Machine
}

function isV1StoredMessage(raw: UnknownRecord): boolean {
    return Array.isArray(raw.blocks) && typeof raw.role === 'string'
}

export function adaptV1Message(raw: unknown): DecryptedMessage {
    if (!isRecord(raw) || !isV1StoredMessage(raw)) {
        return raw as DecryptedMessage
    }
    const id = asString(raw.id) ?? ''
    const seq = asNumber(raw.seq) ?? 0
    const createdAt = asNumber(raw.created_at) ?? Date.now()
    const invokedAt = asNumber(raw.invoked_at) ?? createdAt
    const localId = asString(raw.local_id) ?? null
    const role = asString(raw.role) ?? 'user'
    const blocks = Array.isArray(raw.blocks) ? raw.blocks : []
    const rawMeta = isRecord(raw.meta) ? { ...raw.meta } : {}

    let content: UnknownRecord
    if (role === 'user') {
        const texts: string[] = []
        const attachments: UnknownRecord[] = []
        for (const blk of blocks) {
            if (!isRecord(blk)) continue
            if (blk.type === 'text' && typeof blk.text === 'string') {
                texts.push(blk.text)
            } else if (blk.type === 'attachment') {
                const filename = asString(blk.filename) ?? 'attachment'
                attachments.push({
                    id: asString(blk.id) ?? '',
                    filename,
                    mimeType: asString(blk.mimeType ?? blk.mime_type) ?? 'application/octet-stream',
                    size: asNumber(blk.size) ?? 0,
                    path: asString(blk.previewUrl ?? blk.preview_url) ?? filename
                })
            }
        }
        const inner: UnknownRecord = { type: 'text', text: texts.join('\n') }
        if (attachments.length > 0) {
            inner.attachments = attachments
        }
        content = { role: 'user', content: inner }
    } else if (role === 'assistant') {
        if (blocks.length === 1 && isRecord(blocks[0]) && blocks[0].type === 'generated_media') {
            const gm = blocks[0]
            content = {
                role: 'agent',
                content: {
                    type: 'codex',
                    data: {
                        type: 'generated-image',
                        id,
                        imageId: asString(gm.id) ?? '',
                        fileName: asString(gm.filename) ?? 'image',
                        mimeType: asString(gm.mime_type ?? gm.mimeType) ?? 'image/png'
                    }
                }
            }
        } else {
            const contentBlocks: UnknownRecord[] = []
            for (const blk of blocks) {
                if (!isRecord(blk)) continue
                if (blk.type === 'text' && typeof blk.text === 'string') {
                    contentBlocks.push({ type: 'text', text: blk.text })
                } else if (blk.type === 'thinking' && typeof blk.thinking === 'string') {
                    contentBlocks.push({ type: 'thinking', thinking: blk.thinking })
                } else if (blk.type === 'tool_use') {
                    contentBlocks.push({
                        type: 'tool_use',
                        id: asString(blk.id) ?? '',
                        name: asString(blk.name) ?? '',
                        input: blk.input ?? {}
                    })
                }
            }
            content = {
                role: 'agent',
                content: {
                    type: 'output',
                    data: {
                        type: 'assistant',
                        message: {
                            role: 'assistant',
                            content: contentBlocks
                        }
                    }
                }
            }
        }
    } else if (role === 'tool') {
        const contentBlocks: UnknownRecord[] = []
        let firstToolName: string | undefined
        let firstReceipt: unknown
        for (const blk of blocks) {
            if (!isRecord(blk) || blk.type !== 'tool_result') continue
            if (firstToolName === undefined && typeof blk.name === 'string') {
                firstToolName = blk.name
            }
            if (firstReceipt === undefined && blk.receipt !== undefined) {
                firstReceipt = blk.receipt
            }
            const obj: UnknownRecord = {
                type: 'tool_result',
                tool_use_id: asString(blk.tool_use_id ?? blk.toolUseId) ?? '',
                content: asString(blk.content) ?? '',
                is_error: Boolean(blk.is_error ?? blk.isError)
            }
            if (blk.receipt !== undefined) {
                obj.tool_receipt = blk.receipt
            }
            contentBlocks.push(obj)
        }
        if (firstToolName && rawMeta.toolName === undefined) {
            rawMeta.toolName = firstToolName
        }
        if (firstReceipt !== undefined && rawMeta.toolReceipt === undefined) {
            rawMeta.toolReceipt = firstReceipt
        }
        content = {
            role: 'agent',
            content: {
                type: 'output',
                data: {
                    type: 'user',
                    message: {
                        role: 'user',
                        content: contentBlocks
                    }
                }
            },
            meta: rawMeta
        }
    } else {
        const text = blocks
            .filter((b): b is UnknownRecord => isRecord(b) && b.type === 'text' && typeof b.text === 'string')
            .map((b) => b.text as string)
            .join('\n')
        content = {
            role: 'system',
            content: { type: 'text', text }
        }
    }

    const adapted: UnknownRecord = {
        id,
        seq,
        localId,
        contentRevision: asNumber(raw.content_rev) ?? 0,
        createdAt,
        invokedAt,
        deliveryState: asString(raw.delivery_state) ?? 'invoked',
        content
    }
    return adapted as unknown as DecryptedMessage
}

function adaptV1Page(page: UnknownRecord): MessagesResponse['page'] {
    return {
        readThroughRevision: asNumber(page.readThroughRevision ?? page.read_through_revision),
        direction: (asString(page.direction) as 'latest' | 'before' | 'after') ?? 'latest',
        limit: asNumber(page.limit) ?? 200,
        epoch: asNumber(page.epoch) ?? 0,
        reset: asBoolean(page.reset) ?? false,
        nextBeforeSeq: asNumber(page.nextBeforeSeq ?? page.next_before_seq) ?? null,
        nextBeforeAt: asNumber(page.nextBeforeAt ?? page.next_before_at) ?? null,
        nextAfterSeq: asNumber(page.nextAfterSeq ?? page.next_after_seq) ?? null,
        nextAfterAt: asNumber(page.nextAfterAt ?? page.next_after_at) ?? null,
        snapshotHeadSeq: asNumber(page.snapshotHeadSeq ?? page.snapshot_head_seq) ?? null,
        snapshotHeadAt: asNumber(page.snapshotHeadAt ?? page.snapshot_head_at) ?? null,
        hasMore: asBoolean(page.hasMore ?? page.has_more) ?? false
    }
}

export function adaptV1MessagesResponse(raw: unknown): MessagesResponse {
    if (!isRecord(raw)) {
        return raw as MessagesResponse
    }
    const messages = Array.isArray(raw.messages) ? raw.messages.map(adaptV1Message) : []
    const page = isRecord(raw.page) ? adaptV1Page(raw.page) : {
        direction: 'latest' as const,
        limit: 200,
        epoch: 0,
        reset: false,
        nextBeforeSeq: null,
        nextBeforeAt: null,
        nextAfterSeq: null,
        nextAfterAt: null,
        snapshotHeadSeq: null,
        snapshotHeadAt: null,
        hasMore: false
    }
    return { messages, page }
}

export function adaptV1MessageContextResponse(raw: unknown): MessageContextResponse | null {
    if (raw === null || raw === undefined) {
        return null
    }
    if (!isRecord(raw)) {
        return raw as MessageContextResponse
    }
    const messages = Array.isArray(raw.messages) ? raw.messages.map(adaptV1Message) : []
    const pageRaw = isRecord(raw.page) ? raw.page : {}
    return {
        messages,
        targetMessageId: asString(raw.targetMessageId ?? raw.target_message_id) ?? '',
        page: {
            epoch: asNumber(pageRaw.epoch) ?? 0,
            nextBeforeSeq: asNumber(pageRaw.nextBeforeSeq ?? pageRaw.next_before_seq) ?? null,
            nextBeforeAt: asNumber(pageRaw.nextBeforeAt ?? pageRaw.next_before_at) ?? null,
            snapshotHeadSeq: asNumber(pageRaw.snapshotHeadSeq ?? pageRaw.snapshot_head_seq) ?? null,
            snapshotHeadAt: asNumber(pageRaw.snapshotHeadAt ?? pageRaw.snapshot_head_at) ?? null,
            hasMore: asBoolean(pageRaw.hasMore ?? pageRaw.has_more) ?? false
        }
    }
}

function adaptV1SearchHit(raw: unknown): SessionContentMatch {
    if (!isRecord(raw)) {
        return raw as SessionContentMatch
    }
    const roleRaw = asString(raw.role)
    const role: 'user' | 'assistant' = roleRaw === 'user' ? 'user' : 'assistant'
    return {
        messageId: asString(raw.messageId ?? raw.message_id) ?? '',
        role,
        seq: asNumber(raw.seq) ?? 0,
        createdAt: asNumber(raw.createdAt ?? raw.created_at) ?? 0,
        snippet: asString(raw.snippet) ?? '',
        truncated: asBoolean(raw.truncated) ?? false
    }
}

export function adaptV1SearchResponse(raw: unknown): SessionContentSearchResponse {
    if (!isRecord(raw)) {
        return raw as SessionContentSearchResponse
    }
    if (Array.isArray(raw.results)) {
        return {
            results: raw.results as SessionContentSearchResponse['results'],
            hasPotentiallyIncompleteResults: asBoolean(
                raw.hasPotentiallyIncompleteResults ?? raw.has_potentially_incomplete_results
            ) ?? false
        }
    }
    const hits = Array.isArray(raw.hits) ? raw.hits : []
    const sessionsMap = isRecord(raw.sessions) ? raw.sessions : {}
    const results: SessionContentSearchResponse['results'] = []
    for (const hit of hits) {
        if (!isRecord(hit)) continue
        const sid = asString(hit.session_id ?? hit.sessionId) ?? ''
        const sessRaw = sessionsMap[sid]
        const session = sessRaw
            ? adaptV1SessionSummary(sessRaw)
            : adaptV1SessionSummary({ id: sid, updated_at: asNumber(hit.created_at) ?? 0 })
        results.push({
            session,
            match: adaptV1SearchHit(hit)
        })
    }
    return {
        results,
        hasPotentiallyIncompleteResults: asBoolean(
            raw.has_potentially_incomplete_results ?? raw.hasPotentiallyIncompleteResults
        ) ?? false
    }
}

export function adaptV1SessionSearchResponse(raw: unknown): SessionContentMatchesResponse {
    if (!isRecord(raw)) {
        return raw as SessionContentMatchesResponse
    }
    if (Array.isArray(raw.matches)) {
        return {
            matches: raw.matches as SessionContentMatch[],
            total: asNumber(raw.total) ?? raw.matches.length,
            hasPotentiallyIncompleteResults: asBoolean(
                raw.hasPotentiallyIncompleteResults ?? raw.has_potentially_incomplete_results
            ) ?? false
        }
    }
    const hits = Array.isArray(raw.hits) ? raw.hits : []
    return {
        matches: hits.map(adaptV1SearchHit),
        total: asNumber(raw.total) ?? hits.length,
        hasPotentiallyIncompleteResults: asBoolean(
            raw.has_potentially_incomplete_results ?? raw.hasPotentiallyIncompleteResults
        ) ?? false
    }
}

export function adaptV1AgyModelsResponse(raw: unknown): AgyModelsResponse {
    if (!isRecord(raw)) {
        return raw as AgyModelsResponse
    }
    if ('availableModels' in raw || 'currentModelId' in raw) {
        return raw as unknown as AgyModelsResponse
    }
    return {
        success: asBoolean(raw.success) ?? false,
        availableModels: Array.isArray(raw.available_models)
            ? raw.available_models as AgyModelsResponse['availableModels']
            : undefined,
        currentModelId: asString(raw.current_model_id) ?? null,
        error: asString(raw.error)
    }
}

export function adaptV1SpawnResponse(raw: unknown): SpawnResponse {
    if (!isRecord(raw)) {
        return raw as SpawnResponse
    }
    if (raw.type === 'success' || raw.type === 'error') {
        return raw as unknown as SpawnResponse
    }
    if (isRecord(raw.session) && typeof raw.session.id === 'string') {
        return { type: 'success', sessionId: raw.session.id }
    }
    return {
        type: 'error',
        message: asString(raw.error) ?? 'Failed to create session'
    }
}

export function adaptV1ScratchlistEntry(raw: unknown): {
    entryId: string
    text: string
    createdAt: number
    updatedAt: number
    attachments: ScratchlistAttachmentMetadata[]
} {
    if (!isRecord(raw)) {
        return raw as {
            entryId: string
            text: string
            createdAt: number
            updatedAt: number
            attachments: ScratchlistAttachmentMetadata[]
        }
    }
    return {
        entryId: asString(raw.entryId ?? raw.id) ?? '',
        text: asString(raw.text) ?? '',
        createdAt: asNumber(raw.createdAt ?? raw.created_at) ?? 0,
        updatedAt: asNumber(raw.updatedAt ?? raw.updated_at) ?? 0,
        attachments: Array.isArray(raw.attachments)
            ? (raw.attachments as ScratchlistAttachmentMetadata[])
            : []
    }
}

/**
 * Normalize Reins Native v1 SSE events (`snake_case` types & fields) into
 * the HAPI `SyncEvent` union expected by `useSSE` and app listeners.
 * Already-normalized HAPI events pass through unchanged.
 */
export function adaptV1SyncEvent(raw: unknown): SyncEvent | null {
    if (!isRecord(raw) || typeof raw.type !== 'string') {
        return null
    }
    switch (raw.type) {
        case 'connection_changed': {
            const data = isRecord(raw.data) ? raw.data : {}
            return {
                type: 'connection-changed',
                data: {
                    status: asString(data.status) ?? 'connected',
                    subscriptionId: asString(data.subscription_id ?? data.subscriptionId),
                    resume: asString(data.resume)
                }
            } as unknown as SyncEvent
        }
        case 'session_added':
        case 'session_updated': {
            const mappedType = raw.type === 'session_added' ? 'session-added' : 'session-updated'
            const sessionRaw = raw.session ?? raw.data
            return {
                type: mappedType,
                namespace: asString(raw.namespace),
                sessionId: asString(raw.session_id ?? raw.sessionId) ?? '',
                data: sessionRaw !== undefined ? adaptV1Session(sessionRaw) : undefined
            } as unknown as SyncEvent
        }
        case 'session_removed': {
            return {
                type: 'session-removed',
                namespace: asString(raw.namespace),
                sessionId: asString(raw.session_id ?? raw.sessionId) ?? ''
            } as unknown as SyncEvent
        }
        case 'session_ended': {
            return {
                type: 'session-ended',
                namespace: asString(raw.namespace),
                sessionId: asString(raw.session_id ?? raw.sessionId) ?? '',
                reason: raw.reason
            } as unknown as SyncEvent
        }
        case 'message_received': {
            return {
                type: 'message-received',
                namespace: asString(raw.namespace),
                sessionId: asString(raw.session_id ?? raw.sessionId) ?? '',
                message: adaptV1Message(raw.message)
            } as unknown as SyncEvent
        }
        case 'machine_updated': {
            const machineRaw = raw.machine
            const updatedAt = asNumber(raw.updated_at) ?? Date.now()
            const data = machineRaw !== undefined && machineRaw !== null
                ? adaptV1Machine(machineRaw)
                : {
                    active: asBoolean(raw.active),
                    activeAt: updatedAt,
                    updatedAt
                }
            return {
                type: 'machine-updated',
                namespace: asString(raw.namespace),
                machineId: asString(raw.machine_id ?? raw.machineId) ?? '',
                data
            } as unknown as SyncEvent
        }
        case 'machine_models_updated': {
            return {
                type: 'machine-agy-models-updated',
                namespace: asString(raw.namespace),
                machineId: asString(raw.machine_id ?? raw.machineId) ?? ''
            } as unknown as SyncEvent
        }
        case 'toast': {
            if (isRecord(raw.data) && 'session_id' in raw.data && !('sessionId' in raw.data)) {
                return {
                    ...raw,
                    data: {
                        ...raw.data,
                        sessionId: raw.data.session_id
                    }
                } as unknown as SyncEvent
            }
            return raw as unknown as SyncEvent
        }
        default:
            return raw as unknown as SyncEvent
    }
}
