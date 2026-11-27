import { describe, expect, it } from 'vitest'
import { hasActiveSteeringTurn } from '@hapi/protocol'
import { MachineSchema, SessionSchema } from '@hapi/protocol/schemas'
import { normalizeDecryptedMessage } from '@/chat/normalize'
import { reduceChatBlocks } from '@/chat/reducer'
import { isQueuedForInvocation } from '@/lib/messages'
import {
    adaptV1AgyModelsResponse,
    adaptV1AuthResponse,
    adaptV1CancelMessageResponse,
    adaptV1HubSettingsResponse,
    adaptV1Machine,
    adaptV1Message,
    adaptV1MessagesResponse,
    adaptV1QueuedStateResponse,
    adaptV1ReadStateRequest,
    adaptV1ReadStateResponse,
    adaptV1RetryIndeterminateMessageResponse,
    adaptV1ScratchlistEntry,
    adaptV1SearchResponse,
    adaptV1Session,
    adaptV1SessionSearchResponse,
    adaptV1SpawnResponse,
    adaptV1SteerQueuedMessageResponse,
    adaptV1SyncEvent,
    buildV1SessionStreamUrl,
    buildV1TerminalWsUrl
} from './v1Adapters'

describe('v1Adapters', () => {
    it('builds wss/ws native v1 terminal URLs', () => {
        expect(buildV1TerminalWsUrl('https://reins.example.test', 'sess/1', 'jwt tok')).toBe(
            'wss://reins.example.test/v1/sessions/sess%2F1/terminal?token=jwt%20tok'
        )
        expect(buildV1TerminalWsUrl('http://127.0.0.1:3016', 'sess-1', 'abc')).toBe(
            'ws://127.0.0.1:3016/v1/sessions/sess-1/terminal?token=abc'
        )
    })

    it('adapts v1 auth login response', () => {
        expect(adaptV1AuthResponse({ token: 'jwt-1', namespace: 'default', is_owner: true })).toEqual({
            token: 'jwt-1',
            user: { id: 0, username: 'default', firstName: 'default' }
        })
    })

    it('adapts v1 settings response', () => {
        expect(adaptV1HubSettingsResponse({
            session_summary_contract: false,
            session_summary_in_chat: true,
            peer_spawn_defaults: { agent: 'claude', model: 'sonnet', permission_mode: 'yolo' }
        })).toEqual({
            sessionSummaryContract: false,
            sessionSummaryInChat: true,
            peerSpawnDefaults: { agent: 'claude', model: 'sonnet', permissionMode: 'yolo' }
        })
    })

    it('adapts read-state request and response', () => {
        expect(adaptV1ReadStateRequest({ type: 'read', readRevision: 7, expectedVersion: 2 })).toEqual({
            readRevision: 7,
            manualUnread: false,
            expectedVersion: 2
        })
        expect(adaptV1ReadStateRequest({ type: 'unread', expectedVersion: 2 })).toEqual({
            manualUnread: true,
            expectedVersion: 2
        })
        expect(adaptV1ReadStateResponse({
            contentRevision: 10,
            readRevision: 7,
            readStateVersion: 3,
            manualUnread: false
        })).toEqual({
            readState: { readRevision: 7, manualUnread: false, version: 3 }
        })
    })

    it('adapts v1 Session to HAPI Session', () => {
        const adapted = adaptV1Session({
            id: 'sess-1',
            namespace: 'default',
            machine_id: 'mac-1',
            agent: 'codex',
            directory: '/tmp/repo',
            title: 'Network debug',
            title_locked: true,
            prompt_title: null,
            model: 'gpt-6',
            effort: 'high',
            permission_mode: 'yolo',
            status: 'thinking',
            pinned: true,
            pin_mode: 'global',
            archived: false,
            meta_rev: 2,
            state_rev: 3,
            message_epoch: 1,
            content_rev: 5,
            read_rev: 4,
            read_state_ver: 2,
            manual_unread: false,
            pending_requests: {},
            metadata: {},
            created_at: 1000,
            updated_at: 2000,
            seq: 9,
            message_count: 4,
            last_preview: 'ok'
        })
        expect(adapted.id).toBe('sess-1')
        expect(adapted.active).toBe(true)
        expect(adapted.thinking).toBe(true)
        expect(adapted.metadata?.name).toBe('Network debug')
        expect(adapted.metadata?.path).toBe('/tmp/repo')
        expect(adapted.metadata?.machineId).toBe('mac-1')
        expect(adapted.readState).toEqual({ readRevision: 4, manualUnread: false, version: 2 })
    })

    it('adapts v1 Machine to HAPI Machine', () => {
        const machine = adaptV1Machine({
            id: 'mac-1',
            namespace: 'default',
            name: 'Mac Studio',
            platform: 'darwin',
            capabilities: {},
            active: true,
            last_seen_at: 5000
        })
        expect(machine.id).toBe('mac-1')
        expect(machine.active).toBe(true)
        expect(machine.metadata?.host).toBe('Mac Studio')
    })

    it('adapts v1 StoredMessage and MessagesResponse', () => {
        const resp = adaptV1MessagesResponse({
            messages: [
                {
                    id: 'm1',
                    session_id: 's1',
                    seq: 1,
                    local_id: 'loc-1',
                    role: 'user',
                    content_rev: 1,
                    invoked_at: 100,
                    delivery_state: 'invoked',
                    blocks: [{ type: 'text', text: 'hello' }],
                    meta: {},
                    created_at: 100
                }
            ],
            page: {
                read_through_revision: 1,
                direction: 'latest',
                limit: 50,
                epoch: 0,
                reset: false,
                next_before_seq: null,
                next_before_at: null,
                next_after_seq: 1,
                next_after_at: 100,
                snapshot_head_seq: 1,
                snapshot_head_at: 100,
                has_more: false
            }
        })
        expect(resp.messages).toHaveLength(1)
        expect(resp.messages[0]?.localId).toBe('loc-1')
        expect(resp.page.readThroughRevision).toBe(1)
        expect(resp.page.hasMore).toBe(false)

        const gm = adaptV1Message({
            id: 'm2',
            session_id: 's1',
            seq: 2,
            local_id: null,
            role: 'assistant',
            content_rev: 2,
            invoked_at: 200,
            delivery_state: 'invoked',
            blocks: [{ type: 'generated_media', id: 'img_1', filename: 'chart.png', mime_type: 'image/png' }],
            meta: {},
            created_at: 200
        })
        expect((gm.content as { content?: { data?: { imageId?: string } } }).content?.data?.imageId).toBe('img_1')
    })

    it('adapts v1 search, agy-models, spawn, scratchlist, and SSE events', () => {
        const srch = adaptV1SearchResponse({
            hits: [{ message_id: 'm1', session_id: 's1', seq: 1, role: 'user', snippet: 'hi', created_at: 10 }],
            sessions: { s1: { id: 's1', title: 'S1', machine_id: 'm', directory: '/', agent: 'codex', updated_at: 20, created_at: 10, archived: false, status: 'idle', metadata: {}, pending_requests: {}, pinned: false, pin_mode: 'none', meta_rev: 1, state_rev: 1, content_rev: 1, read_rev: 0, read_state_ver: 0, manual_unread: false, seq: 1 } },
            has_potentially_incomplete_results: false
        })
        expect(srch.results).toHaveLength(1)
        expect(srch.results[0]?.match.messageId).toBe('m1')

        const sessSrch = adaptV1SessionSearchResponse({
            hits: [{ message_id: 'm1', session_id: 's1', seq: 1, role: 'assistant', snippet: 'ok', created_at: 10 }],
            total: 1,
            has_potentially_incomplete_results: false
        })
        expect(sessSrch.matches[0]?.messageId).toBe('m1')

        expect(adaptV1AgyModelsResponse({
            success: true,
            available_models: [{ modelId: 'm1', name: 'M1' }],
            current_model_id: 'm1'
        })).toEqual({
            success: true,
            availableModels: [{ modelId: 'm1', name: 'M1' }],
            currentModelId: 'm1',
            error: undefined
        })

        expect(adaptV1SpawnResponse({ session: { id: 'sess-new' } })).toEqual({
            type: 'success',
            sessionId: 'sess-new'
        })

        expect(adaptV1ScratchlistEntry({ id: 'e1', text: 'note', createdAt: 1, updatedAt: 2, attachments: [] })).toEqual({
            entryId: 'e1',
            text: 'note',
            createdAt: 1,
            updatedAt: 2,
            attachments: []
        })

        const connEv = adaptV1SyncEvent({
            type: 'connection_changed',
            data: { status: 'connected', subscription_id: 'sub-1', resume: 'ok' }
        })
        expect(connEv).toEqual({
            type: 'connection-changed',
            data: { status: 'connected', subscriptionId: 'sub-1', resume: 'ok' }
        })

        const remEv = adaptV1SyncEvent({ type: 'session_removed', namespace: 'default', session_id: 's1' })
        expect(remEv).toEqual({ type: 'session-removed', namespace: 'default', sessionId: 's1' })
    })

    it('passes SessionSchema and MachineSchema strict validation for nullable/object v1 fields', () => {
        const session = adaptV1Session({
            id: 'sess-null-pm',
            namespace: 'default',
            machine_id: 'mac-1',
            agent: 'codex',
            directory: '/tmp/repo',
            title: 'Title',
            title_locked: false,
            prompt_title: null,
            model: '',
            effort: 'high',
            permission_mode: null,
            status: 'idle',
            pinned: false,
            pin_mode: 'none',
            archived: false,
            meta_rev: 1,
            state_rev: 1,
            message_epoch: 0,
            content_rev: 1,
            read_rev: 0,
            read_state_ver: 0,
            manual_unread: false,
            pending_requests: {},
            metadata: {},
            created_at: 1000,
            updated_at: 2000,
            seq: 1
        })
        expect(session.permissionMode).toBeUndefined()
        expect(session.model).toBeNull()
        expect(session.modelReasoningEffort).toBe('high')
        expect(SessionSchema.safeParse(session).success).toBe(true)

        const machine = adaptV1Machine({
            id: 'mac-obj-caps',
            namespace: 'default',
            name: 'Mac Studio',
            platform: 'darwin',
            capabilities: { pty: true },
            active: true,
            last_seen_at: 5000
        })
        expect(machine.metadata?.capabilities).toBeUndefined()
        expect(MachineSchema.safeParse(machine).success).toBe(true)
    })

    it('maps deliveryState/deliveryPending and multi-block generated_media accurately', () => {
        const invoked = adaptV1Message({
            id: 'm-invoked',
            session_id: 's1',
            seq: 1,
            local_id: null,
            role: 'user',
            content_rev: 1,
            invoked_at: 100,
            delivery_state: 'invoked',
            blocks: [{ type: 'text', text: 'hi' }],
            meta: {},
            created_at: 100
        })
        expect(invoked.deliveryState).toBeUndefined()
        expect((invoked as { deliveryPending?: boolean }).deliveryPending).toBeUndefined()

        const dispatching = adaptV1Message({
            id: 'm-disp',
            session_id: 's1',
            seq: 2,
            local_id: 'l-1',
            role: 'user',
            content_rev: 2,
            invoked_at: null,
            delivery_state: 'dispatching',
            blocks: [{ type: 'text', text: 'hi' }],
            meta: {},
            created_at: 100
        })
        expect(dispatching.deliveryState).toBeUndefined()
        expect((dispatching as { deliveryPending?: boolean }).deliveryPending).toBe(true)

        const indet = adaptV1Message({
            id: 'm-indet',
            session_id: 's1',
            seq: 3,
            local_id: 'l-2',
            role: 'user',
            content_rev: 3,
            invoked_at: null,
            delivery_state: 'indeterminate',
            blocks: [{ type: 'text', text: 'hi' }],
            meta: {},
            created_at: 100
        })
        expect(indet.deliveryState).toBe('indeterminate')

        const multi = adaptV1Message({
            id: 'm-multi',
            session_id: 's1',
            seq: 4,
            local_id: null,
            role: 'assistant',
            content_rev: 4,
            invoked_at: 200,
            delivery_state: 'invoked',
            blocks: [
                { type: 'text', text: 'Here is the chart:' },
                { type: 'generated_media', id: 'img_2', filename: 'plot.png', mime_type: 'image/png' }
            ],
            meta: {},
            created_at: 200
        })
        const contentBlocks = (multi.content as { content?: { data?: { message?: { content?: Array<Record<string, unknown>> } } } }).content?.data?.message?.content ?? []
        expect(contentBlocks).toHaveLength(2)
        expect(contentBlocks[1]).toMatchObject({ type: 'generated_media', imageId: 'img_2', fileName: 'plot.png' })
    })

    it('always populates peerSpawnDefaults in adaptV1HubSettingsResponse', () => {
        expect(adaptV1HubSettingsResponse({ ok: true })).toEqual({
            sessionSummaryContract: false,
            sessionSummaryInChat: false,
            peerSpawnDefaults: { agent: 'claude', model: 'sonnet', permissionMode: 'yolo' }
        })
    })

    it('builds native v1 session stream URLs', () => {
        expect(buildV1SessionStreamUrl('https://reins.example.test', 'sess/1', 'jwt tok')).toBe(
            'https://reins.example.test/v1/sessions/sess%2F1/stream?token=jwt+tok'
        )
        expect(buildV1SessionStreamUrl('', 'sess-1', 'abc')).toBe(
            '/v1/sessions/sess-1/stream?token=abc'
        )
    })

    it('projects AGY steering gate fields (agySessionProtocol + steeringActive) cleanly', () => {
        const session = adaptV1Session({
            id: 'sess-agy',
            namespace: 'default',
            machine_id: 'mac-1',
            agent: 'agy',
            directory: '/tmp/repo',
            title: 'AGY ACP',
            title_locked: false,
            prompt_title: null,
            model: 'gemini-3.8-pro',
            effort: 'high',
            permission_mode: 'default',
            status: 'thinking',
            pinned: false,
            pin_mode: 'none',
            archived: false,
            meta_rev: 2,
            state_rev: 2,
            message_epoch: 0,
            content_rev: 2,
            read_rev: 1,
            read_state_ver: 1,
            manual_unread: false,
            pending_requests: { steeringActive: true },
            metadata: { agySessionProtocol: 'acp' },
            created_at: 1000,
            updated_at: 2000,
            seq: 2
        })
        expect(SessionSchema.safeParse(session).success).toBe(true)
        expect(hasActiveSteeringTurn(session)).toBe(true)
    })

    it('preserves invokedAt: null for queued/dispatching/indeterminate user rows so QueuedMessagesBar recognizes them', () => {
        const queued = adaptV1Message({
            id: 'm-queued',
            session_id: 's1',
            seq: 5,
            local_id: 'loc-q',
            role: 'user',
            content_rev: 5,
            invoked_at: null,
            delivery_state: 'queued',
            blocks: [{ type: 'text', text: 'wait in queue' }],
            meta: {},
            created_at: 500
        })
        expect(queued.invokedAt).toBeNull()
        expect(isQueuedForInvocation(queued)).toBe(true)

        const dispatching = adaptV1Message({
            id: 'm-disp-null',
            session_id: 's1',
            seq: 6,
            local_id: 'loc-d',
            role: 'user',
            content_rev: 6,
            invoked_at: null,
            delivery_state: 'dispatching',
            blocks: [{ type: 'text', text: 'steering now' }],
            meta: {},
            created_at: 600
        })
        expect(dispatching.invokedAt).toBeNull()
        expect(isQueuedForInvocation(dispatching)).toBe(true)
        expect((dispatching as { deliveryPending?: boolean }).deliveryPending).toBe(true)

        const indet = adaptV1Message({
            id: 'm-indet-null',
            session_id: 's1',
            seq: 7,
            local_id: 'loc-i',
            role: 'user',
            content_rev: 7,
            invoked_at: null,
            delivery_state: 'indeterminate',
            blocks: [{ type: 'text', text: 'outcome unknown' }],
            meta: {},
            created_at: 700
        })
        expect(indet.invokedAt).toBeNull()
        expect(indet.deliveryState).toBe('indeterminate')
        expect(isQueuedForInvocation(indet)).toBe(true)
    })

    it('projects StoredMessage.meta.usage and meta.model into reducer latestUsage for the context bar', () => {
        const msg = adaptV1Message({
            id: 'm-usage',
            session_id: 's1',
            seq: 10,
            local_id: null,
            role: 'assistant',
            content_rev: 10,
            invoked_at: 1000,
            delivery_state: 'invoked',
            blocks: [{ type: 'text', text: 'Done!' }],
            meta: {
                segmentId: 'seg-10',
                model: 'gemini-3.8-pro',
                usage: {
                    input_tokens: 40_000,
                    output_tokens: 1_250,
                    cache_read_input_tokens: 30_000,
                    context_tokens: 42_500,
                    context_window: 1_000_000
                }
            },
            created_at: 1000
        })
        const normalized = normalizeDecryptedMessage(msg)
        expect(normalized).not.toBeNull()
        expect(normalized?.model).toBe('gemini-3.8-pro')
        const reduced = reduceChatBlocks([normalized!], null)
        expect(reduced.latestUsage).toMatchObject({
            inputTokens: 40_000,
            outputTokens: 1_250,
            cacheRead: 30_000,
            contextSize: 42_500,
            contextWindow: 1_000_000,
            model: 'gemini-3.8-pro'
        })

        // Also handle context-only usage updates (e.g. ACP usage_update before final prompt counts).
        const contextOnly = adaptV1Message({
            id: 'm-ctx-only',
            session_id: 's1',
            seq: 11,
            local_id: null,
            role: 'assistant',
            content_rev: 11,
            invoked_at: 1100,
            delivery_state: 'invoked',
            blocks: [{ type: 'text', text: 'Thinking' }],
            meta: {
                usage: {
                    context_tokens: 120_000,
                    context_window: 200_000
                }
            },
            created_at: 1100
        })
        const ctxNormalized = normalizeDecryptedMessage(contextOnly)
        const ctxReduced = reduceChatBlocks([ctxNormalized!], null)
        expect(ctxReduced.latestUsage).toMatchObject({
            contextSize: 120_000,
            contextWindow: 200_000
        })
    })

    it('adapts Phase B queue/steer/cancel/retry REST responses and SSE events', () => {
        const invokedRaw = {
            id: 'm-inv',
            session_id: 's1',
            seq: 8,
            local_id: 'loc-8',
            role: 'user',
            content_rev: 8,
            invoked_at: 8888,
            delivery_state: 'invoked',
            blocks: [{ type: 'text', text: 'already sent' }],
            meta: {},
            created_at: 8000
        }

        const cancelResp = adaptV1CancelMessageResponse({ status: 'invoked', message: invokedRaw })
        expect(cancelResp.status).toBe('invoked')
        if (cancelResp.status === 'invoked') {
            expect(cancelResp.message.localId).toBe('loc-8')
            expect(cancelResp.message.invokedAt).toBe(8888)
        }

        const steerResp = adaptV1SteerQueuedMessageResponse({ status: 'invoked', message: invokedRaw })
        expect(steerResp.status).toBe('invoked')
        if (steerResp.status === 'invoked') {
            expect(steerResp.message.id).toBe('m-inv')
            expect(steerResp.message.invokedAt).toBe(8888)
        }

        const retryResp = adaptV1RetryIndeterminateMessageResponse({ status: 'invoked', message: invokedRaw })
        expect(retryResp.status).toBe('invoked')
        if (retryResp.status === 'invoked') {
            expect(retryResp.message.localId).toBe('loc-8')
        }

        expect(adaptV1QueuedStateResponse({
            queued_local_ids: ['loc-1'],
            indeterminate_local_ids: ['loc-2'],
            dispatching_local_ids: ['loc-2'],
            invoked_local_messages: [{ local_id: 'loc-3', invoked_at: 3000 }]
        })).toEqual({
            queuedLocalIds: ['loc-1'],
            indeterminateLocalIds: ['loc-2'],
            dispatchingLocalIds: ['loc-2'],
            invokedLocalMessages: [{ localId: 'loc-3', invokedAt: 3000 }]
        })

        expect(adaptV1SyncEvent({
            type: 'messages_consumed',
            namespace: 'default',
            session_id: 's1',
            local_ids: ['loc-1'],
            invoked_at: 4000,
            steered: true
        })).toEqual({
            type: 'messages-consumed',
            namespace: 'default',
            sessionId: 's1',
            localIds: ['loc-1'],
            invokedAt: 4000,
            steered: true
        })

        expect(adaptV1SyncEvent({
            type: 'messages_indeterminate',
            namespace: 'default',
            session_id: 's1',
            local_ids: ['loc-2'],
            dispatching: true
        })).toEqual({
            type: 'messages-indeterminate',
            namespace: 'default',
            sessionId: 's1',
            localIds: ['loc-2'],
            dispatching: true
        })

        expect(adaptV1SyncEvent({
            type: 'messages_requeued',
            namespace: 'default',
            session_id: 's1',
            local_ids: ['loc-2']
        })).toEqual({
            type: 'messages-requeued',
            namespace: 'default',
            sessionId: 's1',
            localIds: ['loc-2']
        })

        expect(adaptV1SyncEvent({
            type: 'message_cancelled',
            namespace: 'default',
            session_id: 's1',
            message_id: 'm-9',
            local_id: 'loc-9'
        })).toEqual({
            type: 'message-cancelled',
            namespace: 'default',
            sessionId: 's1',
            messageId: 'm-9',
            localId: 'loc-9'
        })
    })

    it('surfaces auth_required errors cleanly in adaptV1AgyModelsResponse', () => {
        const hardAuth = adaptV1AgyModelsResponse({
            success: false,
            available_models: [],
            current_model_id: null,
            auth_required: true
        })
        expect(hardAuth.success).toBe(false)
        expect(hardAuth.error).toContain('Authentication required')

        const staleAuth = adaptV1AgyModelsResponse({
            success: true,
            available_models: [{ model_id: 'gemini-3.8-pro-high', name: 'Gemini 3.8 Pro (High)' }],
            current_model_id: 'gemini-3.8-pro-high',
            auth_required: true
        })
        expect(staleAuth.success).toBe(true)
        expect(staleAuth.availableModels).toEqual([{
            model_id: 'gemini-3.8-pro-high',
            modelId: 'gemini-3.8-pro-high',
            name: 'Gemini 3.8 Pro (High)'
        }])
        expect(staleAuth.error).toContain('Authentication required')
    })
})
