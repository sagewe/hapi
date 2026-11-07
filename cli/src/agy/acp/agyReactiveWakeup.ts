import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join, relative } from 'node:path';
import { isObject } from '@hapi/protocol';
import type { AcpSdkBackend } from '@/agent/backends/acp';
import type { AgentMessage } from '@/agent/types';
import type { AgyMode } from '../types';
import { configureAgyAcpSession } from './agyAcpBackend';

export interface AgyRawTranscriptStep {
    step_index: number;
    source: string;
    type: string;
    status: string;
    created_at?: string;
    thinking?: string;
    content?: string;
    tool_calls?: Array<{
        name: string;
        args?: Record<string, unknown>;
    }>;
    input_tokens?: number;
    output_tokens?: number;
    cache_read_tokens?: number;
}

interface TrackedToolCall {
    id: string;
    name: string;
    input: unknown;
    title?: string;
    kind?: string;
}

interface PendingBackgroundTask extends TrackedToolCall {
    taskId: string;
    stepIndex: number;
}

interface PendingReactiveToolResult extends TrackedToolCall {
    toolName: string;
    args: Record<string, unknown>;
    isDaemon: boolean;
}

export interface AgyReactiveWakeupOptions {
    brainDir?: string;
    pollIntervalMs?: number;
    quietPeriodMs?: number;
}

const DEFAULT_POLL_INTERVAL_MS = 200;
const DEFAULT_QUIET_PERIOD_MS = 300;

function stripStepTimestamps(content: string | undefined): string {
    if (!content) return '';
    return content
        .replace(/^Created At:\s*[^\n]+\n?/i, '')
        .replace(/^Completed At:\s*[^\n]+\n?/i, '');
}

export function parseAgyCommandOutput(rawText: string | undefined): { output: string; exit_code?: number } {
    const body = stripStepTimestamps(rawText);
    const match = body.match(/^Command exited with code (\d+)\./m);
    const exitCode = match ? Number.parseInt(match[1], 10) : undefined;
    return {
        output: body,
        ...(exitCode !== undefined && Number.isFinite(exitCode) ? { exit_code: exitCode } : {})
    };
}

function extractRunningTaskId(content: string | undefined): string | null {
    if (!content) return null;
    const match = content.match(/Tool is running as a background task with task id:\s*([^\s\n]+)/);
    return match ? match[1] : null;
}

function extractSystemMessageTaskCompletion(content: string | undefined): {
    taskId: string;
    resultText: string;
    cancelled: boolean;
} | null {
    if (!content) return null;
    const finishedMatch = content.match(
        /Task id "([^"]+)" (finished|was canceled) with result:\n([\s\S]*?)(?:\n<\/SYSTEM_MESSAGE>|$)/
    );
    if (finishedMatch) {
        return {
            taskId: finishedMatch[1],
            cancelled: finishedMatch[2] === 'was canceled',
            resultText: finishedMatch[3]
        };
    }
    const senderMatch = content.match(/\[Message\]\s+timestamp=\S+\s+sender=([^\s\n]+)\s+priority=\S+\s+content=([\s\S]*?)(?:\n<\/SYSTEM_MESSAGE>|$)/);
    if (senderMatch && senderMatch[1] !== 'system' && senderMatch[1].includes('/task-')) {
        return {
            taskId: senderMatch[1],
            cancelled: false,
            resultText: senderMatch[2]
        };
    }
    return null;
}

function isServerRestartSystemMessage(content: string | undefined): boolean {
    if (!content) return false;
    return content.includes('All your subagents and background tasks have been stopped due to server restart');
}

function extractManageTaskSettledIds(content: string | undefined): string[] {
    if (!content) return [];
    const settled: string[] = [];
    for (const match of content.matchAll(/Task "([^"]+)" (?:cancelled|already finished)\./g)) {
        settled.push(match[1]);
    }
    const statusMatch = content.match(/Task:\s*([^\s\n]+)[\s\S]*?\nStatus:\s*(DONE|FAILED|KILLED|CANCELLED)\b/i);
    if (statusMatch) {
        settled.push(statusMatch[1]);
    }
    return settled;
}

function isDaemonToolCall(args: Record<string, unknown> | undefined): boolean {
    if (!args) return false;
    if (args.IsDaemon === true || args.IsDaemon === 'true') return true;
    if (typeof args.CronExpression === 'string' && args.CronExpression.trim().length > 0 && args.MaxIterations !== 1) {
        return true;
    }
    return false;
}

function formatReactiveToolCall(
    toolName: string,
    args: Record<string, unknown>,
    cwd: string
): { name: string; title: string; kind: string; input: unknown } {
    if (toolName === 'run_command') {
        const command = typeof args.CommandLine === 'string' && args.CommandLine.trim().length > 0
            ? args.CommandLine
            : 'Run run_command';
        return { name: command, title: command, kind: 'execute', input: args };
    }
    if (toolName === 'read_file') {
        const rawPath = typeof args.Path === 'string' ? args.Path : '';
        const rel = rawPath ? (relative(cwd, rawPath) || basename(rawPath)) : 'file';
        const title = `File ${rel}`;
        return { name: title, title, kind: 'read', input: args };
    }
    if (toolName === 'edit_file' || toolName === 'write_file') {
        const rawPath = typeof args.Path === 'string' ? args.Path : '';
        const rel = rawPath ? (relative(cwd, rawPath) || basename(rawPath)) : 'file';
        const title = `File ${rel}`;
        return { name: title, title, kind: 'edit', input: args };
    }
    if (toolName === 'search_web') {
        const query = typeof args.query === 'string' ? JSON.stringify(args.query) : 'Run search_web';
        return { name: query, title: query, kind: 'search', input: args };
    }
    const title = `Run ${toolName}`;
    return { name: title, title, kind: 'other', input: args };
}

function formatReactiveToolOutput(
    toolName: string,
    content: string | undefined,
    isError: boolean
): unknown {
    if (toolName === 'run_command') {
        return parseAgyCommandOutput(content);
    }
    if (toolName === 'edit_file' || toolName === 'write_file') {
        return isError ? stripStepTimestamps(content) : {};
    }
    return isError ? stripStepTimestamps(content) : undefined;
}

/**
 * Tracks Antigravity background tasks (`run_command`, `schedule`, etc.) and
 * streams post-prompt Reactive Wakeup steps from `transcript_full.jsonl` when
 * `agy acp`'s initial `session/prompt` returns early while background tasks are
 * still `RUNNING`. Once a Reactive Wakeup turn settles, invokes `session/resume`
 * so `agy acp` calls `(*SessionState).SkipHistory(len(steps))` and does not
 * re-emit the reactive steps on the next user prompt.
 */
export class AgyReactiveWakeupTracker {
    private readonly brainDir: string;
    private readonly pollIntervalMs: number;
    private readonly quietPeriodMs: number;

    private syncedStepIndex = -1;
    private prePromptMaxStepIndex = -1;
    private openPromptToolCalls: TrackedToolCall[] = [];
    private readonly pendingTasks = new Map<string, PendingBackgroundTask>();
    private readonly pendingReactiveToolResults = new Map<number, PendingReactiveToolResult>();

    constructor(options: AgyReactiveWakeupOptions = {}) {
        this.brainDir = options.brainDir ?? join(homedir(), '.gemini', 'antigravity-cli', 'brain');
        this.pollIntervalMs = options.pollIntervalMs ?? DEFAULT_POLL_INTERVAL_MS;
        this.quietPeriodMs = options.quietPeriodMs ?? DEFAULT_QUIET_PERIOD_MS;
    }

    reset(): void {
        this.syncedStepIndex = -1;
        this.prePromptMaxStepIndex = -1;
        this.openPromptToolCalls = [];
        this.pendingTasks.clear();
        this.pendingReactiveToolResults.clear();
    }

    getSyncedStepIndex(): number {
        return this.syncedStepIndex;
    }

    getPollIntervalMs(): number {
        return this.pollIntervalMs;
    }

    hasPendingTasks(): boolean {
        return this.pendingTasks.size > 0;
    }

    private resolveTranscriptPath(sessionId: string): string | null {
        const logsDir = join(this.brainDir, sessionId, '.system_generated', 'logs');
        const fullPath = join(logsDir, 'transcript_full.jsonl');
        if (existsSync(fullPath)) return fullPath;
        const compactPath = join(logsDir, 'transcript.jsonl');
        if (existsSync(compactPath)) return compactPath;
        return null;
    }

    readSteps(sessionId: string): AgyRawTranscriptStep[] {
        const path = this.resolveTranscriptPath(sessionId);
        if (!path) return [];
        let raw: string;
        try {
            raw = readFileSync(path, 'utf8');
        } catch {
            return [];
        }
        const steps: AgyRawTranscriptStep[] = [];
        for (const line of raw.split('\n')) {
            const trimmed = line.trim();
            if (!trimmed) continue;
            try {
                const parsed = JSON.parse(trimmed);
                if (isObject(parsed) && typeof parsed.step_index === 'number') {
                    steps.push(parsed as unknown as AgyRawTranscriptStep);
                }
            } catch {
                // Ignore a trailing partially-flushed JSONL line.
            }
        }
        return steps;
    }

    /** Synchronize baseline step index when a session is loaded or created. */
    syncBaseline(sessionId: string): void {
        const steps = this.readSteps(sessionId);
        const maxIdx = steps.length > 0 ? steps[steps.length - 1].step_index : -1;
        if (maxIdx > this.syncedStepIndex) {
            this.syncedStepIndex = maxIdx;
        }
    }

    /** Record transcript baseline before dispatching `backend.prompt()`. */
    beforePrompt(sessionId: string | null): void {
        this.openPromptToolCalls = [];
        if (!sessionId) {
            this.prePromptMaxStepIndex = -1;
            return;
        }
        const steps = this.readSteps(sessionId);
        const maxIdx = steps.length > 0 ? steps[steps.length - 1].step_index : -1;
        this.prePromptMaxStepIndex = maxIdx;
        if (this.syncedStepIndex < maxIdx) {
            this.syncedStepIndex = maxIdx;
        }
    }

    /** Observe `onUpdate` messages emitted during `backend.prompt()` to track open `tool_call` IDs. */
    observePromptUpdate(message: AgentMessage): void {
        if (message.type === 'tool_call') {
            const idx = this.openPromptToolCalls.findIndex((entry) => entry.id === message.id);
            const record: TrackedToolCall = {
                id: message.id,
                name: message.name,
                input: message.input,
                ...(message.title ? { title: message.title } : {}),
                ...(message.kind ? { kind: message.kind } : {})
            };
            if (idx >= 0) {
                this.openPromptToolCalls[idx] = record;
            } else {
                this.openPromptToolCalls.push(record);
            }
        } else if (message.type === 'tool_result') {
            const idx = this.openPromptToolCalls.findIndex((entry) => entry.id === message.id);
            if (idx >= 0) {
                this.openPromptToolCalls.splice(idx, 1);
            }
        }
    }

    /**
     * Checks if new reactive steps have appeared in `transcript_full.jsonl` while
     * the driver is idle between user turns.
     */
    hasUnreadReactiveSteps(sessionId: string | null): boolean {
        if (!sessionId || this.syncedStepIndex < 0) return false;
        const steps = this.readSteps(sessionId);
        if (steps.length === 0) return false;
        const maxIdx = steps[steps.length - 1].step_index;
        return maxIdx > this.syncedStepIndex;
    }

    /**
     * Called immediately after `backend.prompt()` resolves. Inspects steps added
     * during the synchronous turn for `MODEL:GENERIC:RUNNING` background tasks,
     * and if any background task is pending or post-prompt reactive steps exist,
     * streams the Reactive Wakeup turn and syncs `agy acp`'s `SkipHistory`.
     */
    async afterPrompt(params: {
        sessionId: string;
        cwd: string;
        mode: AgyMode;
        backend: AcpSdkBackend;
        onUpdate: (message: AgentMessage) => void;
        shouldYield: () => boolean;
        isAborted: () => boolean;
    }): Promise<void> {
        const { sessionId, cwd, onUpdate } = params;
        const steps = this.readSteps(sessionId);
        if (steps.length === 0) return;

        const promptEndStepIndex = this.findSynchronousPromptEndStepIndex(steps, this.prePromptMaxStepIndex);
        this.ingestSynchronousTurnSteps(steps, this.prePromptMaxStepIndex, promptEndStepIndex, cwd, onUpdate);
        if (promptEndStepIndex > this.syncedStepIndex) {
            this.syncedStepIndex = promptEndStepIndex;
        }

        await this.drainReactiveLoop(params);
    }

    /**
     * Runs when the idle watcher detects new steps in `transcript_full.jsonl`
     * while no user prompt is in flight.
     */
    async afterIdleWakeup(params: {
        sessionId: string;
        cwd: string;
        mode: AgyMode;
        backend: AcpSdkBackend;
        onUpdate: (message: AgentMessage) => void;
        shouldYield: () => boolean;
        isAborted: () => boolean;
    }): Promise<void> {
        await this.drainReactiveLoop(params);
    }

    private findSynchronousPromptEndStepIndex(
        steps: AgyRawTranscriptStep[],
        prePromptMaxStepIndex: number
    ): number {
        let startIndex = -1;
        for (let i = 0; i < steps.length; i++) {
            const step = steps[i];
            if (step.step_index > prePromptMaxStepIndex && step.source === 'USER_EXPLICIT' && step.type === 'USER_INPUT') {
                startIndex = i;
            }
        }
        if (startIndex < 0) {
            startIndex = steps.findIndex((s) => s.step_index > prePromptMaxStepIndex);
            if (startIndex < 0) {
                return steps[steps.length - 1].step_index;
            }
        }

        let lastSyncStepIndex = steps[startIndex].step_index;
        for (let i = startIndex; i < steps.length; i++) {
            const step = steps[i];
            lastSyncStepIndex = step.step_index;
            if (step.source === 'MODEL' && step.type === 'PLANNER_RESPONSE' && step.status === 'DONE') {
                const toolCalls = Array.isArray(step.tool_calls) ? step.tool_calls : [];
                if (toolCalls.length === 0) {
                    return step.step_index;
                }
            } else if (step.source === 'SYSTEM' && step.type === 'ERROR_MESSAGE') {
                return step.step_index;
            }
        }
        return lastSyncStepIndex;
    }

    private ingestSynchronousTurnSteps(
        steps: AgyRawTranscriptStep[],
        prePromptMaxStepIndex: number,
        promptEndStepIndex: number,
        cwd: string,
        onUpdate: (message: AgentMessage) => void
    ): void {
        const byStepIndex = new Map<number, AgyRawTranscriptStep>();
        for (const step of steps) {
            byStepIndex.set(step.step_index, step);
        }

        // Map each GENERIC step in the synchronous turn back to its tool_call in the preceding PLANNER_RESPONSE.
        const toolCallMetaByStep = new Map<number, { toolName: string; args: Record<string, unknown> }>();
        for (const step of steps) {
            if (step.step_index <= prePromptMaxStepIndex || step.step_index > promptEndStepIndex) continue;
            if (step.source === 'MODEL' && step.type === 'PLANNER_RESPONSE' && Array.isArray(step.tool_calls)) {
                step.tool_calls.forEach((tc, offset) => {
                    toolCallMetaByStep.set(step.step_index + 1 + offset, {
                        toolName: tc.name,
                        args: isObject(tc.args) ? tc.args : {}
                    });
                });
            }
        }

        for (const step of steps) {
            if (step.step_index <= prePromptMaxStepIndex || step.step_index > promptEndStepIndex) continue;

            if (step.source === 'MODEL' && step.type === 'GENERIC' && step.status === 'RUNNING') {
                const taskId = extractRunningTaskId(step.content);
                if (!taskId) continue;
                const meta = toolCallMetaByStep.get(step.step_index) ?? {
                    toolName: 'run_command',
                    args: {}
                };
                if (isDaemonToolCall(meta.args)) continue;

                const matchedOpenCall = this.takeMatchingOpenPromptToolCall(meta.toolName, meta.args);
                const fallbackFormatted = formatReactiveToolCall(meta.toolName, meta.args, cwd);
                const tracked: PendingBackgroundTask = {
                    taskId,
                    stepIndex: step.step_index,
                    id: matchedOpenCall?.id ?? `call_reactive_${step.step_index}`,
                    name: matchedOpenCall?.name ?? fallbackFormatted.name,
                    input: matchedOpenCall?.input ?? fallbackFormatted.input,
                    ...(matchedOpenCall?.title ? { title: matchedOpenCall.title } : { title: fallbackFormatted.title }),
                    ...(matchedOpenCall?.kind ? { kind: matchedOpenCall.kind } : { kind: fallbackFormatted.kind })
                };
                this.pendingTasks.set(taskId, tracked);
            } else if (step.source === 'SYSTEM' && step.type === 'SYSTEM_MESSAGE') {
                this.handleSystemMessageStep(step, onUpdate);
            } else if (step.source === 'MODEL' && step.type === 'GENERIC' && step.status === 'DONE') {
                this.handleManageTaskSettlement(step.content, onUpdate);
            }
        }
    }

    private takeMatchingOpenPromptToolCall(
        toolName: string,
        args: Record<string, unknown>
    ): TrackedToolCall | null {
        if (this.openPromptToolCalls.length === 0) return null;
        if (toolName === 'run_command' && typeof args.CommandLine === 'string') {
            const idx = this.openPromptToolCalls.findIndex(
                (c) => isObject(c.input) && c.input.CommandLine === args.CommandLine
            );
            if (idx >= 0) {
                return this.openPromptToolCalls.splice(idx, 1)[0];
            }
        }
        if (toolName === 'schedule' && typeof args.Prompt === 'string') {
            const idx = this.openPromptToolCalls.findIndex(
                (c) => isObject(c.input) && c.input.Prompt === args.Prompt
            );
            if (idx >= 0) {
                return this.openPromptToolCalls.splice(idx, 1)[0];
            }
        }
        return this.openPromptToolCalls.shift() ?? null;
    }

    private handleSystemMessageStep(
        step: AgyRawTranscriptStep,
        onUpdate: (message: AgentMessage) => void
    ): void {
        if (isServerRestartSystemMessage(step.content)) {
            this.pendingTasks.clear();
            return;
        }
        const completion = extractSystemMessageTaskCompletion(step.content);
        if (!completion) return;
        const pending = this.pendingTasks.get(completion.taskId);
        if (!pending) return;
        this.pendingTasks.delete(completion.taskId);

        const status = completion.cancelled ? 'failed' : 'completed';
        const output = pending.kind === 'execute'
            ? parseAgyCommandOutput(completion.resultText)
            : (completion.cancelled ? stripStepTimestamps(completion.resultText) : undefined);

        onUpdate({
            type: 'tool_call',
            id: pending.id,
            name: pending.name,
            input: pending.input,
            status,
            ...(pending.title ? { title: pending.title } : {}),
            ...(pending.kind ? { kind: pending.kind } : {})
        });
        onUpdate({
            type: 'tool_result',
            id: pending.id,
            output,
            status
        });
    }

    private handleManageTaskSettlement(
        content: string | undefined,
        onUpdate: (message: AgentMessage) => void
    ): void {
        for (const taskId of extractManageTaskSettledIds(content)) {
            const pending = this.pendingTasks.get(taskId);
            if (!pending) continue;
            this.pendingTasks.delete(taskId);
            onUpdate({
                type: 'tool_call',
                id: pending.id,
                name: pending.name,
                input: pending.input,
                status: 'completed',
                ...(pending.title ? { title: pending.title } : {}),
                ...(pending.kind ? { kind: pending.kind } : {})
            });
            onUpdate({
                type: 'tool_result',
                id: pending.id,
                output: { output: stripStepTimestamps(content) },
                status: 'completed'
            });
        }
    }

    private processNewReactiveSteps(
        steps: AgyRawTranscriptStep[],
        cwd: string,
        onUpdate: (message: AgentMessage) => void
    ): boolean {
        let emittedOrAdvanced = false;
        for (const step of steps) {
            if (step.step_index <= this.syncedStepIndex) continue;

            if (step.source === 'SYSTEM' && step.type === 'SYSTEM_MESSAGE') {
                this.handleSystemMessageStep(step, onUpdate);
                this.syncedStepIndex = step.step_index;
                emittedOrAdvanced = true;
                continue;
            }

            if (step.source === 'MODEL' && step.type === 'PLANNER_RESPONSE' && step.status === 'DONE') {
                if (typeof step.thinking === 'string' && step.thinking.trim().length > 0) {
                    onUpdate({ type: 'reasoning', text: step.thinking });
                }
                if (typeof step.content === 'string' && step.content.length > 0) {
                    onUpdate({ type: 'text', text: step.content });
                }
                const toolCalls = Array.isArray(step.tool_calls) ? step.tool_calls : [];
                toolCalls.forEach((tc, offset) => {
                    const args = isObject(tc.args) ? tc.args : {};
                    const formatted = formatReactiveToolCall(tc.name, args, cwd);
                    const callId = `call_reactive_${step.step_index}_${offset}`;
                    const resultStepIndex = step.step_index + 1 + offset;
                    this.pendingReactiveToolResults.set(resultStepIndex, {
                        id: callId,
                        toolName: tc.name,
                        args,
                        name: formatted.name,
                        input: formatted.input,
                        title: formatted.title,
                        kind: formatted.kind,
                        isDaemon: isDaemonToolCall(args)
                    });
                    onUpdate({
                        type: 'tool_call',
                        id: callId,
                        name: formatted.name,
                        input: formatted.input,
                        status: 'in_progress',
                        title: formatted.title,
                        kind: formatted.kind
                    });
                });
                if (typeof step.input_tokens === 'number' || typeof step.output_tokens === 'number') {
                    onUpdate({
                        type: 'usage',
                        inputTokens: step.input_tokens ?? 0,
                        outputTokens: step.output_tokens ?? 0,
                        ...(typeof step.cache_read_tokens === 'number'
                            ? { cacheReadTokens: step.cache_read_tokens }
                            : {})
                    });
                }
                this.syncedStepIndex = step.step_index;
                emittedOrAdvanced = true;
                continue;
            }

            if (step.source === 'MODEL' && step.type === 'GENERIC') {
                const meta = this.pendingReactiveToolResults.get(step.step_index) ?? {
                    id: `call_reactive_${step.step_index}`,
                    toolName: 'run_command',
                    args: {},
                    name: 'Run tool',
                    input: {},
                    title: 'Run tool',
                    kind: 'other',
                    isDaemon: false
                };

                if (step.status === 'DONE') {
                    this.handleManageTaskSettlement(step.content, onUpdate);
                }

                if (step.status === 'RUNNING') {
                    const taskId = extractRunningTaskId(step.content);
                    if (taskId && !meta.isDaemon) {
                        this.pendingTasks.set(taskId, {
                            taskId,
                            stepIndex: step.step_index,
                            id: meta.id,
                            name: meta.name,
                            input: meta.input,
                            title: meta.title,
                            kind: meta.kind
                        });
                    }
                    this.pendingReactiveToolResults.delete(step.step_index);
                    this.syncedStepIndex = step.step_index;
                    emittedOrAdvanced = true;
                    continue;
                }

                if (step.status === 'DONE' || step.status === 'ERROR') {
                    const isError = step.status === 'ERROR';
                    const status = isError ? 'failed' : 'completed';
                    const output = formatReactiveToolOutput(meta.toolName, step.content, isError);
                    onUpdate({
                        type: 'tool_call',
                        id: meta.id,
                        name: meta.name,
                        input: meta.input,
                        status,
                        ...(meta.title ? { title: meta.title } : {}),
                        ...(meta.kind ? { kind: meta.kind } : {})
                    });
                    onUpdate({
                        type: 'tool_result',
                        id: meta.id,
                        output,
                        status
                    });
                    this.pendingReactiveToolResults.delete(step.step_index);
                    this.syncedStepIndex = step.step_index;
                    emittedOrAdvanced = true;
                    continue;
                }
            }

            this.syncedStepIndex = step.step_index;
            emittedOrAdvanced = true;
        }
        return emittedOrAdvanced;
    }

    private isReactiveTurnMidFlight(steps: AgyRawTranscriptStep[]): boolean {
        if (this.pendingReactiveToolResults.size > 0) return true;
        if (steps.length === 0) return false;
        const last = steps[steps.length - 1];
        if (last.source === 'SYSTEM' && last.type === 'SYSTEM_MESSAGE') {
            return true;
        }
        if (last.source === 'MODEL' && last.type === 'PLANNER_RESPONSE') {
            const toolCalls = Array.isArray(last.tool_calls) ? last.tool_calls : [];
            if (toolCalls.length > 0) return true;
        }
        if (last.source === 'MODEL' && last.type === 'GENERIC') {
            return true;
        }
        return false;
    }

    private async drainReactiveLoop(params: {
        sessionId: string;
        cwd: string;
        mode: AgyMode;
        backend: AcpSdkBackend;
        onUpdate: (message: AgentMessage) => void;
        shouldYield: () => boolean;
        isAborted: () => boolean;
    }): Promise<void> {
        const { sessionId, cwd, mode, backend, onUpdate, shouldYield, isAborted } = params;
        let needsSessionResumeSync = false;
        let lastActivityAt = Date.now();

        while (!isAborted()) {
            const steps = this.readSteps(sessionId);
            const advanced = this.processNewReactiveSteps(steps, cwd, onUpdate);
            if (advanced) {
                needsSessionResumeSync = true;
                lastActivityAt = Date.now();
            }

            const midFlight = this.isReactiveTurnMidFlight(steps);
            const withinQuietWindow = needsSessionResumeSync && (Date.now() - lastActivityAt < this.quietPeriodMs);

            if (!midFlight && !withinQuietWindow) {
                if (this.pendingTasks.size === 0 || shouldYield()) {
                    break;
                }
            }

            await new Promise<void>((resolve) => {
                const timer = setTimeout(resolve, this.pollIntervalMs);
                timer.unref?.();
            });
        }

        if (needsSessionResumeSync && !isAborted()) {
            await this.syncBackendHistorySkip(backend, sessionId, cwd, mode);
        }
    }

    private async syncBackendHistorySkip(
        backend: AcpSdkBackend,
        sessionId: string,
        cwd: string,
        mode: AgyMode
    ): Promise<void> {
        const backendWithResume = backend as unknown as {
            resumeSession?: (config: { cwd: string; mcpServers: never[]; sessionId: string }) => Promise<string>;
            suppressUpdatesDuring?: <T>(fn: () => Promise<T>) => Promise<T>;
            refreshSessionInfo?: (sessionId: string, cwd: string) => Promise<void>;
        };
        if (typeof backendWithResume.resumeSession !== 'function') {
            return;
        }
        const runResume = async () => {
            await backendWithResume.resumeSession!({ cwd, mcpServers: [], sessionId });
            await configureAgyAcpSession(backend, sessionId, mode);
        };
        if (typeof backendWithResume.suppressUpdatesDuring === 'function') {
            await backendWithResume.suppressUpdatesDuring(runResume);
        } else {
            await runResume();
        }
        void backendWithResume.refreshSessionInfo?.(sessionId, cwd);
    }
}
