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
    return { adapter, handle: (id: string, params: unknown = form) => handle(params, id), state: () => state, updateAgentState };
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


describe('agy elicitation answer semantics', () => {
    it('publishes the actual free-text policy and maps valid choices to native values', async () => {
        const { adapter, handle, state } = setup();
        const result = handle('fixed');
        expect(state().requests?.fixed?.arguments).toMatchObject({ questions: [{ allowFreeText: false }] });
        await adapter.handlePermissionResponse({ id: 'fixed', approved: true, answers: { '0': ['One'] } });
        expect(await result).toEqual({ action: 'accept', content: { q1: 'one' } });
        expect(state().completedRequests?.fixed).toMatchObject({ status: 'approved', answers: { '0': ['One'] } });
    });

    it('declines blank and unknown answers on fixed-choice forms rather than accepting an empty object', async () => {
        const invalidAnswers: Array<Record<string, string[]> | undefined> = [undefined, {}, { '0': ['  '] }, { '0': ['unknown choice'] }];
        for (const answers of invalidAnswers) {
            const { adapter, handle, state } = setup();
            const result = handle('fixed');
            await adapter.handlePermissionResponse({ id: 'fixed', approved: true, answers });
            expect(await result).toEqual({ action: 'decline' });
            expect(state().requests).toEqual({});
            expect(state().completedRequests?.fixed).toMatchObject({ status: 'denied', decision: 'denied' });
            expect(state().completedRequests?.fixed?.answers).toBeUndefined();
        }
    });

    it('accepts a text-only question through qN_other and never inserts typed text into a fixed choice', async () => {
        const { adapter, handle, state } = setup();
        const result = handle('text', { sessionId: 'native', requestedSchema: { type: 'object', properties: {
            q3_other: { type: 'string', title: 'Explain?' }
        } } });
        expect(state().requests?.text?.arguments).toEqual({ questions: [{
            question: 'Explain?', multiSelect: false, options: [], allowFreeText: true
        }] });
        await adapter.handlePermissionResponse({ id: 'text', approved: true, answers: { '0': ['  custom answer  '] } });
        expect(await result).toEqual({ action: 'accept', content: { q3_other: 'custom answer' } });
    });

    it('maps multi-choice anyOf/oneOf options and only includes supported custom text', async () => {
        const { adapter, handle } = setup();
        const result = handle('multi', { requestedSchema: { properties: {
            q1: { type: 'array', title: 'Choose', items: { oneOf: [{ const: 'a', title: 'Alpha' }, { const: 'b', title: 'Beta' }] } },
            q1_other: { type: 'string' },
            q2: { type: 'string', title: 'Fixed', anyOf: [{ const: 'yes', title: 'Yes' }] }
        } } });
        await adapter.handlePermissionResponse({ id: 'multi', approved: true, answers: {
            '0': ['Alpha', 'Beta', 'extra'], '1': ['Yes', 'unsupported']
        } });
        expect(await result).toEqual({ action: 'accept', content: { q1: ['a', 'b'], q1_other: 'extra', q2: 'yes' } });
    });

    it('declines unsupported or unanswerable schemas without queueing a pending card', async () => {
        const { handle, updateAgentState } = setup();
        for (const params of [
            { mode: 'url', requestedSchema: {} },
            { requestedSchema: { properties: { q1: { type: 'number' } } } },
            { requestedSchema: { properties: { q1_other: { type: 'array' } } } },
            { requestedSchema: { properties: { q1: { type: 'string' }, q2_other: { type: 'string' } } } }
        ]) expect(await handle('unsupported', params)).toEqual({ action: 'decline' });
        expect(updateAgentState).not.toHaveBeenCalled();
    });
});
