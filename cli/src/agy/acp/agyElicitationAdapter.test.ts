import { describe, expect, it, vi } from 'vitest';
import type { AcpSdkBackend } from '@/agent/backends/acp';
import type { ApiSessionClient } from '@/api/apiSession';
import type { AgentState } from '@/api/types';
import { AgyElicitationAdapter } from './agyElicitationAdapter';

function setup() {
    let handle!: (params: unknown, requestId: string | number | null) => Promise<unknown>;
    let state: AgentState = {};
    const updateAgentState = vi.fn((update: (state: AgentState) => AgentState) => { state = update(state); });
    const backend = {
        registerExtensionRequestHandler: (_method: string, handler: typeof handle) => { handle = handler; },
        cancelPrompt: vi.fn(async () => {})
    } as unknown as AcpSdkBackend;
    const adapter = new AgyElicitationAdapter({ updateAgentState } as unknown as ApiSessionClient, backend);
    const form = { sessionId: 'native', requestedSchema: { type: 'object', properties: {
        q1: { type: 'string', title: 'Choose?', oneOf: [{ const: 'one', title: 'One' }] }
    } } };
    return { adapter, handle: (id: string) => handle(form, id), state: () => state, updateAgentState };
}

describe('agy elicitation lifecycle', () => {
    it('cancels late forms after an empty Stop sweep instead of creating an orphan wait', async () => {
        const { adapter, handle, updateAgentState } = setup();
        await adapter.cancelAll('Stopped');
        expect(await handle('late')).toEqual({ action: 'cancel' });
        expect(updateAgentState).not.toHaveBeenCalled();
    });

    it('settles existing questions on Stop and admits questions again on the next prompt', async () => {
        const { adapter, handle, state } = setup();
        const previous = handle('first');
        expect(state().requests?.first?.tool).toBe('AskUserQuestion');
        await adapter.cancelAll('Stopped');
        expect(await previous).toEqual({ action: 'cancel' });
        expect(state().requests).toEqual({});
        expect(state().completedRequests?.first?.status).toBe('canceled');
        expect(await handle('late')).toEqual({ action: 'cancel' });
        adapter.beginPrompt();
        const next = handle('next');
        expect(state().requests?.next?.tool).toBe('AskUserQuestion');
        await adapter.handlePermissionResponse({ id: 'next', approved: true, answers: { '0': ['One'] } });
        expect(await next).toEqual({ action: 'accept', content: { q1: 'one' } });
    });
});
