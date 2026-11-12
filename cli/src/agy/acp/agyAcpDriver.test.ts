import { mkdtempSync, mkdirSync, rmSync, writeFileSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it, expect, vi } from 'vitest';
import { AgyAcpDriver } from './agyAcpDriver';
import { AgyElicitationAdapter } from './agyElicitationAdapter';
import { AgyReactiveWakeupTracker, type AgyReactiveWakeupOptions, type AgyRawTranscriptStep } from './agyReactiveWakeup';
import { canonicalizeQuestionToolInput } from '@/agent/utils';
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
function harness(reactiveOptions?: AgyReactiveWakeupOptions) {
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
        resumeSession: vi.fn(async ({ sessionId }) => sessionId),
        registerExtensionRequestHandler: vi.fn(),
        suppressUpdatesDuring: vi.fn(async <T>(fn: () => Promise<T>) => await fn()),
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
    const driver = new TestDriver(session as unknown as AgySession, factory, reactiveOptions);
    const start = async () => {
        queue.push('initial', mode, 'initial-id');
        const running = driver.run();
        await vi.waitFor(() => expect(backend.prompt).toHaveBeenCalled());
        update!({ type: 'text', text: 'working' });
        return { running, getUpdate: () => update! };
    };
    return { driver, session, client, backend, queue, turn, steer, start, factory, getUpdate: () => update! };
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

    it('waits for RUNNING background tasks after prompt() resolves, streams Reactive Wakeup steps, and calls resumeSession to advance SkipHistory', async () => {
        const brainDir = mkdtempSync(join(tmpdir(), 'agy-reactive-test-'));
        try {
            const logsDir = join(brainDir, 'agy-native', '.system_generated', 'logs');
            mkdirSync(logsDir, { recursive: true });
            const transcriptPath = join(logsDir, 'transcript_full.jsonl');
            const appendSteps = (steps: AgyRawTranscriptStep[]) => {
                appendFileSync(transcriptPath, `${steps.map((s) => JSON.stringify(s)).join('\n')}\n`, 'utf8');
            };
            writeFileSync(transcriptPath, '', 'utf8');

            const h = harness({ brainDir, pollIntervalMs: 10, quietPeriodMs: 25 });
            const { running, getUpdate } = await h.start();
            const emit = getUpdate();

            // Simulate agy acp emitting an in_progress background run_command tool_call during prompt()
            emit({
                type: 'tool_call',
                id: 'call_bg_2',
                name: 'sleep 2 && echo done',
                input: { CommandLine: 'sleep 2 && echo done', WaitMsBeforeAsync: 500 },
                status: 'in_progress',
                title: 'sleep 2 && echo done',
                kind: 'execute'
            });
            emit({ type: 'text', text: '后台任务已启动，等待完成...' });

            // Write synchronous turn steps (0..3) with step 2 as RUNNING background task
            appendSteps([
                { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                {
                    step_index: 1,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    tool_calls: [{ name: 'run_command', args: { CommandLine: 'sleep 2 && echo done', WaitMsBeforeAsync: 500 } }]
                },
                {
                    step_index: 2,
                    source: 'MODEL',
                    type: 'GENERIC',
                    status: 'RUNNING',
                    content: 'Created At: 2026-11-07T23:00:00+08:00\nTool is running as a background task with task id: agy-native/task-2\n'
                },
                {
                    step_index: 3,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    content: '后台任务已启动，等待完成...'
                }
            ]);

            // Resolve backend.prompt() while task-2 is still RUNNING
            h.turn.resolve();
            await new Promise((r) => setTimeout(r, 40));

            // Turn must NOT report ready or thinking=false while task-2 is still RUNNING
            expect(h.session.sendSessionEvent).not.toHaveBeenCalledWith({ type: 'ready' });
            expect(h.session.onThinkingChange).not.toHaveBeenCalledWith(false);

            // Now simulate task-2 finishing and Reactive Wakeup executing steps 4..7
            appendSteps([
                {
                    step_index: 4,
                    source: 'SYSTEM',
                    type: 'SYSTEM_MESSAGE',
                    status: 'DONE',
                    content: '<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-07T15:00:05Z sender=agy-native/task-2 priority=MESSAGE_PRIORITY_LOW content=Task id "agy-native/task-2" finished with result:\nCommand exited with code 0.\n\nCommand output:\ndone\n</SYSTEM_MESSAGE>'
                },
                {
                    step_index: 5,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    thinking: 'Checking README before replying.',
                    tool_calls: [{ name: 'read_file', args: { Path: '/tmp/README.md' } }]
                },
                {
                    step_index: 6,
                    source: 'MODEL',
                    type: 'GENERIC',
                    status: 'DONE',
                    content: 'Created At: 2026-11-07T23:00:06+08:00\nCompleted At: 2026-11-07T23:00:06+08:00\nShowing lines 1-1 of 1\n1: # Hello'
                },
                {
                    step_index: 7,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    thinking: 'Everything is verified.',
                    content: '后台任务已完成，输出为 done。',
                    input_tokens: 1200,
                    output_tokens: 80,
                    cache_read_tokens: 400
                }
            ]);

            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            expect(h.session.onThinkingChange).toHaveBeenCalledWith(false);
            expect(h.backend.suppressUpdatesDuring).toHaveBeenCalledTimes(1);
            expect(h.backend.resumeSession).toHaveBeenCalledWith({
                cwd: '/tmp',
                mcpServers: [],
                sessionId: 'agy-native'
            });

            const sentPayloads = h.client.sendAgentMessage.mock.calls.map((c) => c[0]);
            // Background command tool_result emitted with original callId 'call_bg_2'
            expect(sentPayloads).toContainEqual({
                type: 'tool-call-result',
                callId: 'call_bg_2',
                output: { output: 'Command exited with code 0.\n\nCommand output:\ndone', exit_code: 0 },
                is_error: false
            });
            // Reactive read_file tool_call and final text message emitted
            expect(sentPayloads).toContainEqual(expect.objectContaining({
                type: 'tool-call',
                name: 'File README.md',
                nativeKind: 'read',
                status: 'completed'
            }));
            expect(sentPayloads).toContainEqual({
                type: 'message',
                message: '后台任务已完成，输出为 done。'
            });

            await h.driver.stop();
            await running;
        } finally {
            rmSync(brainDir, { recursive: true, force: true });
        }
    });

    it('streams idle Reactive Wakeup turns (e.g. scheduled timers/daemon tasks) between user prompts', async () => {
        const brainDir = mkdtempSync(join(tmpdir(), 'agy-idle-reactive-test-'));
        try {
            const logsDir = join(brainDir, 'agy-native', '.system_generated', 'logs');
            mkdirSync(logsDir, { recursive: true });
            const transcriptPath = join(logsDir, 'transcript_full.jsonl');
            const appendSteps = (steps: AgyRawTranscriptStep[]) => {
                appendFileSync(transcriptPath, `${steps.map((s) => JSON.stringify(s)).join('\n')}\n`, 'utf8');
            };
            writeFileSync(transcriptPath, '', 'utf8');

            const h = harness({ brainDir, pollIntervalMs: 10, quietPeriodMs: 25 });
            const { running } = await h.start();

            // Complete normal synchronous turn (steps 0..1)
            appendSteps([
                { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                { step_index: 1, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'working' }
            ]);
            h.turn.resolve();

            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            h.session.sendSessionEvent.mockClear();
            h.session.onThinkingChange.mockClear();

            // While idle between turns, a scheduled timer fires and appends steps 2..3
            appendSteps([
                {
                    step_index: 2,
                    source: 'SYSTEM',
                    type: 'SYSTEM_MESSAGE',
                    status: 'DONE',
                    content: '<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-07T15:05:00Z sender=agy-native/task-1 priority=MESSAGE_PRIORITY_HIGH content=定时检查\n</SYSTEM_MESSAGE>'
                },
                {
                    step_index: 3,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    content: '定时巡检已完成，一切正常。'
                }
            ]);

            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            expect(h.session.onThinkingChange).toHaveBeenCalledWith(true);
            expect(h.session.onThinkingChange).toHaveBeenCalledWith(false);
            expect(h.backend.resumeSession).toHaveBeenCalledWith({
                cwd: '/tmp',
                mcpServers: [],
                sessionId: 'agy-native'
            });
            expect(h.client.sendAgentMessage).toHaveBeenCalledWith({
                type: 'message',
                message: '定时巡检已完成，一切正常。'
            });

            await h.driver.stop();
            await running;
        } finally {
            rmSync(brainDir, { recursive: true, force: true });
        }
    });

    it('does not hang in afterPrompt when a synchronous turn ends on ask_question, allowing the next message to be sent', async () => {
        const brainDir = mkdtempSync(join(tmpdir(), 'agy-ask-question-test-'));
        try {
            const logsDir = join(brainDir, 'agy-native', '.system_generated', 'logs');
            mkdirSync(logsDir, { recursive: true });
            const transcriptPath = join(logsDir, 'transcript_full.jsonl');
            const appendSteps = (steps: AgyRawTranscriptStep[]) => {
                appendFileSync(transcriptPath, `${steps.map((s) => JSON.stringify(s)).join('\n')}\n`, 'utf8');
            };
            writeFileSync(transcriptPath, '', 'utf8');

            const h = harness({ brainDir, pollIntervalMs: 10, quietPeriodMs: 20 });
            const { running } = await h.start();

            // Simulate turn ending on PLANNER_RESPONSE with ask_question tool_call (no MODEL:GENERIC step yet)
            appendSteps([
                { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                {
                    step_index: 1,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    content: 'What would you like to do?',
                    tool_calls: [{
                        name: 'ask_question',
                        args: {
                            questions: [{
                                question: 'Choose an option',
                                options: ['(Recommended) Option A', 'Option B'],
                                is_multi_select: false
                            }]
                        }
                    }]
                }
            ]);

            h.turn.resolve();

            // Must emit ready and thinking=false without hanging in drainReactiveLoop
            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            expect(h.session.onThinkingChange).toHaveBeenCalledWith(false);

            await h.driver.stop();
            await running;
        } finally {
            rmSync(brainDir, { recursive: true, force: true });
        }
    });

    it('canonicalizes Run ask_question tool calls and bridges elicitation/create to interactive AskUserQuestion answers', async () => {
        const canonical = canonicalizeQuestionToolInput(
            {
                questions: [
                    {
                        question: 'Which environment?',
                        options: ['(Recommended) Staging', 'Production'],
                        is_multi_select: false
                    },
                    {
                        question: 'Which features?',
                        options: ['Auth', 'Metrics'],
                        is_multi_select: true
                    }
                ]
            },
            'Run ask_question'
        );
        expect(canonical).toEqual({
            name: 'AskUserQuestion',
            input: {
                questions: [
                    {
                        question: 'Which environment?',
                        options: [{ label: '(Recommended) Staging' }, { label: 'Production' }],
                        multiSelect: false,
                        is_multi_select: false
                    },
                    {
                        question: 'Which features?',
                        options: [{ label: 'Auth' }, { label: 'Metrics' }],
                        multiSelect: true,
                        is_multi_select: true
                    }
                ]
            }
        });

        let elicitationHandler: ((params: unknown, requestId: string | number | null) => Promise<unknown>) | undefined;
        let agentState: Record<string, unknown> = { requests: {}, completedRequests: {} };
        const client = {
            updateAgentState: vi.fn((updater: (state: unknown) => Record<string, unknown>) => {
                agentState = updater(agentState);
            })
        };
        const backend = {
            registerExtensionRequestHandler: vi.fn((method: string, handler: typeof elicitationHandler) => {
                if (method === 'elicitation/create') {
                    elicitationHandler = handler;
                }
            }),
            cancelPrompt: vi.fn(async () => {})
        };

        const adapter = new AgyElicitationAdapter(
            client as unknown as ConstructorParameters<typeof AgyElicitationAdapter>[0],
            backend as unknown as AcpSdkBackend
        );
        expect(elicitationHandler).toBeDefined();

        const elicitationPromise = elicitationHandler!(
            {
                sessionId: 'agy-native',
                toolCallId: 'call_ask_1',
                mode: 'form',
                message: 'Please answer the questions',
                requestedSchema: {
                    type: 'object',
                    properties: {
                        q1: {
                            type: 'string',
                            title: 'Which environment?',
                            oneOf: [
                                { const: 'opt_staging', title: '(Recommended) Staging' },
                                { const: 'opt_prod', title: 'Production' }
                            ]
                        },
                        q1_other: {
                            type: 'string',
                            title: 'Other',
                            description: 'Custom answer if none of the options fit'
                        },
                        q2: {
                            type: 'array',
                            title: 'Which features?',
                            items: {
                                type: 'string',
                                anyOf: [
                                    { const: 'feat_auth', title: 'Auth' },
                                    { const: 'feat_metrics', title: 'Metrics' }
                                ]
                            }
                        },
                        q2_other: {
                            type: 'string',
                            title: 'Other',
                            description: 'Custom answer if none of the options fit'
                        }
                    }
                }
            },
            42
        );

        expect((agentState.requests as Record<string, unknown>).call_ask_1).toEqual(
            expect.objectContaining({
                tool: 'AskUserQuestion',
                arguments: {
                    questions: [
                        {
                            question: 'Which environment?',
                            multiSelect: false,
                            options: [{ label: '(Recommended) Staging' }, { label: 'Production' }]
                        },
                        {
                            question: 'Which features?',
                            multiSelect: true,
                            options: [{ label: 'Auth' }, { label: 'Metrics' }]
                        }
                    ]
                }
            })
        );

        const handled = await adapter.handlePermissionResponse({
            id: 'call_ask_1',
            approved: true,
            decision: 'approved',
            answers: {
                '0': ['Production'],
                '1': ['Auth', 'Custom tracing']
            }
        });
        expect(handled).toBe(true);

        const result = await elicitationPromise;
        expect(result).toEqual({
            action: 'accept',
            content: {
                q1: 'opt_prod',
                q2: ['feat_auth'],
                q2_other: 'Custom tracing'
            }
        });
        expect((agentState.completedRequests as Record<string, unknown>).call_ask_1).toEqual(
            expect.objectContaining({
                tool: 'AskUserQuestion',
                status: 'approved',
                answers: {
                    '0': ['Production'],
                    '1': ['Auth', 'Custom tracing']
                }
            })
        );
    });

    it('settles orphaned reactive tool calls on stream interruption gap (393 -> 398) while preserving live background tasks and finishing thinking=false', async () => {
        const brainDir = mkdtempSync(join(tmpdir(), 'agy-stream-gap-test-'));
        try {
            const logsDir = join(brainDir, 'agy-native', '.system_generated', 'logs');
            mkdirSync(logsDir, { recursive: true });
            const transcriptPath = join(logsDir, 'transcript_full.jsonl');
            const appendSteps = (steps: AgyRawTranscriptStep[]) => {
                appendFileSync(transcriptPath, `${steps.map((s) => JSON.stringify(s)).join('\n')}\n`, 'utf8');
            };
            writeFileSync(transcriptPath, '', 'utf8');

            const h = harness({ brainDir, pollIntervalMs: 10, quietPeriodMs: 20 });
            const { running } = await h.start();

            // Synchronous turn spawns two background tasks: task-377 and task-378
            appendSteps([
                { step_index: 375, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                {
                    step_index: 376,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    tool_calls: [
                        { name: 'run_command', args: { CommandLine: 'build-mac', WaitMsBeforeAsync: 500 } },
                        { name: 'run_command', args: { CommandLine: 'build-ios', WaitMsBeforeAsync: 500 } }
                    ]
                },
                {
                    step_index: 377,
                    source: 'MODEL',
                    type: 'GENERIC',
                    status: 'RUNNING',
                    content: 'Tool is running as a background task with task id: agy-native/task-377\n'
                },
                {
                    step_index: 378,
                    source: 'MODEL',
                    type: 'GENERIC',
                    status: 'RUNNING',
                    content: 'Tool is running as a background task with task id: agy-native/task-378\n'
                },
                { step_index: 382, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'Waiting on builds...' }
            ]);
            h.turn.resolve();

            // task-377 finishes, step 393 emits 4 file write/edit calls (expecting 394..397),
            // then stream interrupts at step 398 while task-378 is STILL running!
            appendSteps([
                {
                    step_index: 383,
                    source: 'SYSTEM',
                    type: 'SYSTEM_MESSAGE',
                    status: 'DONE',
                    content: '<SYSTEM_MESSAGE>\nTask id "agy-native/task-377" finished with result:\nCommand exited with code 0.\n</SYSTEM_MESSAGE>'
                },
                {
                    step_index: 393,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    tool_calls: [
                        { name: 'write_file', args: { Path: '/tmp/a.md', Content: 'a' } },
                        { name: 'edit_file', args: { Path: '/tmp/b.md' } },
                        { name: 'edit_file', args: { Path: '/tmp/c.md' } },
                        { name: 'edit_file', args: { Path: '/tmp/d.md' } }
                    ]
                },
                {
                    step_index: 398,
                    source: 'SYSTEM',
                    type: 'ERROR_MESSAGE',
                    status: 'DONE',
                    content: 'Error: The stream was interrupted. Please continue the task you were working on.'
                },
                {
                    step_index: 399,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    content: 'Recovered after interruption; waiting for task-378.'
                }
            ]);

            await new Promise((r) => setTimeout(r, 50));
            // task-378 is still running, so turn must NOT prematurely report ready
            expect(h.session.sendSessionEvent).not.toHaveBeenCalledWith({ type: 'ready' });

            // Now task-378 finishes and step 412 completes the turn
            appendSteps([
                {
                    step_index: 411,
                    source: 'SYSTEM',
                    type: 'SYSTEM_MESSAGE',
                    status: 'DONE',
                    content: '<SYSTEM_MESSAGE>\nTask id "agy-native/task-378" finished with result:\nCommand exited with code 0.\n</SYSTEM_MESSAGE>'
                },
                {
                    step_index: 412,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    content: 'All builds and docs complete.'
                }
            ]);

            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            expect(h.session.onThinkingChange).toHaveBeenCalledWith(false);

            const sentPayloads = h.client.sendAgentMessage.mock.calls.map((c) => c[0]);
            for (const offset of [0, 1, 2, 3]) {
                expect(sentPayloads).toContainEqual(expect.objectContaining({
                    type: 'tool-call-result',
                    callId: `call_reactive_393_${offset}`,
                    is_error: true
                }));
                expect(sentPayloads).not.toContainEqual(expect.objectContaining({
                    type: 'tool-call-result',
                    callId: `call_reactive_393_${offset}`,
                    is_error: false
                }));
            }
            expect(sentPayloads).toContainEqual({
                type: 'message',
                message: 'All builds and docs complete.'
            });

            await h.driver.stop();
            await running;
        } finally {
            rmSync(brainDir, { recursive: true, force: true });
        }
    });

    it('processes in-place same-step_index RUNNING -> DONE transitions without dropping text or tool results', async () => {
        const brainDir = mkdtempSync(join(tmpdir(), 'agy-inplace-step-test-'));
        try {
            const logsDir = join(brainDir, 'agy-native', '.system_generated', 'logs');
            mkdirSync(logsDir, { recursive: true });
            const transcriptPath = join(logsDir, 'transcript_full.jsonl');
            const writeSteps = (steps: AgyRawTranscriptStep[]) => {
                writeFileSync(transcriptPath, `${steps.map((s) => JSON.stringify(s)).join('\n')}\n`, 'utf8');
            };

            const h = harness({ brainDir, pollIntervalMs: 10, quietPeriodMs: 20 });
            const { running } = await h.start();

            const baseSteps: AgyRawTranscriptStep[] = [
                { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                {
                    step_index: 1,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    tool_calls: [{ name: 'run_command', args: { CommandLine: 'sleep 1', WaitMsBeforeAsync: 500 } }]
                },
                {
                    step_index: 2,
                    source: 'MODEL',
                    type: 'GENERIC',
                    status: 'RUNNING',
                    content: 'Tool is running as a background task with task id: agy-native/task-2\n'
                },
                { step_index: 3, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'waiting' },
                {
                    step_index: 4,
                    source: 'SYSTEM',
                    type: 'SYSTEM_MESSAGE',
                    status: 'DONE',
                    content: '<SYSTEM_MESSAGE>\nTask id "agy-native/task-2" finished with result:\nCommand exited with code 0.\n</SYSTEM_MESSAGE>'
                },
                {
                    step_index: 5,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'RUNNING',
                    content: 'partial'
                }
            ];
            writeSteps(baseSteps);
            h.turn.resolve();

            // Allow multiple poll cycles while step 5 is still RUNNING
            await new Promise((r) => setTimeout(r, 45));
            expect(h.session.sendSessionEvent).not.toHaveBeenCalledWith({ type: 'ready' });

            // Rewrite step 5 in-place as DONE with full content
            writeSteps([
                ...baseSteps.slice(0, -1),
                {
                    step_index: 5,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    content: 'full final reactive answer'
                }
            ]);

            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            expect(h.client.sendAgentMessage).toHaveBeenCalledWith({
                type: 'message',
                message: 'full final reactive answer'
            });

            await h.driver.stop();
            await running;
        } finally {
            rmSync(brainDir, { recursive: true, force: true });
        }
    });

    it('does not deadlock when a reactive wakeup turn ends on ask_question without a GENERIC step', async () => {
        const brainDir = mkdtempSync(join(tmpdir(), 'agy-reactive-ask-test-'));
        try {
            const logsDir = join(brainDir, 'agy-native', '.system_generated', 'logs');
            mkdirSync(logsDir, { recursive: true });
            const transcriptPath = join(logsDir, 'transcript_full.jsonl');
            const appendSteps = (steps: AgyRawTranscriptStep[]) => {
                appendFileSync(transcriptPath, `${steps.map((s) => JSON.stringify(s)).join('\n')}\n`, 'utf8');
            };
            writeFileSync(transcriptPath, '', 'utf8');

            const h = harness({ brainDir, pollIntervalMs: 10, quietPeriodMs: 20 });
            const { running } = await h.start();

            appendSteps([
                { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                {
                    step_index: 1,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    tool_calls: [{ name: 'run_command', args: { CommandLine: 'check', WaitMsBeforeAsync: 500 } }]
                },
                {
                    step_index: 2,
                    source: 'MODEL',
                    type: 'GENERIC',
                    status: 'RUNNING',
                    content: 'Tool is running as a background task with task id: agy-native/task-2\n'
                },
                { step_index: 3, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'checking...' }
            ]);
            h.turn.resolve();

            appendSteps([
                {
                    step_index: 4,
                    source: 'SYSTEM',
                    type: 'SYSTEM_MESSAGE',
                    status: 'DONE',
                    content: '<SYSTEM_MESSAGE>\nTask id "agy-native/task-2" finished with result:\nCommand exited with code 1.\n</SYSTEM_MESSAGE>'
                },
                {
                    step_index: 5,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    content: 'How should we recover?',
                    tool_calls: [{
                        name: 'ask_question',
                        args: {
                            questions: [{
                                question: 'Retry or abort?',
                                options: ['Retry', 'Abort']
                            }]
                        }
                    }]
                }
            ]);

            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            expect(h.session.onThinkingChange).toHaveBeenCalledWith(false);

            await h.driver.stop();
            await running;
        } finally {
            rmSync(brainDir, { recursive: true, force: true });
        }
    });

    it('settles both pendingTasks and pendingReactiveToolResults on server restart and wakes from empty initial baseline', async () => {
        const brainDir = mkdtempSync(join(tmpdir(), 'agy-restart-baseline-test-'));
        try {
            const logsDir = join(brainDir, 'agy-native', '.system_generated', 'logs');
            mkdirSync(logsDir, { recursive: true });
            const transcriptPath = join(logsDir, 'transcript_full.jsonl');
            // Note: transcript_full.jsonl intentionally does NOT exist yet when start() calls syncBaseline!

            const h = harness({ brainDir, pollIntervalMs: 10, quietPeriodMs: 20 });
            const { running } = await h.start();
            // Finish initial prompt before transcript exists
            h.turn.resolve();
            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            h.session.sendSessionEvent.mockClear();
            h.session.onThinkingChange.mockClear();

            // Create transcript starting at step_index 0 while idle (verifies empty baseline -1 wakes up)
            appendFileSync(
                transcriptPath,
                `${[
                    {
                        step_index: 0,
                        source: 'MODEL',
                        type: 'PLANNER_RESPONSE',
                        status: 'DONE',
                        tool_calls: [{ name: 'write_file', args: { Path: '/tmp/out.txt', Content: 'hi' } }]
                    },
                    {
                        step_index: 2,
                        source: 'SYSTEM',
                        type: 'SYSTEM_MESSAGE',
                        status: 'DONE',
                        content: 'All your subagents and background tasks have been stopped due to server restart.'
                    }
                ].map((s) => JSON.stringify(s)).join('\n')}\n`,
                'utf8'
            );

            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            const sentPayloads = h.client.sendAgentMessage.mock.calls.map((c) => c[0]);
            expect(sentPayloads).toContainEqual(expect.objectContaining({
                type: 'tool-call-result',
                callId: 'call_reactive_0_0',
                is_error: true
            }));

            await h.driver.stop();
            await running;
        } finally {
            rmSync(brainDir, { recursive: true, force: true });
        }
    });

    it('retains SkipHistory resumeSession debt when resumeSession fails and flushes it before the next prompt, plus caches unchanged transcript reads', async () => {
        const brainDir = mkdtempSync(join(tmpdir(), 'agy-resume-debt-test-'));
        try {
            const logsDir = join(brainDir, 'agy-native', '.system_generated', 'logs');
            mkdirSync(logsDir, { recursive: true });
            const transcriptPath = join(logsDir, 'transcript_full.jsonl');
            writeFileSync(
                transcriptPath,
                `${[
                    { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                    { step_index: 1, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'ok' }
                ].map((s) => JSON.stringify(s)).join('\n')}\n`,
                'utf8'
            );

            // Verify stat-gated cache returns identical array reference when file is untouched
            const standalone = new AgyReactiveWakeupTracker({ brainDir });
            const firstRead = standalone.readSteps('agy-native');
            const secondRead = standalone.readSteps('agy-native');
            expect(secondRead).toBe(firstRead);

            const h = harness({ brainDir, pollIntervalMs: 10, quietPeriodMs: 20 });
            h.backend.resumeSession
                .mockRejectedValueOnce(new Error('transient RPC timeout'))
                .mockResolvedValue('agy-native');

            const { running } = await h.start();
            h.turn.resolve();
            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            h.session.sendSessionEvent.mockClear();

            // Idle wakeup appends reactive steps; first resumeSession fails transiently
            appendFileSync(
                transcriptPath,
                `${[
                    {
                        step_index: 2,
                        source: 'SYSTEM',
                        type: 'SYSTEM_MESSAGE',
                        status: 'DONE',
                        content: '<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-12T15:00:00Z sender=agy-native/task-9 priority=HIGH content=ping\n</SYSTEM_MESSAGE>'
                    },
                    { step_index: 3, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'pong' }
                ].map((s) => JSON.stringify(s)).join('\n')}\n`,
                'utf8'
            );

            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            expect(h.backend.resumeSession).toHaveBeenCalledTimes(1);

            // Next user prompt flushes pending SkipHistory sync before calling backend.prompt()
            h.backend.prompt.mockImplementationOnce(async () => {});
            h.queue.push('follow-up', mode, 'second-id');
            await vi.waitFor(() => {
                expect(h.backend.prompt).toHaveBeenCalledTimes(2);
            });
            expect(h.backend.resumeSession).toHaveBeenCalledTimes(2);

            await h.driver.stop();
            await running;
        } finally {
            rmSync(brainDir, { recursive: true, force: true });
        }
    });

    it('blocks backend.prompt and restores user message via abort-restore if SkipHistory resumeSession persistently fails', async () => {
        const brainDir = mkdtempSync(join(tmpdir(), 'agy-resume-gate-test-'));
        try {
            const logsDir = join(brainDir, 'agy-native', '.system_generated', 'logs');
            mkdirSync(logsDir, { recursive: true });
            const transcriptPath = join(logsDir, 'transcript_full.jsonl');
            writeFileSync(
                transcriptPath,
                `${[
                    { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                    { step_index: 1, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'ok' }
                ].map((s) => JSON.stringify(s)).join('\n')}\n`,
                'utf8'
            );

            const h = harness({ brainDir, pollIntervalMs: 10, quietPeriodMs: 20 });
            h.backend.resumeSession.mockRejectedValue(new Error('persistent resume failure'));

            const { running } = await h.start();
            h.turn.resolve();
            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            h.session.sendSessionEvent.mockClear();

            appendFileSync(
                transcriptPath,
                `${[
                    {
                        step_index: 2,
                        source: 'SYSTEM',
                        type: 'SYSTEM_MESSAGE',
                        status: 'DONE',
                        content: '<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-12T15:00:00Z sender=agy-native/task-9 priority=HIGH content=ping\n</SYSTEM_MESSAGE>'
                    },
                    { step_index: 3, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'pong' }
                ].map((s) => JSON.stringify(s)).join('\n')}\n`,
                'utf8'
            );

            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            expect(h.backend.resumeSession).toHaveBeenCalledTimes(1);
            h.session.sendSessionEvent.mockClear();

            // Queue follow-up while resumeSession still rejects: prompt MUST NOT be called!
            h.queue.push('follow-up', mode, 'second-id');
            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({
                    type: 'abort-restore',
                    text: 'follow-up'
                });
            });
            expect(h.backend.prompt).toHaveBeenCalledTimes(1);
            expect(h.backend.resumeSession).toHaveBeenCalledTimes(2);
            expect(h.backend.disconnect).toHaveBeenCalled();

            await h.driver.stop();
            await running;
        } finally {
            rmSync(brainDir, { recursive: true, force: true });
        }
    });

    it('does not falsely fail RUNNING tools/planner when ordinary SYSTEM_MESSAGE arrives and preserves call_reactive_* callId on late DONE', async () => {
        const brainDir = mkdtempSync(join(tmpdir(), 'agy-running-sysmsg-test-'));
        try {
            const logsDir = join(brainDir, 'agy-native', '.system_generated', 'logs');
            mkdirSync(logsDir, { recursive: true });
            const transcriptPath = join(logsDir, 'transcript_full.jsonl');
            const writeSteps = (steps: AgyRawTranscriptStep[]) => {
                writeFileSync(transcriptPath, `${steps.map((s) => JSON.stringify(s)).join('\n')}\n`, 'utf8');
            };

            const h = harness({ brainDir, pollIntervalMs: 10, quietPeriodMs: 20 });
            const { running } = await h.start();

            // Sync turn ends at step 1; reactive wakeup has step 2 (SYSTEM_MESSAGE),
            // step 3 (PLANNER calling run_command), step 4 (GENERIC:RUNNING non-bg),
            // AND an async background notification arrives at step 5 while step 4 is RUNNING!
            writeSteps([
                { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                { step_index: 1, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'sync ok' },
                {
                    step_index: 2,
                    source: 'SYSTEM',
                    type: 'SYSTEM_MESSAGE',
                    status: 'DONE',
                    content: '<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-12T15:00:00Z sender=agy-native/task-1 priority=HIGH content=wake\n</SYSTEM_MESSAGE>'
                },
                {
                    step_index: 3,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    tool_calls: [{ name: 'run_command', args: { CommandLine: 'long-sync-cmd', WaitMsBeforeAsync: 10000 } }]
                },
                {
                    step_index: 4,
                    source: 'MODEL',
                    type: 'GENERIC',
                    status: 'RUNNING',
                    content: ''
                },
                {
                    step_index: 5,
                    source: 'SYSTEM',
                    type: 'SYSTEM_MESSAGE',
                    status: 'DONE',
                    content: '<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-12T15:00:02Z sender=agy-native/task-99 priority=NORMAL content=other-note\n</SYSTEM_MESSAGE>'
                }
            ]);
            h.turn.resolve();

            await new Promise((r) => setTimeout(r, 45));
            const midPayloads = h.client.sendAgentMessage.mock.calls.map((c) => c[0]);
            // Step 4 MUST NOT have been marked failed by ordinary SYSTEM_MESSAGE at step 5!
            expect(midPayloads).not.toContainEqual(expect.objectContaining({
                type: 'tool-call-result',
                callId: 'call_reactive_3_0',
                is_error: true
            }));
            expect(h.session.sendSessionEvent).not.toHaveBeenCalledWith({ type: 'ready' });

            // Now step 4 completes in-place as DONE and step 6 finishes the reactive turn
            writeSteps([
                { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                { step_index: 1, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'sync ok' },
                {
                    step_index: 2,
                    source: 'SYSTEM',
                    type: 'SYSTEM_MESSAGE',
                    status: 'DONE',
                    content: '<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-12T15:00:00Z sender=agy-native/task-1 priority=HIGH content=wake\n</SYSTEM_MESSAGE>'
                },
                {
                    step_index: 3,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    tool_calls: [{ name: 'run_command', args: { CommandLine: 'long-sync-cmd', WaitMsBeforeAsync: 10000 } }]
                },
                {
                    step_index: 4,
                    source: 'MODEL',
                    type: 'GENERIC',
                    status: 'DONE',
                    content: 'Command exited with code 0.\nok'
                },
                {
                    step_index: 5,
                    source: 'SYSTEM',
                    type: 'SYSTEM_MESSAGE',
                    status: 'DONE',
                    content: '<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-12T15:00:02Z sender=agy-native/task-99 priority=NORMAL content=other-note\n</SYSTEM_MESSAGE>'
                },
                {
                    step_index: 6,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    content: 'done cleanly'
                }
            ]);

            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            const finalPayloads = h.client.sendAgentMessage.mock.calls.map((c) => c[0]);
            expect(finalPayloads).toContainEqual(expect.objectContaining({
                type: 'tool-call-result',
                callId: 'call_reactive_3_0',
                is_error: false
            }));
            expect(finalPayloads).not.toContainEqual(expect.objectContaining({
                type: 'tool-call-result',
                callId: 'call_reactive_4'
            }));

            await h.driver.stop();
            await running;
        } finally {
            rmSync(brainDir, { recursive: true, force: true });
        }
    });

    it('does not duplicate reactive messages on mid-write malformed lines or temporary short rewrite snapshots', () => {
        const brainDir = mkdtempSync(join(tmpdir(), 'agy-torn-read-test-'));
        try {
            const logsDir = join(brainDir, 'agy-native', '.system_generated', 'logs');
            mkdirSync(logsDir, { recursive: true });
            const transcriptPath = join(logsDir, 'transcript_full.jsonl');

            const step0: AgyRawTranscriptStep = { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' };
            const step1: AgyRawTranscriptStep = { step_index: 1, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'sync1' };
            const step2: AgyRawTranscriptStep = { step_index: 2, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'reactive2' };
            const step3: AgyRawTranscriptStep = { step_index: 3, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'reactive3' };
            const step4: AgyRawTranscriptStep = { step_index: 4, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'reactive4' };

            writeFileSync(transcriptPath, `${[step0, step1].map((s) => JSON.stringify(s)).join('\n')}\n`, 'utf8');
            const tracker = new AgyReactiveWakeupTracker({ brainDir });
            tracker.syncBaseline('agy-native');

            const emitted: AgentMessage[] = [];
            const onUpdate = (m: AgentMessage) => emitted.push(m);

            // Emit reactive2 and reactive3 once
            writeFileSync(transcriptPath, `${[step0, step1, step2, step3].map((s) => JSON.stringify(s)).join('\n')}\n`, 'utf8');
            (tracker as unknown as { processNewReactiveSteps: (s: AgyRawTranscriptStep[], cwd: string, cb: (m: AgentMessage) => void) => boolean })
                .processNewReactiveSteps(tracker.readSteps('agy-native'), '/tmp', onUpdate);
            expect(emitted.filter((m) => m.type === 'text')).toEqual([
                { type: 'text', text: 'reactive2' },
                { type: 'text', text: 'reactive3' }
            ]);

            // Simulate torn rewrite 1: step0, step1 + truncated JSON tail
            writeFileSync(transcriptPath, `${JSON.stringify(step0)}\n${JSON.stringify(step1)}\n{"step_index":2,"source":"MO`, 'utf8');
            (tracker as unknown as { processNewReactiveSteps: (s: AgyRawTranscriptStep[], cwd: string, cb: (m: AgentMessage) => void) => boolean })
                .processNewReactiveSteps(tracker.readSteps('agy-native'), '/tmp', onUpdate);

            // Simulate torn rewrite 2: momentary 0-byte window
            writeFileSync(transcriptPath, '', 'utf8');
            (tracker as unknown as { processNewReactiveSteps: (s: AgyRawTranscriptStep[], cwd: string, cb: (m: AgentMessage) => void) => boolean })
                .processNewReactiveSteps(tracker.readSteps('agy-native'), '/tmp', onUpdate);

            // Simulate torn rewrite 3: clean newline prefix [step0, step1] before step2..step4 flush
            writeFileSync(transcriptPath, `${[step0, step1].map((s) => JSON.stringify(s)).join('\n')}\n`, 'utf8');
            (tracker as unknown as { processNewReactiveSteps: (s: AgyRawTranscriptStep[], cwd: string, cb: (m: AgentMessage) => void) => boolean })
                .processNewReactiveSteps(tracker.readSteps('agy-native'), '/tmp', onUpdate);

            // Writer finishes flushing [step0..step4]: ONLY reactive4 may be emitted!
            writeFileSync(transcriptPath, `${[step0, step1, step2, step3, step4].map((s) => JSON.stringify(s)).join('\n')}\n`, 'utf8');
            (tracker as unknown as { processNewReactiveSteps: (s: AgyRawTranscriptStep[], cwd: string, cb: (m: AgentMessage) => void) => boolean })
                .processNewReactiveSteps(tracker.readSteps('agy-native'), '/tmp', onUpdate);

            expect(emitted.filter((m) => m.type === 'text')).toEqual([
                { type: 'text', text: 'reactive2' },
                { type: 'text', text: 'reactive3' },
                { type: 'text', text: 'reactive4' }
            ]);
        } finally {
            rmSync(brainDir, { recursive: true, force: true });
        }
    });

    it('settles BACKGROUND_RUNNING in-place DONE transitions without SYSTEM_MESSAGE and wakes on divergent truncation below promptEndStepIndex', async () => {
        const brainDir = mkdtempSync(join(tmpdir(), 'agy-bg-inplace-truncate-test-'));
        try {
            const logsDir = join(brainDir, 'agy-native', '.system_generated', 'logs');
            mkdirSync(logsDir, { recursive: true });
            const transcriptPath = join(logsDir, 'transcript_full.jsonl');
            const writeSteps = (steps: AgyRawTranscriptStep[]) => {
                writeFileSync(transcriptPath, `${steps.map((s) => JSON.stringify(s)).join('\n')}\n`, 'utf8');
            };

            const h = harness({ brainDir, pollIntervalMs: 10, quietPeriodMs: 20 });
            const { running } = await h.start();
            h.getUpdate()({
                type: 'tool_call',
                id: 'call_sync_bg_2',
                name: 'bg-job',
                title: 'bg-job',
                kind: 'execute',
                input: { CommandLine: 'bg-job' },
                status: 'in_progress'
            });

            // Sync turn has step 2 as background task (step_index 2 <= promptEndStepIndex 3)
            writeSteps([
                { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                {
                    step_index: 1,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    tool_calls: [{ name: 'run_command', args: { CommandLine: 'bg-job', WaitMsBeforeAsync: 500 } }]
                },
                {
                    step_index: 2,
                    source: 'MODEL',
                    type: 'GENERIC',
                    status: 'RUNNING',
                    content: 'Tool is running as a background task with task id: agy-native/task-2\n'
                },
                { step_index: 3, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'started bg-job' }
            ]);
            h.turn.resolve();

            await new Promise((r) => setTimeout(r, 35));
            expect(h.session.sendSessionEvent).not.toHaveBeenCalledWith({ type: 'ready' });

            // Transition step 2 in-place to DONE WITHOUT any SYSTEM_MESSAGE!
            writeSteps([
                { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                {
                    step_index: 1,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    tool_calls: [{ name: 'run_command', args: { CommandLine: 'bg-job', WaitMsBeforeAsync: 500 } }]
                },
                {
                    step_index: 2,
                    source: 'MODEL',
                    type: 'GENERIC',
                    status: 'DONE',
                    content: 'Command exited with code 0.\nbg finished directly'
                },
                { step_index: 3, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'started bg-job' }
            ]);

            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            expect(h.client.sendAgentMessage).toHaveBeenCalledWith(expect.objectContaining({
                type: 'tool-call-result',
                callId: 'call_sync_bg_2',
                is_error: false
            }));

            h.session.sendSessionEvent.mockClear();

            // Now truncate/replace transcript below old promptEndStepIndex (3) with new step at index 1!
            writeSteps([
                { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                { step_index: 1, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'post-truncate wakeup below old promptEnd' }
            ]);

            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            expect(h.client.sendAgentMessage).toHaveBeenCalledWith({
                type: 'message',
                message: 'post-truncate wakeup below old promptEnd'
            });

            await h.driver.stop();
            await running;
        } finally {
            rmSync(brainDir, { recursive: true, force: true });
        }
    });

    it('settles Turn 1 pendingTasks when old background step becomes DONE in-place either before Turn 2 beforePrompt or during Turn 2 foreground prompt', async () => {
        for (const completionWindow of ['before-second-beforePrompt', 'during-second-foreground-prompt'] as const) {
            const brainDir = mkdtempSync(join(tmpdir(), `agy-cross-turn-bg-${completionWindow}-`));
            try {
                const logsDir = join(brainDir, 'agy-native', '.system_generated', 'logs');
                mkdirSync(logsDir, { recursive: true });
                const transcriptPath = join(logsDir, 'transcript_full.jsonl');
                const writeSteps = (steps: AgyRawTranscriptStep[]) => {
                    writeFileSync(transcriptPath, `${steps.map((s) => JSON.stringify(s)).join('\n')}\n`, 'utf8');
                };

                const h = harness({ brainDir, pollIntervalMs: 10, quietPeriodMs: 20 });
                const turn2 = deferred<void>();
                void turn2.promise.catch(() => {});

                const { running } = await h.start();
                h.getUpdate()({
                    type: 'tool_call',
                    id: 'call_turn1_bg',
                    name: 'turn1-bg-cmd',
                    title: 'turn1-bg-cmd',
                    kind: 'execute',
                    input: { CommandLine: 'turn1-bg-cmd' },
                    status: 'in_progress'
                });

                const turn1RunningSteps: AgyRawTranscriptStep[] = [
                    { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                    {
                        step_index: 1,
                        source: 'MODEL',
                        type: 'PLANNER_RESPONSE',
                        status: 'DONE',
                        tool_calls: [{ name: 'run_command', args: { CommandLine: 'turn1-bg-cmd', WaitMsBeforeAsync: 500 } }]
                    },
                    {
                        step_index: 2,
                        source: 'MODEL',
                        type: 'GENERIC',
                        status: 'RUNNING',
                        content: 'Tool is running as a background task with task id: agy-native/task-2\n'
                    },
                    { step_index: 3, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'turn1 waiting' }
                ];
                writeSteps(turn1RunningSteps);

                // Prepare Turn 2 prompt mock before queueing Turn 2 so Turn 1 yields to Turn 2
                h.backend.prompt.mockImplementationOnce(async (_id, _content, sink) => {
                    if (completionWindow === 'before-second-beforePrompt') {
                        // Already rewritten before beforePrompt ran (see below)
                    } else {
                        // Window B: task-2 was still RUNNING during Turn 2 beforePrompt(),
                        // and transitions in-place to DONE during Turn 2 foreground execution!
                        writeSteps([
                            turn1RunningSteps[0],
                            turn1RunningSteps[1],
                            {
                                step_index: 2,
                                source: 'MODEL',
                                type: 'GENERIC',
                                status: 'DONE',
                                content: 'Command exited with code 0.\nturn1 bg done in foreground'
                            },
                            turn1RunningSteps[3],
                            { step_index: 4, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'second' },
                            { step_index: 5, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'turn2 answer' }
                        ]);
                    }
                    sink({ type: 'text', text: 'turn2 answer' });
                    await turn2.promise;
                });

                if (completionWindow === 'before-second-beforePrompt') {
                    // Pause resume/load or rewrite right as Turn 1 yields before Turn 2 beforePrompt()
                    h.turn.resolve();
                    await new Promise((r) => setTimeout(r, 25));
                    // Window A: task-2 becomes DONE in-place right BEFORE Turn 2 is queued / beforePrompt() runs,
                    // and Turn 2 is immediately queued before idle watcher drains it!
                    writeSteps([
                        turn1RunningSteps[0],
                        turn1RunningSteps[1],
                        {
                            step_index: 2,
                            source: 'MODEL',
                            type: 'GENERIC',
                            status: 'DONE',
                            content: 'Command exited with code 0.\nturn1 bg done before beforePrompt'
                        },
                        turn1RunningSteps[3],
                        { step_index: 4, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'second' },
                        { step_index: 5, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'turn2 answer' }
                    ]);
                    h.queue.push('second', mode, 'second-id');
                } else {
                    h.queue.push('second', mode, 'second-id');
                    h.turn.resolve();
                }

                await vi.waitFor(() => {
                    expect(h.backend.prompt).toHaveBeenCalledTimes(2);
                });
                h.session.sendSessionEvent.mockClear();
                turn2.resolve();

                await vi.waitFor(() => {
                    expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
                });
                expect(h.session.onThinkingChange).toHaveBeenLastCalledWith(false);

                const toolResults = h.client.sendAgentMessage.mock.calls
                    .map((c) => c[0])
                    .filter((m) => m.type === 'tool-call-result' && m.callId === 'call_turn1_bg');
                expect(toolResults).toHaveLength(1);
                expect(toolResults[0]).toEqual(expect.objectContaining({
                    type: 'tool-call-result',
                    callId: 'call_turn1_bg',
                    is_error: false
                }));
                expect((h.driver as unknown as { reactiveWakeup: AgyReactiveWakeupTracker }).reactiveWakeup.hasPendingTasks()).toBe(false);

                await h.driver.stop();
                await running;
            } finally {
                rmSync(brainDir, { recursive: true, force: true });
            }
        }
    });

    it('exits bounded awaiting-next-planner grace window when a trailing SYSTEM_MESSAGE produces no follow-up planner and detects tool_calls arg-only divergence', async () => {
        const brainDir = mkdtempSync(join(tmpdir(), 'agy-grace-and-arg-diverge-'));
        try {
            const logsDir = join(brainDir, 'agy-native', '.system_generated', 'logs');
            mkdirSync(logsDir, { recursive: true });
            const transcriptPath = join(logsDir, 'transcript_full.jsonl');
            const writeSteps = (steps: AgyRawTranscriptStep[]) => {
                writeFileSync(transcriptPath, `${steps.map((s) => JSON.stringify(s)).join('\n')}\n`, 'utf8');
            };

            const h = harness({ brainDir, pollIntervalMs: 10, quietPeriodMs: 15, nextPlannerGraceMs: 40 });
            const { running } = await h.start();

            // Step 1 is RUNNING while ordinary notification step 2 arrives
            writeSteps([
                { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                { step_index: 1, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'sync' },
                { step_index: 2, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'RUNNING', content: 'streaming...' },
                {
                    step_index: 3,
                    source: 'SYSTEM',
                    type: 'SYSTEM_MESSAGE',
                    status: 'DONE',
                    content: '<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-12T16:00:00Z sender=agy-native/task-9 priority=MESSAGE_PRIORITY_LOW content=canceled\n</SYSTEM_MESSAGE>'
                }
            ]);
            h.turn.resolve();

            await new Promise((r) => setTimeout(r, 25));
            const tracker = (h.driver as unknown as { reactiveWakeup: AgyReactiveWakeupTracker }).reactiveWakeup;
            expect(tracker.getReactiveFlightState(tracker.readSteps('agy-native'))).toBe('active-step');

            // Step 2 finishes in-place as DONE while step 3 remains trailing SYSTEM_MESSAGE with NO follow-up step 4
            writeSteps([
                { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                { step_index: 1, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'sync' },
                { step_index: 2, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'completed reply' },
                {
                    step_index: 3,
                    source: 'SYSTEM',
                    type: 'SYSTEM_MESSAGE',
                    status: 'DONE',
                    content: '<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-12T16:00:00Z sender=agy-native/task-9 priority=MESSAGE_PRIORITY_LOW content=canceled\n</SYSTEM_MESSAGE>'
                }
            ]);

            await vi.waitFor(() => {
                expect(h.session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' });
            });
            expect(tracker.getReactiveFlightState(tracker.readSteps('agy-native'))).toBe('idle');
            expect(h.client.sendAgentMessage).toHaveBeenCalledWith({
                type: 'message',
                message: 'completed reply'
            });

            await h.driver.stop();
            await running;

            // Verify standalone arg-only divergence detection (`CommandLine: old-command -> new-command`)
            const argTracker = new AgyReactiveWakeupTracker({ brainDir });
            writeSteps([
                { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                {
                    step_index: 1,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    created_at: '2026-11-13T00:00:00Z',
                    content: '',
                    tool_calls: [{ name: 'run_command', args: { CommandLine: 'old-command' } }]
                },
                { step_index: 2, source: 'MODEL', type: 'GENERIC', status: 'DONE', content: 'Command exited with code 0.\nold' },
                { step_index: 3, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', content: 'done old' }
            ]);
            argTracker.syncBaseline('agy-native');
            expect(argTracker.hasUnreadReactiveSteps('agy-native')).toBe(false);

            // Rewrite step 1 with identical step_index, type, created_at, content, and tool name — ONLY CommandLine changed!
            writeSteps([
                { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', status: 'DONE', content: 'initial' },
                {
                    step_index: 1,
                    source: 'MODEL',
                    type: 'PLANNER_RESPONSE',
                    status: 'DONE',
                    created_at: '2026-11-13T00:00:00Z',
                    content: '',
                    tool_calls: [{ name: 'run_command', args: { CommandLine: 'new-command' } }]
                }
            ]);
            expect(argTracker.hasUnreadReactiveSteps('agy-native')).toBe(true);
            const argEmitted: AgentMessage[] = [];
            (argTracker as unknown as { processNewReactiveSteps: (s: AgyRawTranscriptStep[], cwd: string, cb: (m: AgentMessage) => void) => boolean })
                .processNewReactiveSteps(argTracker.readSteps('agy-native'), '/tmp', (m) => argEmitted.push(m));
            expect(argEmitted).toContainEqual(expect.objectContaining({
                type: 'tool_call',
                id: 'call_reactive_1_0',
                title: 'new-command'
            }));
        } finally {
            rmSync(brainDir, { recursive: true, force: true });
        }
    });
});
