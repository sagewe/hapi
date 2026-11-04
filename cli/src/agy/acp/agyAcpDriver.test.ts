import { describe, it, expect, vi } from 'vitest';
import { AgyAcpDriver } from './agyAcpDriver';
import { MessageQueue2 } from '@/utils/MessageQueue2';
import { hashObject } from '@/utils/deterministicJson';
import { ACP_INDETERMINATE_SYMBOL } from '@/agent/backends/acp/AcpStdioTransport';
import type { AcpSdkBackend } from '@/agent/backends/acp';
import type { AgySession } from '../session';
import type { AgyMode } from '../types';
import type { AgentMessage } from '@/agent/types';

vi.mock('@/agent/permissionAdapter', () => ({ PermissionAdapter: class { async cancelAll() {} } }));
vi.mock('@/agent/acpSessionTitle', () => ({ registerAcpSessionTitleSync: () => {} }));

function deferred<T>() {
    let resolve!: (value: T) => void;
    let reject!: (error: unknown) => void;
    const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
    return { promise, resolve, reject };
}
const mode: AgyMode = { permissionMode: 'request-review', model: null, effort: null };
class TestDriver extends AgyAcpDriver { run() { return this.runMainLoop(); } }
function harness() {
    const turn = deferred<void>();
    const steer = deferred<string | null>();
    const queue = new MessageQueue2<AgyMode>((m) => hashObject(m));
    let active = false;
    let update: ((message: AgentMessage) => void) | undefined;
    const client = {
        updateAgentState: vi.fn(), updateMetadata: vi.fn(),
        rpcHandlerManager: { registerHandler: vi.fn() },
        emitMessagesConsumed: vi.fn(), sendAgentMessage: vi.fn(),
        setSteerDeliveryState: vi.fn(async () => true), emitSteerIndeterminate: vi.fn()
    };
    const session = {
        path: '/tmp', sessionId: null as string | null, client, queue,
        setKillHandler: vi.fn(), onThinkingChange: vi.fn(), sendSessionEvent: vi.fn(),
        onSessionFound: vi.fn((id: string) => { session.sessionId = id; })
    };
    const backend = {
        initialize: vi.fn(async () => {}), newSession: vi.fn(async () => 'agy-native'),
        loadSession: vi.fn(async ({ sessionId }) => sessionId),
        isPromptRequestInFlight: () => active,
        prompt: vi.fn(async (_id, _content, sink) => {
            active = true; update = sink;
            try { await turn.promise; } finally { active = false; }
        }),
        beginSoftSteerPrompt: vi.fn(() => ({ dispatched: Promise.resolve(), completed: steer.promise })),
        waitForResponseComplete: vi.fn(async () => {}), refreshSessionInfo: vi.fn(async () => {}),
        cancelPrompt: vi.fn(async () => {}),
        disconnect: vi.fn(async () => {
            const error = Object.assign(new Error('closed'), { [ACP_INDETERMINATE_SYMBOL]: true });
            turn.reject(error); steer.reject(error);
        })
    };
    // These test promises also represent an idle transport before dispatch.
    void turn.promise.catch(() => {}); void steer.promise.catch(() => {});
    const factory = vi.fn(() => backend as unknown as AcpSdkBackend);
    const driver = new TestDriver(session as unknown as AgySession, factory);
    const start = async () => {
        queue.push('initial', mode, 'initial-id');
        const running = driver.run();
        await vi.waitFor(() => expect(backend.prompt).toHaveBeenCalled());
        update!({ type: 'text', text: 'working' });
        return { running };
    };
    return { driver, session, client, backend, queue, turn, steer, start, factory };
}

describe('Antigravity ACP delivery', () => {
    it('steers one reserved row, keeps the next ordinary message queued, and waits for the steer receipt', async () => {
        const h = harness(); const { running } = await h.start();
        h.queue.push('ordinary', mode, 'later'); h.queue.push('pivot', mode, 'pivot');
        expect(await h.driver.steer({ localId: 'pivot' })).toEqual({ steered: true });
        expect(h.backend.beginSoftSteerPrompt).toHaveBeenCalledWith('agy-native', [{ type: 'text', text: 'pivot' }]);
        expect(h.backend.cancelPrompt).not.toHaveBeenCalled();
        h.turn.resolve();
        await new Promise((r) => setTimeout(r, 10));
        expect(h.backend.prompt).toHaveBeenCalledTimes(1);
        expect(h.session.sendSessionEvent).not.toHaveBeenCalledWith({ type: 'ready' });
        h.queue.cancelByLocalId('later');
        h.steer.resolve('end_turn');
        await vi.waitFor(() => expect(h.client.emitMessagesConsumed).toHaveBeenCalledWith(['pivot'], { steered: true }));
        await h.driver.stop(); await running;
    });
    it('refuses a queued model change without losing its queue position', async () => {
        const h = harness(); const { running } = await h.start();
        h.queue.push('other-model', { ...mode, model: 'other' }, 'other');
        expect((await h.driver.steer({ localId: 'other' })).steered).toBe(false);
        expect(h.backend.beginSoftSteerPrompt).not.toHaveBeenCalled();
        expect(h.queue.cancelByLocalId('other')).toBe(true);
        await h.driver.stop(); await running;
    });
    it('holds ambiguous injected messages for explicit resolution after disconnect', async () => {
        const h = harness(); const { running } = await h.start();
        h.queue.push('pivot', mode, 'pivot');
        await h.driver.steer({ localId: 'pivot' });
        await h.driver.stop(); await running;
        expect(h.client.emitSteerIndeterminate).toHaveBeenCalledWith(['pivot']);
        expect(h.client.emitMessagesConsumed).not.toHaveBeenCalledWith(['pivot'], { steered: true });
        expect(h.backend.prompt).toHaveBeenCalledTimes(1);
    });
    it('restores explicitly rejected steers and does not announce acceptance', async () => {
        const h = harness(); const { running } = await h.start();
        h.queue.push('pivot', mode, 'pivot');
        await h.driver.steer({ localId: 'pivot' });
        h.steer.reject(new Error('invalid prompt'));
        await vi.waitFor(() => expect(h.client.setSteerDeliveryState).toHaveBeenCalledWith(['pivot'], 'queued'));
        expect(h.queue.cancelByLocalId('pivot')).toBe(true);
        expect(h.client.emitMessagesConsumed).not.toHaveBeenCalledWith(['pivot'], { steered: true });
        await h.driver.stop(); await running;
    });
    it('rechecks the turn after the persistence await before dispatching', async () => {
        const h = harness(); const { running } = await h.start();
        const persisted = deferred<boolean>();
        h.client.setSteerDeliveryState.mockImplementationOnce(() => persisted.promise);
        h.queue.push('pivot', mode, 'pivot');
        const pending = h.driver.steer({ localId: 'pivot' });
        h.turn.resolve();
        await new Promise((r) => setTimeout(r, 10));
        persisted.resolve(true);
        expect((await pending).steered).toBe(false);
        expect(h.backend.beginSoftSteerPrompt).not.toHaveBeenCalled();
        await h.driver.stop(); await running;
    });
    it('loads the same native conversation on resume', async () => {
        const h = harness(); h.session.sessionId = 'saved-native';
        const { running } = await h.start();
        expect(h.backend.loadSession).toHaveBeenCalledWith({ cwd: '/tmp', mcpServers: [], sessionId: 'saved-native' });
        expect(h.session.onSessionFound).toHaveBeenCalledWith('saved-native', { agySessionProtocol: 'acp' });
        await h.driver.stop(); await running;
    });
});
