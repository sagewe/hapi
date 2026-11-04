import { describe, it, expect, vi } from 'vitest';
import { AcpSdkBackend } from '@/agent/backends/acp';
import type { AgentMessage } from '@/agent/types';
import { configureAgyAcpSession } from './agyAcpBackend';

function deferred<T>() {
    let resolve!: (value: T) => void;
    const promise = new Promise<T>((yes) => { resolve = yes; });
    return { promise, resolve };
}
describe('Antigravity ACP backend', () => {
    it('waits for both replies, deduplicates text and preserves steer-owned usage', async () => {
        const main = deferred<unknown>(); const steer = deferred<unknown>();
        const backend = new AcpSdkBackend({ command: 'agy', flavor: 'agy', textChunkMode: 'dedupe' });
        const internals = backend as unknown as { transport: unknown; handleSessionUpdate(params: unknown): void };
        internals.transport = {
            sendRequest: vi.fn(() => main.promise),
            sendRequestWithDispatch: () => ({ dispatched: Promise.resolve(), completed: steer.promise })
        };
        const messages: AgentMessage[] = [];
        let completed = false;
        const prompt = backend.prompt('native', [{ type: 'text', text: 'first' }], (m) => messages.push(m))
            .then(() => { completed = true; });
        await vi.waitFor(() => expect(backend.isPromptRequestInFlight()).toBe(true));
        const pending = backend.beginSoftSteerPrompt('native', [{ type: 'text', text: 'pivot' }]);
        main.resolve({ stopReason: 'end_turn' });
        await new Promise((r) => setTimeout(r, 500));
        expect(completed).toBe(false);
        for (let i = 0; i < 2; i++) {
        internals.handleSessionUpdate({ sessionId: 'native', update: { sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: 'thinking' } } });
        internals.handleSessionUpdate({
            sessionId: 'native', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'STEER_ACCEPTED' } }
        });
        }
        steer.resolve({ stopReason: 'end_turn', usage: { inputTokens: 100, outputTokens: 12 } });
        await pending.completed; await prompt;
        expect(messages.filter((m) => m.type === 'text')).toEqual([{ type: 'text', text: 'STEER_ACCEPTED' }]);
        expect(messages.filter((m) => m.type === 'usage')).toHaveLength(1);
        expect(messages.find((m) => m.type === 'usage')).toMatchObject({ inputTokens: 100, outputTokens: 12 });
        expect(messages.filter((m) => m.type === 'turn_complete')).toHaveLength(1);
    });
    it('applies model and effort separately and refuses unsupported effort', async () => {
        const backend = {
            setModel: vi.fn(async () => {}), setConfigOption: vi.fn(async () => {}),
            getThoughtLevelConfigOption: () => ({ id: 'thought_level', options: [{ value: 'high' }] })
        };
        await configureAgyAcpSession(backend as unknown as AcpSdkBackend, 'id', {
            permissionMode: 'request-review', model: 'gemini-4-argon-high', effort: 'high'
        });
        expect(backend.setModel).toHaveBeenCalledWith('id', 'gemini-4-argon', { flavor: 'agy' });
        expect(backend.setConfigOption).toHaveBeenCalledWith('id', 'thought_level', 'high');
        await expect(configureAgyAcpSession(backend as unknown as AcpSdkBackend, 'id', {
            permissionMode: 'request-review', effort: 'max'
        })).rejects.toThrow('does not advertise');
    });
});
