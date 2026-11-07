import { mkdtempSync, mkdirSync, rmSync, writeFileSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it, expect, vi } from 'vitest';
import { AgyAcpDriver } from './agyAcpDriver';
import { AgyElicitationAdapter } from './agyElicitationAdapter';
import type { AgyReactiveWakeupOptions, AgyRawTranscriptStep } from './agyReactiveWakeup';
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
});
