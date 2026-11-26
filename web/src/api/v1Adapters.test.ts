import { describe, expect, it } from 'vitest'
import {
    adaptV1AgyModelsResponse,
    adaptV1AuthResponse,
    adaptV1HubSettingsResponse,
    adaptV1Machine,
    adaptV1Message,
    adaptV1MessagesResponse,
    adaptV1ReadStateRequest,
    adaptV1ReadStateResponse,
    adaptV1ScratchlistEntry,
    adaptV1SearchResponse,
    adaptV1Session,
    adaptV1SessionSearchResponse,
    adaptV1SpawnResponse,
    adaptV1SyncEvent,
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
})
