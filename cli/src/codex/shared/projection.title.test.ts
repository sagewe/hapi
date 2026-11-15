import { describe, expect, it, vi } from 'vitest';
import type { ApiSessionClient } from '@/api/apiSession';
import type { Metadata } from '@/api/types';
import { SharedCodexProjection } from './projection';

function fixture(parentThreadId?: string, deferWrites = false) {
    let metadata: Metadata = { path: '/repo', host: 'test', flavor: 'codex', name: 'Manual name' };
    const queued: Array<(value: Metadata) => Metadata> = [];
    const update = vi.fn((fn: (value: Metadata) => Metadata) => {
        if (deferWrites) queued.push(fn);
        else metadata = fn(metadata);
    });
    const send = vi.fn();
    const committed = vi.fn(async (_id: string) => {});
    const appendTags = vi.fn(async (_tags: string[]) => ({ tags: [], added: [], skipped: [], limitReached: false }));
    const session = {
        getMetadata: () => metadata, updateMetadata: update, sendAgentMessage: send,
        sendUserMessage() {}, appendSessionTags: appendTags
    } as unknown as ApiSessionClient;
    return {
        projection: new SharedCodexProjection(session, 'thread', committed, parentThreadId),
        metadata: () => metadata, update, send, committed, appendTags,
        flush: () => { for (const fn of queued.splice(0)) metadata = fn(metadata); }
    };
}

function titleItem(id: string, title: string) {
    return { id, type: 'mcpToolCall', server: 'hapi', tool: 'change_title', arguments: { title },
        status: 'completed', result: { content: [{ type: 'text', text: 'Successfully changed chat title' }], isError: false } };
}
function params(item: unknown, turnId = 'turn') { return { threadId: 'thread', turnId, item }; }
function history(...items: unknown[]) { return { turns: [{ id: 'turn', status: 'completed', items }] }; }

describe('shared Codex titles', () => {
    it('keeps a user lock on live tool completions and historical title projection', async () => {
        const f = fixture()
        f.update(metadata => ({ ...metadata, titleLocked: true }))
        await f.projection.notification('item/completed', params(titleItem('locked', 'Agent')))
        await f.projection.history(history(titleItem('old-locked', 'Historical')))
        expect(f.metadata()).toMatchObject({ name: 'Manual name', titleLocked: true })
    })

    it('renames via metadata.name so a spawn name does not hide change_title', async () => {
        const f = fixture();
        const item = titleItem('title', ' Remote title ');
        await f.projection.notification('item/started', params(item));
        expect(f.update).not.toHaveBeenCalled();
        // Completion may omit the arguments already sent at start.
        await f.projection.notification('item/completed', params({ ...item, arguments: undefined }));
        expect(f.metadata()).toMatchObject({ name: 'Remote title' });
        expect(f.metadata().summary).toBeUndefined();
        expect(f.send.mock.calls.map(([body]) => body.type)).toEqual(['tool-call', 'tool-call-result']);
        expect(f.update).toHaveBeenCalledTimes(1);
        await f.projection.notification('item/completed', params(item));
        f.projection.reset();
        await f.projection.history(history(item));
        await f.projection.notification('item/completed', params(item));
        expect(f.update).toHaveBeenCalledTimes(1);
    });

    it('handles a complete item without a start and orders successive titles across deferred writes', async () => {
        const f = fixture(undefined, true);
        // Start without a spawn name so successive renames are visible on name.
        f.update(metadata => {
            const { name: _ignored, ...rest } = metadata;
            return rest as Metadata;
        });
        f.update.mockClear();
        await f.projection.notification('item/completed', params(titleItem('first', 'First')));
        await f.projection.notification('item/completed', params(titleItem('second', 'Second')));
        f.flush();
        expect(f.metadata().name).toBe('Second');
    });

    it.each([
        { status: 'failed' }, { status: 'cancelled' }, { status: 'inProgress' },
        { error: { message: 'failed' } }, { result: { Err: 'failed' } },
        { result: { isError: true } }, { result: { Ok: { isError: true } } },
        { result: null }, { arguments: { title: '   ' } },
        { server: 'other' }, { tool: 'other' }
    ])('ignores unsuccessful or unrelated tools: %j', async overrides => {
        const f = fixture();
        const item = { ...titleItem('title', 'Wrong'), ...overrides };
        await f.projection.notification('item/started', params(item));
        await f.projection.notification('item/completed', params(item));
        await f.projection.history(history(item));
        expect(f.update).not.toHaveBeenCalled();
    });

    it('isolates child and sibling titles from the root metadata', async () => {
        const child = fixture('parent');
        const item = titleItem('title', 'Child title');
        await child.projection.notification('item/started', params(item));
        await child.projection.notification('item/completed', params(item));
        await child.projection.history(history(item));
        expect(child.update).not.toHaveBeenCalled();
        expect(child.send.mock.calls[0][0].type).toBe('agent-run-trace');
        const root = fixture();
        await root.projection.notification('item/completed', { ...params(item), threadId: 'sibling' });
        expect(root.update).not.toHaveBeenCalled();
    });

    it('restores only the last successful historical title and does not replay earlier names', async () => {
        const f = fixture();
        f.update(metadata => {
            const { name: _ignored, ...rest } = metadata;
            return rest as Metadata;
        });
        f.update.mockClear();
        const first = titleItem('first', 'First');
        const last = titleItem('last', 'Last');
        const snapshot = history(first, last, { ...titleItem('failed', 'Failed'), result: { isError: true } });
        await f.projection.history(snapshot);
        expect(f.metadata().name).toBe('Last');
        expect(f.update).toHaveBeenCalledTimes(1);
        f.projection.reset();
        await f.projection.history(snapshot);
        await f.projection.notification('item/completed', params(first));
        expect(f.metadata().name).toBe('Last');
        expect(f.update).toHaveBeenCalledTimes(1);
    });

    it('never overwrites an existing display title during a cold history replay', async () => {
        const f = fixture();
        f.update(metadata => ({ ...metadata, summary: { text: 'Existing', updatedAt: 123 } }));
        f.update.mockClear();
        await f.projection.history(history(titleItem('old', 'Old')));
        expect(f.update).not.toHaveBeenCalled();
        expect(f.metadata().name).toBe('Manual name');
        expect(f.metadata().summary).toEqual({ text: 'Existing', updatedAt: 123 });
    });

    it('keeps pending inputs from an active snapshot for a later argument-less completion', async () => {
        const f = fixture();
        const item = { ...titleItem('title', 'Resumed'), status: 'inProgress', result: null };
        await f.projection.history({ turns: [{ id: 'turn', status: 'inProgress', items: [item] }] });
        expect(f.update).not.toHaveBeenCalled();
        await f.projection.notification('item/completed', params({ ...titleItem('title', 'unused'), arguments: undefined }));
        expect(f.metadata().name).toBe('Resumed');
    });

    it('does not roll back a live title when a suspended replay or queued metadata callback resumes', async () => {
        const f = fixture(undefined, true);
        f.update(metadata => {
            const { name: _ignored, ...rest } = metadata;
            return rest as Metadata;
        });
        f.update.mockClear();
        let release!: () => void;
        f.committed.mockImplementationOnce(() => new Promise<void>(resolve => { release = resolve; }));
        const replay = f.projection.history(history(
            { id: 'user', type: 'userMessage', content: [{ type: 'text', text: 'hello' }] },
            titleItem('old', 'Old')
        ));
        await vi.waitFor(() => expect(release).toBeTypeOf('function'));
        await f.projection.notification('item/completed', params(titleItem('live', 'Live'), 'next'));
        release(); await replay;
        f.flush();
        expect(f.metadata().name).toBe('Live');

        const queued = fixture(undefined, true);
        queued.update(metadata => {
            const { name: _ignored, ...rest } = metadata;
            return rest as Metadata;
        });
        queued.update.mockClear();
        await queued.projection.history(history(titleItem('old', 'Old')));
        await queued.projection.notification('item/completed', params(titleItem('live', 'Live'), 'next'));
        queued.flush();
        expect(queued.metadata().name).toBe('Live');
    });
});

function tagItem(id: string, tool = 'change_title', tags = ['Web']) {
    return { ...titleItem(id, 'Labeled title'), tool, arguments: { title: 'Labeled title', tags },
        result: { isError: false, structuredContent: { success: true, deferred: true }, content: [] } };
}

describe('owning Codex thread tag effects', () => {
    it('adds tags while retaining a locked title and does not replay removed labels', async () => {
        const f = fixture();
        f.update(meta => ({ ...meta, titleLocked: true }));
        const item = tagItem('tags');
        await f.projection.notification('item/started', params(item));
        await f.projection.notification('item/completed', params({ ...item, arguments: undefined }));
        expect(f.appendTags).toHaveBeenCalledWith(['Web']);
        expect(f.metadata().name).toBe('Manual name');
        await f.projection.notification('item/completed', params(item));
        f.projection.reset();
        await f.projection.history(history(item));
        await f.projection.notification('item/completed', params(item));
        expect(f.appendTags).toHaveBeenCalledTimes(1);
    });

    it('lets add_tags work without a title and rejects descendants or other threads', async () => {
        const item = { ...tagItem('only', 'add_tags'), arguments: { tags: ['新标签'] } };
        const root = fixture();
        await root.projection.notification('item/completed', params(item));
        expect(root.appendTags).toHaveBeenCalledWith(['新标签']);
        expect(root.metadata().name).toBe('Manual name');
        const child = fixture('parent');
        await child.projection.notification('item/completed', params(item));
        expect(child.appendTags).not.toHaveBeenCalled();
        const other = fixture();
        await other.projection.notification('item/completed', { ...params(item), threadId: 'different' });
        expect(other.appendTags).not.toHaveBeenCalled();
    });

    it('requires new-server deferred acceptance rather than a legacy title-only success', async () => {
        const f = fixture();
        await f.projection.notification('item/completed', params({ ...tagItem('old'), result: titleItem('old', 'Title').result }));
        await f.projection.notification('item/completed', params({ ...tagItem('failed'), result: { isError: true } }));
        await f.projection.notification('item/completed', params({ ...tagItem('rejected'), result: { structuredContent: { success: false, deferred: true } } }));
        expect(f.appendTags).not.toHaveBeenCalled();
        const text = { content: [{ type: 'text', text: 'Accepted for deferred application by the owning session; no title or tags have been changed yet.\n' + JSON.stringify({ success: true, deferred: true }) }] };
        await f.projection.notification('item/completed', params({ ...tagItem('json'), result: { Ok: text } }));
        expect(f.appendTags).toHaveBeenCalledTimes(1);
    });

    it('does not hold the conversation stream behind a pending tag HTTP request', async () => {
        const f = fixture();
        let release!: () => void;
        f.appendTags.mockImplementationOnce(() => new Promise(resolve => { release = () => resolve({ tags: [], added: [], skipped: [], limitReached: false }); }));
        await f.projection.notification('item/completed', params(tagItem('pending')));
        expect(f.send).toHaveBeenCalled();
        expect(release).toBeTypeOf('function');
        release();
    });

    it('seeds historical identities before asynchronous history rendering can interleave', async () => {
        const f = fixture();
        let release!: () => void;
        f.committed.mockImplementationOnce(() => new Promise<void>(resolve => { release = resolve; }));
        const item = tagItem('historic');
        const replay = f.projection.history(history({ id: 'u', type: 'userMessage', content: [{ type: 'text', text: 'hi' }] }, item));
        await vi.waitFor(() => expect(release).toBeTypeOf('function'));
        await f.projection.notification('item/completed', params(item));
        release(); await replay;
        expect(f.appendTags).not.toHaveBeenCalled();
    });

    it('does not resurrect historical tags when replay later fills omitted arguments', async () => {
        const f = fixture();
        const item = { ...tagItem('history-args', 'add_tags'), arguments: { tags: ['Web'] } };
        await f.projection.history(history({ ...item, arguments: undefined }));
        await f.projection.notification('item/completed', params(item));
        expect(f.appendTags).not.toHaveBeenCalled();
    });
});
