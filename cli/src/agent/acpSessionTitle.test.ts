import { describe, expect, it, vi } from 'vitest';
import type { Metadata } from '../api/types';
import { createAcpSessionTitleSync, registerAcpSessionTitleSync } from './acpSessionTitle';
import type { AcpSessionInfoUpdate } from './backends/acp/AcpSdkBackend';

type TitleClient = Parameters<typeof createAcpSessionTitleSync>[0];

function makeClient(metadata: Partial<Metadata> = {}) {
    const state = { ...metadata } as Metadata;
    const updateMetadata = vi.fn((handler: (metadata: Metadata) => Metadata) => {
        Object.assign(state, handler(state));
    });
    return {
        client: {
            getMetadata: () => ({ ...state }),
            updateMetadata
        } satisfies TitleClient,
        updateMetadata,
        state
    };
}

describe('registerAcpSessionTitleSync', () => {
    it('forwards normalized unique ACP titles into session summary metadata', () => {
        let listener: ((update: AcpSessionInfoUpdate) => void) | null = null;
        const backend = {
            setSessionInfoUpdateListener(next: ((update: AcpSessionInfoUpdate) => void) | null) {
                listener = next;
            }
        };
        const { client, updateMetadata, state } = makeClient();

        registerAcpSessionTitleSync(backend, client);

        listener!({ sessionId: 'session-1', title: '  Native Cursor Title  ' });
        listener!({ sessionId: 'session-1', title: 'Native Cursor Title' });
        listener!({ sessionId: 'session-1', title: '' });
        listener!({ sessionId: 'session-1', title: null });
        listener!({ sessionId: 'session-1', title: 'Untitled' });
        listener!({ sessionId: 'session-1', title: 'New Session' });
        listener!({ sessionId: 'session-1', title: 'New session - 2026-07-12T15:30:03.251Z' });

        expect(updateMetadata).toHaveBeenCalledTimes(1);
        expect(state.summary).toEqual({
            text: 'Native Cursor Title',
            updatedAt: expect.any(Number)
        });
    });

    it('stops syncing native titles after a manual title is set', () => {
        const { client, updateMetadata, state } = makeClient();
        const controller = createAcpSessionTitleSync(client);

        controller.syncNativeTitle('Native Title');
        controller.markManualTitle();
        controller.syncNativeTitle('Newer Native Title');

        expect(updateMetadata).toHaveBeenCalledTimes(2);
        expect(state.summary).toEqual({
            text: 'Native Title',
            updatedAt: expect.any(Number)
        });
        expect(state.acpManualTitle).toBe(true);
    });

    it('persists manual precedence in metadata and honors it after controller recreation', () => {
        const first = makeClient();
        const firstController = createAcpSessionTitleSync(first.client);
        firstController.syncNativeTitle('Native Title');
        firstController.markManualTitle();

        expect(first.state.acpManualTitle).toBe(true);

        const second = makeClient(first.state);
        const secondController = createAcpSessionTitleSync(second.client);
        secondController.syncNativeTitle('Newer Native Title');

        expect(second.updateMetadata).not.toHaveBeenCalled();
    });
});
