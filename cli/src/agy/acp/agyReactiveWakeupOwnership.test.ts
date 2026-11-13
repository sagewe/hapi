import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AcpSdkBackend } from '@/agent/backends/acp';
import type { AgentMessage } from '@/agent/types';
import { AgyReactiveContinuationPendingError, AgyReactiveWakeupTracker, type AgyRawTranscriptStep } from './agyReactiveWakeup';

const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
function fixture() {
    const root = mkdtempSync(join(tmpdir(), 'agy-ownership-'));
    roots.push(root);
    const logs = join(root, 'session', '.system_generated', 'logs');
    mkdirSync(logs, { recursive: true });
    const write = (steps: AgyRawTranscriptStep[]) => writeFileSync(join(logs, 'transcript_full.jsonl'), steps.map((s) => JSON.stringify(s)).join('\n') + '\n');
    write([]);
    const tracker = new AgyReactiveWakeupTracker({ brainDir: root, pollIntervalMs: 5, quietPeriodMs: 5, nextPlannerGraceMs: 15, maxDrainMs: 30 });
    tracker.syncBaseline('session');
    tracker.beforePrompt('session');
    const messages: AgentMessage[] = [];
    const backend = { resumeSession: vi.fn(async () => 'session'), suppressUpdatesDuring: async <T>(fn: () => Promise<T>) => fn() };
    const params = { sessionId: 'session', cwd: '/tmp', mode: { permissionMode: 'request-review' as const, model: null, effort: null }, backend: backend as unknown as AcpSdkBackend, onUpdate: (m: AgentMessage) => messages.push(m), shouldYield: () => false, isAborted: () => false };
    return { tracker, write, messages, backend, params };
}
const step = (step_index: number, source: string, type: string, content = '', status = 'DONE'): AgyRawTranscriptStep => ({ step_index, source, type, content, status });
const sync = [step(0, 'USER_EXPLICIT', 'USER_INPUT', 'start'), step(1, 'MODEL', 'PLANNER_RESPONSE', 'started')];

describe('Antigravity log supplement ownership', () => {
    it('does not repeat a reactive answer already delivered by ACP during concurrent prompts', async () => {
        const f = fixture();
        f.write([...sync, step(2, 'SYSTEM', 'SYSTEM_MESSAGE', 'background finished'), step(3, 'MODEL', 'PLANNER_RESPONSE', 'final answer')]);
        f.tracker.observePromptUpdate({ type: 'text', text: 'started' });
        f.tracker.observePromptUpdate({ type: 'text', text: 'final ' });
        f.tracker.observePromptUpdate({ type: 'text', text: 'answer' });
        await f.tracker.afterPrompt(f.params);
        expect(f.messages).toEqual([]);
        expect(f.backend.resumeSession).not.toHaveBeenCalled();
        expect(f.tracker.hasPendingIdleWork('session')).toBe(false);
    });

    it('does not confuse repeated streaming snapshots with a second identical background reply', async () => {
        const f = fixture();
        f.write([...sync, step(2, 'SYSTEM', 'SYSTEM_MESSAGE', 'timer'), step(3, 'MODEL', 'PLANNER_RESPONSE', 'started')]);
        f.tracker.observePromptUpdate({ type: 'text', text: 'started', id: 'stream', live: true, streamSnapshot: true });
        f.tracker.observePromptUpdate({ type: 'text', text: 'started', id: 'stream', streamSnapshot: true });
        await f.tracker.afterPrompt(f.params);
        expect(f.messages.filter((m) => m.type === 'text')).toEqual([{ type: 'text', text: 'started' }]);
    });

    it('stops log ownership at the next explicit user boundary', async () => {
        const f = fixture();
        f.write(sync);
        await f.tracker.afterPrompt(f.params);
        f.write([...sync, step(2, 'SYSTEM', 'SYSTEM_MESSAGE', 'timer'), step(3, 'MODEL', 'PLANNER_RESPONSE', 'timer reply'),
            step(4, 'USER_EXPLICIT', 'USER_INPUT', 'another client'), step(5, 'MODEL', 'PLANNER_RESPONSE', 'ordinary reply')]);
        await f.tracker.afterIdleWakeup(f.params);
        expect(f.messages.filter((m) => m.type === 'text')).toEqual([{ type: 'text', text: 'timer reply' }]);
    });

    it('bounds a stale RUNNING snapshot without resuming/cancelling native work, then recovers on a real update', async () => {
        const f = fixture();
        const wake = [...sync, step(2, 'SYSTEM', 'SYSTEM_MESSAGE', 'timer')];
        f.write([...wake, step(3, 'MODEL', 'PLANNER_RESPONSE', '', 'RUNNING')]);
        await f.tracker.afterPrompt(f.params);
        expect(f.backend.resumeSession).not.toHaveBeenCalled();
        expect(f.tracker.hasPendingIdleWork('session')).toBe(false);
        await expect(f.tracker.requireResumeSyncBeforePrompt(f.params.backend, 'session', '/tmp', f.params.mode))
            .rejects.toBeInstanceOf(AgyReactiveContinuationPendingError);
        f.write([...wake, step(3, 'MODEL', 'PLANNER_RESPONSE', 'completed')]);
        expect(f.tracker.hasPendingIdleWork('session')).toBe(true);
        await f.tracker.afterIdleWakeup(f.params);
        expect(f.messages.filter((m) => m.type === 'text')).toEqual([{ type: 'text', text: 'completed' }]);
        expect(f.backend.resumeSession).toHaveBeenCalledTimes(1);
        expect(f.tracker.hasPendingIdleWork('session')).toBe(false);
    });

    it('does not resurrect or double-settle an ACP-completed background tool from a stale RUNNING log row', async () => {
        const f = fixture();
        const args = { CommandLine: 'sleep 20', WaitMsBeforeAsync: 1000 };
        f.tracker.observePromptUpdate({ type: 'tool_call', id: 'native-tool', name: 'sleep 20', kind: 'execute', input: args, status: 'in_progress' });
        f.tracker.observePromptUpdate({ type: 'tool_result', id: 'native-tool', output: 'done', status: 'completed' });
        f.tracker.observePromptUpdate({ type: 'text', text: 'startedfinished' });
        f.write([sync[0], { ...step(1, 'MODEL', 'PLANNER_RESPONSE'), tool_calls: [{ name: 'run_command', args }] },
            step(2, 'MODEL', 'GENERIC', 'Tool is running as a background task with task id: session/task-2', 'RUNNING'),
            step(3, 'MODEL', 'PLANNER_RESPONSE', 'started'),
            step(4, 'SYSTEM', 'SYSTEM_MESSAGE', 'Task id "session/task-2" finished with result:\nCommand exited with code 0.\n'),
            step(5, 'MODEL', 'PLANNER_RESPONSE', 'finished')]);
        await f.tracker.afterPrompt(f.params);
        expect(f.messages).toEqual([]);
        expect(f.tracker.hasPendingTasks()).toBe(false);
    });
});
