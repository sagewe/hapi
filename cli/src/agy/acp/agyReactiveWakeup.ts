import { existsSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join, relative } from 'node:path';
import { isObject } from '@hapi/protocol';
import type { AcpSdkBackend } from '@/agent/backends/acp';
import type { AgentMessage } from '@/agent/types';
import { logger } from '@/ui/logger';
import { deterministicStringify } from '@/utils/deterministicJson';
import type { AgyMode } from '../types';
import { configureAgyAcpSession } from './agyAcpBackend';

export class AgyReactiveContinuationPendingError extends Error {
    constructor() {
        super('Antigravity background continuation has not settled; message was not sent. Wait for completion or stop it before sending again.');
    }
}

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
    toolName: string;
}

interface RecordedStepSignature {
    source: string;
    type: string;
    createdAt: string;
    terminalSignature: string | null;
}

interface PendingReactiveToolResult extends TrackedToolCall {
    plannerStepIndex: number;
    expectedStepIndex: number;
    toolName: string;
    args: Record<string, unknown>;
    isDaemon: boolean;
    /** `ask_question` pauses for user input without writing a synchronous `GENERIC` step. */
    blocking: boolean;
}

interface CachedTranscriptSnapshot {
    sessionId: string;
    path: string;
    ino: bigint;
    size: bigint;
    mtimeNs: bigint;
    ctimeNs: bigint;
    genesisKey: string | null;
    steps: AgyRawTranscriptStep[];
}

export type AgyReactiveFlightState =
    | 'idle'
    | 'pending-tool-result'
    | 'active-step'
    | 'awaiting-next-planner';

export interface AgyReactiveWakeupOptions {
    brainDir?: string;
    pollIntervalMs?: number;
    quietPeriodMs?: number;
    nextPlannerGraceMs?: number;
    maxDrainMs?: number;
}

const DEFAULT_POLL_INTERVAL_MS = 200;
const DEFAULT_QUIET_PERIOD_MS = 300;
const DEFAULT_NEXT_PLANNER_GRACE_MS = 5_000;

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
 * True only for steps that genuinely advance or interrupt the single-threaded
 * planner batch. Ordinary `SYSTEM_MESSAGE` background-task notifications are
 * asynchronous inbox deliveries and do NOT interrupt an in-flight `RUNNING`
 * tool or planner step.
 */
function isBatchInterruptingBoundaryStep(step: AgyRawTranscriptStep): boolean {
    if (step.source === 'MODEL' && step.type === 'PLANNER_RESPONSE') return true;
    if (step.source === 'SYSTEM' && step.type === 'ERROR_MESSAGE') return true;
    if (step.source === 'SYSTEM' && step.type === 'SYSTEM_MESSAGE' && isServerRestartSystemMessage(step.content)) {
        return true;
    }
    if (step.source === 'USER_EXPLICIT' && step.type === 'USER_INPUT') return true;
    return false;
}

function isTerminalStepStatus(status: string): boolean {
    return status === 'DONE' || status === 'ERROR' || status === 'CANCELLED' || status === 'FAILED';
}

function buildGenesisKey(steps: AgyRawTranscriptStep[]): string | null {
    if (steps.length === 0) return null;
    const first = steps[0];
    const normalizedTools = Array.isArray(first.tool_calls) && first.tool_calls.length > 0
        ? deterministicStringify(first.tool_calls)
        : '';
    return `${first.step_index}:${first.source}:${first.type}:${first.created_at ?? ''}:${normalizedTools}:${(first.content ?? '').slice(0, 96)}`;
}

function computeTerminalStepSignature(step: AgyRawTranscriptStep): string | null {
    if (!isTerminalStepStatus(step.status)) return null;
    const normalizedToolCalls = Array.isArray(step.tool_calls) && step.tool_calls.length > 0
        ? deterministicStringify(step.tool_calls)
        : '';
    return `${step.source}\0${step.type}\0${step.created_at ?? ''}\0${step.status}\0${normalizedToolCalls}\0${step.content ?? ''}`;
}

export interface NormalizedTranscriptGeneration {
    steps: AgyRawTranscriptStep[];
    generationIndex: number;
    generationGenesisKeys: Array<string | null>;
}

function isTrajectoryRollbackAtExistingStep(
    existing: AgyRawTranscriptStep,
    incoming: AgyRawTranscriptStep,
    maxStepIndexSoFar: number
): boolean {
    // A new step_index=0 appearing after the trajectory already advanced past 0
    // (e.g. Antigravity appending a compacted/reset 0..N trajectory without
    // truncating transcript_full.jsonl) starts a new trajectory generation.
    if (incoming.step_index === 0 && maxStepIndexSoFar > 0) {
        return true;
    }
    if (existing.source !== incoming.source || existing.type !== incoming.type) {
        return true;
    }
    const existingCreatedAt = existing.created_at ?? '';
    const incomingCreatedAt = incoming.created_at ?? '';
    if (incoming.step_index === 0 && existingCreatedAt && incomingCreatedAt && existingCreatedAt !== incomingCreatedAt) {
        return true;
    }
    if (isTerminalStepStatus(existing.status)) {
        if (existingCreatedAt && incomingCreatedAt && existingCreatedAt !== incomingCreatedAt) {
            return true;
        }
        if (isTerminalStepStatus(incoming.status)) {
            return computeTerminalStepSignature(existing) !== computeTerminalStepSignature(incoming);
        }
        return true;
    }
    // `existing` was non-terminal (`RUNNING` / etc.) with the same `source` and `type`:
    // fold `incoming` in-place without truncating higher `step_index` sibling steps.
    return false;
}

/**
 * Normalizes raw JSONL lines from `transcript_full.jsonl` into the single active
 * trajectory generation with unique, strictly ascending `step_index` entries:
 * - Appended full resets (`step_index === 0` after `0..K`) advance `generationIndex`
 *   and discard superseded prior-generation lines.
 * - Appended mid-trajectory rollbacks (`step_index === M` replacing an incompatible
 *   or terminal `M..K` tail) supersede `>= M` while preserving `0..M-1`.
 * - Appended in-place updates / duplicate flushes of the same step replace only `M`.
 */
export function normalizeRawTranscriptSteps(rawSteps: AgyRawTranscriptStep[]): NormalizedTranscriptGeneration {
    if (rawSteps.length === 0) {
        return { steps: [], generationIndex: 0, generationGenesisKeys: [] };
    }

    const byIndex = new Map<number, AgyRawTranscriptStep>();
    let maxStepIndexSoFar = -1;
    let generationIndex = 0;
    const priorGenerationGenesisKeys: Array<string | null> = [];

    const snapshotCurrentGenesisKey = (): string | null => {
        if (byIndex.size === 0) return null;
        let minIdx = Infinity;
        for (const k of byIndex.keys()) {
            if (k < minIdx) minIdx = k;
        }
        const first = byIndex.get(minIdx);
        return first ? buildGenesisKey([first]) : null;
    };

    for (const step of rawSteps) {
        const existing = byIndex.get(step.step_index);
        if (existing !== undefined) {
            if (isTrajectoryRollbackAtExistingStep(existing, step, maxStepIndexSoFar)) {
                if (step.step_index === 0) {
                    priorGenerationGenesisKeys.push(snapshotCurrentGenesisKey());
                    generationIndex += 1;
                    byIndex.clear();
                    maxStepIndexSoFar = -1;
                } else {
                    for (const k of [...byIndex.keys()]) {
                        if (k >= step.step_index) {
                            byIndex.delete(k);
                        }
                    }
                    let nextMax = -1;
                    for (const k of byIndex.keys()) {
                        if (k > nextMax) nextMax = k;
                    }
                    maxStepIndexSoFar = nextMax;
                }
            }
        } else if (step.step_index === 0 && byIndex.size > 0 && maxStepIndexSoFar > 0) {
            priorGenerationGenesisKeys.push(snapshotCurrentGenesisKey());
            generationIndex += 1;
            byIndex.clear();
            maxStepIndexSoFar = -1;
        }

        byIndex.set(step.step_index, step);
        if (step.step_index > maxStepIndexSoFar) {
            maxStepIndexSoFar = step.step_index;
        }
    }

    const steps = [...byIndex.entries()]
        .sort((a, b) => a[0] - b[0])
        .map(([, s]) => s);
    const currentGenesisKey = buildGenesisKey(steps);
    return {
        steps,
        generationIndex,
        generationGenesisKeys: [...priorGenerationGenesisKeys, currentGenesisKey]
    };
}

function doesStepDivergeFromRecorded(step: AgyRawTranscriptStep, recorded: RecordedStepSignature): boolean {
    if (recorded.source !== step.source || recorded.type !== step.type) {
        return true;
    }
    const stepCreatedAt = step.created_at ?? '';
    if (recorded.createdAt && stepCreatedAt && recorded.createdAt !== stepCreatedAt) {
        return true;
    }
    if (recorded.terminalSignature !== null) {
        return computeTerminalStepSignature(step) !== recorded.terminalSignature;
    }
    return false;
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
    private readonly nextPlannerGraceMs: number;
    private readonly maxDrainMs: number;
    private lastDrainedSnapshot: AgyRawTranscriptStep[] | null = null;
    private promptText = '';

    private trackedSessionId: string | null = null;
    private trackedGenesisKey: string | null = null;
    private trackedGenerationIndex = 0;
    private trackedGenerationGenesisKeys: Array<string | null> = [];
    private baselineInitialized = false;
    private syncedStepIndex = -1;
    private prePromptMaxStepIndex = -1;
    private promptEndStepIndex = -1;
    private maxRecordedStepIndex = -1;
    private pendingResumeSync = false;
    private trailingPlannerHandoff: { stepIndex: number; since: number } | null = null;
    private transcriptCache: CachedTranscriptSnapshot | null = null;
    private promptToolCalls: TrackedToolCall[] = [];
    private readonly settledPromptCallIds = new Set<string>();
    private readonly stepSignatures = new Map<number, RecordedStepSignature>();
    private readonly processedReactiveStepStatus = new Map<number, string>();
    private readonly reactiveToolMetaByStep = new Map<number, PendingReactiveToolResult>();
    private readonly settledToolStepIndices = new Set<number>();
    private readonly backgroundTaskIdByStep = new Map<number, string>();
    private readonly pendingTasks = new Map<string, PendingBackgroundTask>();
    private readonly pendingReactiveToolResults = new Map<number, PendingReactiveToolResult>();

    constructor(options: AgyReactiveWakeupOptions = {}) {
        this.brainDir = options.brainDir ?? join(homedir(), '.gemini', 'antigravity-cli', 'brain');
        this.pollIntervalMs = options.pollIntervalMs ?? DEFAULT_POLL_INTERVAL_MS;
        this.quietPeriodMs = options.quietPeriodMs ?? DEFAULT_QUIET_PERIOD_MS;
        this.nextPlannerGraceMs = options.nextPlannerGraceMs ?? DEFAULT_NEXT_PLANNER_GRACE_MS;
        this.maxDrainMs = options.maxDrainMs ?? 5_000;
    }

    reset(): void {
        this.lastDrainedSnapshot = null;
        this.promptText = '';
        this.trackedSessionId = null;
        this.trackedGenesisKey = null;
        this.trackedGenerationIndex = 0;
        this.trackedGenerationGenesisKeys = [];
        this.baselineInitialized = false;
        this.syncedStepIndex = -1;
        this.prePromptMaxStepIndex = -1;
        this.promptEndStepIndex = -1;
        this.maxRecordedStepIndex = -1;
        this.pendingResumeSync = false;
        this.trailingPlannerHandoff = null;
        this.transcriptCache = null;
        this.promptToolCalls = [];
        this.settledPromptCallIds.clear();
        this.stepSignatures.clear();
        this.processedReactiveStepStatus.clear();
        this.reactiveToolMetaByStep.clear();
        this.settledToolStepIndices.clear();
        this.backgroundTaskIdByStep.clear();
        this.pendingTasks.clear();
        this.pendingReactiveToolResults.clear();
    }

    private resetForNewTranscriptGeneration(
        sessionId: string,
        genesisKey: string | null,
        generationIndex = 0,
        generationGenesisKeys: Array<string | null> = genesisKey !== null ? [genesisKey] : []
    ): void {
        this.lastDrainedSnapshot = null;
        this.trackedSessionId = sessionId;
        this.trackedGenesisKey = genesisKey;
        this.trackedGenerationIndex = generationIndex;
        this.trackedGenerationGenesisKeys = [...generationGenesisKeys];
        this.syncedStepIndex = -1;
        this.prePromptMaxStepIndex = -1;
        this.promptEndStepIndex = -1;
        this.maxRecordedStepIndex = -1;
        this.trailingPlannerHandoff = null;
        this.stepSignatures.clear();
        this.processedReactiveStepStatus.clear();
        this.reactiveToolMetaByStep.clear();
        this.settledToolStepIndices.clear();
        this.backgroundTaskIdByStep.clear();
        this.pendingTasks.clear();
        this.pendingReactiveToolResults.clear();
    }

    private isTornEarlierGenerationPrefix(
        generationIndex: number,
        generationGenesisKeys: ReadonlyArray<string | null>
    ): boolean {
        if (this.trackedGenerationIndex <= 0 || generationIndex >= this.trackedGenerationIndex) {
            return false;
        }
        if (generationGenesisKeys.length === 0 || generationGenesisKeys.length > this.trackedGenerationGenesisKeys.length) {
            return false;
        }
        for (let i = 0; i < generationGenesisKeys.length; i++) {
            if (generationGenesisKeys[i] !== this.trackedGenerationGenesisKeys[i]) {
                return false;
            }
        }
        return true;
    }

    private reconcileDivergentBranchFrom(
        sessionId: string,
        genesisKey: string | null,
        generationIndex: number,
        generationGenesisKeys: Array<string | null>,
        divergentStepIndex: number
    ): void {
        if (divergentStepIndex <= 0) {
            this.resetForNewTranscriptGeneration(sessionId, genesisKey, generationIndex, generationGenesisKeys);
            return;
        }
        this.trackedGenesisKey = genesisKey;
        this.trackedGenerationIndex = generationIndex;
        this.trackedGenerationGenesisKeys = [...generationGenesisKeys];
        this.trailingPlannerHandoff = null;
        const clampedFloor = divergentStepIndex - 1;
        if (this.promptEndStepIndex >= divergentStepIndex) {
            this.promptEndStepIndex = clampedFloor;
        }
        if (this.prePromptMaxStepIndex >= divergentStepIndex) {
            this.prePromptMaxStepIndex = clampedFloor;
        }
        if (this.syncedStepIndex >= divergentStepIndex) {
            this.syncedStepIndex = clampedFloor;
        }
        for (const idx of [...this.stepSignatures.keys()]) {
            if (idx >= divergentStepIndex) this.stepSignatures.delete(idx);
        }
        for (const idx of [...this.processedReactiveStepStatus.keys()]) {
            if (idx >= divergentStepIndex) this.processedReactiveStepStatus.delete(idx);
        }
        for (const idx of [...this.reactiveToolMetaByStep.keys()]) {
            if (idx >= divergentStepIndex) this.reactiveToolMetaByStep.delete(idx);
        }
        for (const idx of [...this.settledToolStepIndices]) {
            if (idx >= divergentStepIndex) this.settledToolStepIndices.delete(idx);
        }
        for (const idx of [...this.pendingReactiveToolResults.keys()]) {
            if (idx >= divergentStepIndex) this.pendingReactiveToolResults.delete(idx);
        }
        for (const [idx, taskId] of [...this.backgroundTaskIdByStep.entries()]) {
            if (idx >= divergentStepIndex) {
                this.backgroundTaskIdByStep.delete(idx);
                this.pendingTasks.delete(taskId);
            }
        }
        let nextMaxRecorded = -1;
        for (const idx of this.stepSignatures.keys()) {
            if (idx > nextMaxRecorded) nextMaxRecorded = idx;
        }
        this.maxRecordedStepIndex = nextMaxRecorded;
    }

    private findDivergentStepIndex(steps: AgyRawTranscriptStep[]): number | null {
        if (steps.length === 0) return null;
        const maxIdx = steps[steps.length - 1].step_index;
        for (const step of steps) {
            const recorded = this.stepSignatures.get(step.step_index);
            if (recorded !== undefined) {
                if (doesStepDivergeFromRecorded(step, recorded)) {
                    return step.step_index;
                }
            } else if (maxIdx < this.maxRecordedStepIndex && step.step_index < this.maxRecordedStepIndex) {
                return step.step_index;
            }
        }
        return null;
    }

    private recordStepSignatures(steps: AgyRawTranscriptStep[]): void {
        for (const step of steps) {
            this.stepSignatures.set(step.step_index, {
                source: step.source,
                type: step.type,
                createdAt: step.created_at ?? '',
                terminalSignature: computeTerminalStepSignature(step)
            });
            if (step.step_index > this.maxRecordedStepIndex) {
                this.maxRecordedStepIndex = step.step_index;
            }
        }
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

    needsResumeSync(): boolean {
        return this.pendingResumeSync;
    }

    private hasBlockingPendingReactiveToolResults(): boolean {
        for (const pending of this.pendingReactiveToolResults.values()) {
            if (pending.blocking) return true;
        }
        return false;
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
        if (this.trackedSessionId !== null && this.trackedSessionId !== sessionId) {
            this.reset();
        }
        this.trackedSessionId = sessionId;

        const path = this.resolveTranscriptPath(sessionId);
        if (!path) {
            if (this.transcriptCache?.sessionId === sessionId) {
                this.transcriptCache = null;
            }
            return [];
        }

        let stat: ReturnType<typeof statSync>;
        try {
            stat = statSync(path, { bigint: true });
        } catch {
            return [];
        }

        const cached = this.transcriptCache;
        if (
            cached
            && cached.sessionId === sessionId
            && cached.path === path
            && cached.ino === stat.ino
            && cached.size === stat.size
            && cached.mtimeNs === stat.mtimeNs
            && cached.ctimeNs === stat.ctimeNs
        ) {
            return cached.steps;
        }

        let raw: string;
        try {
            raw = readFileSync(path, 'utf8');
        } catch {
            return cached?.sessionId === sessionId ? cached.steps : [];
        }

        const rawSteps: AgyRawTranscriptStep[] = [];
        let sawMalformedLine = false;
        for (const line of raw.split('\n')) {
            const trimmed = line.trim();
            if (!trimmed) continue;
            try {
                const parsed = JSON.parse(trimmed);
                if (isObject(parsed) && typeof parsed.step_index === 'number') {
                    rawSteps.push(parsed as unknown as AgyRawTranscriptStep);
                }
            } catch {
                // Partially-flushed JSONL line during concurrent write/rewrite.
                sawMalformedLine = true;
            }
        }

        const { steps, generationIndex, generationGenesisKeys } = normalizeRawTranscriptSteps(rawSteps);
        const genesisKey = buildGenesisKey(steps);

        if (sawMalformedLine) {
            // Never roll back deduplication state or cache a torn snapshot.
            if (this.isTornEarlierGenerationPrefix(generationIndex, generationGenesisKeys)) {
                return cached && cached.sessionId === sessionId ? cached.steps : steps;
            }
            // If this partial read caught a rewrite mid-flight with fewer steps than
            // the last complete snapshot and no divergence, keep the last complete
            // snapshot until the writer finishes flushing.
            if (
                cached
                && cached.sessionId === sessionId
                && generationIndex === this.trackedGenerationIndex
                && steps.length < cached.steps.length
                && this.findDivergentStepIndex(steps) === null
            ) {
                return cached.steps;
            }
            return steps;
        }

        if (steps.length === 0) {
            if (cached && cached.sessionId === sessionId && cached.steps.length > 0) {
                // Momentary 0-byte window during O_TRUNC rewrite: preserve deduplication
                // state and skip caching until new content is flushed.
                return cached.steps;
            }
        } else {
            if (this.isTornEarlierGenerationPrefix(generationIndex, generationGenesisKeys)) {
                // Non-atomic multi-generation rewrite caught after flushing only an
                // already-retired earlier generation: preserve active-generation state.
                return cached && cached.sessionId === sessionId && cached.steps.length > 0
                    ? cached.steps
                    : steps;
            }
            const maxIdx = steps[steps.length - 1].step_index;
            if (this.trackedGenesisKey === null) {
                this.trackedGenesisKey = genesisKey;
                this.trackedGenerationIndex = generationIndex;
                this.trackedGenerationGenesisKeys = [...generationGenesisKeys];
            } else if (generationIndex > this.trackedGenerationIndex) {
                this.resetForNewTranscriptGeneration(sessionId, genesisKey, generationIndex, generationGenesisKeys);
            } else {
                const divergentStepIndex = this.findDivergentStepIndex(steps);
                if (divergentStepIndex !== null) {
                    this.reconcileDivergentBranchFrom(
                        sessionId,
                        genesisKey,
                        generationIndex,
                        generationGenesisKeys,
                        divergentStepIndex
                    );
                } else if (this.trackedGenesisKey !== genesisKey || generationIndex !== this.trackedGenerationIndex) {
                    this.resetForNewTranscriptGeneration(sessionId, genesisKey, generationIndex, generationGenesisKeys);
                } else if (maxIdx < this.maxRecordedStepIndex) {
                    // Pure prefix of the recorded trajectory caught momentarily shorter
                    // during a non-atomic rewrite: preserve processedReactiveStepStatus
                    // and skip caching so the next poll reads the completed rewrite.
                    return cached && cached.sessionId === sessionId && cached.steps.length > steps.length
                        ? cached.steps
                        : steps;
                }
            }
            this.trackedGenerationIndex = generationIndex;
            this.trackedGenerationGenesisKeys = [...generationGenesisKeys];
            this.recordStepSignatures(steps);
        }

        this.transcriptCache = {
            sessionId,
            path,
            ino: stat.ino,
            size: stat.size,
            mtimeNs: stat.mtimeNs,
            ctimeNs: stat.ctimeNs,
            genesisKey,
            steps
        };
        return steps;
    }

    private advanceSyncedCursor(stepIndex: number): void {
        if (stepIndex > this.syncedStepIndex) {
            this.syncedStepIndex = stepIndex;
        }
    }

    private hasUnsettledPendingBackgroundTaskAtStep(stepIndex: number): boolean {
        const bgTaskId = this.backgroundTaskIdByStep.get(stepIndex);
        return bgTaskId !== undefined && this.pendingTasks.has(bgTaskId);
    }

    private recordBaselineStepStatuses(steps: AgyRawTranscriptStep[], maxStepIndex: number): void {
        for (const step of steps) {
            if (step.step_index > maxStepIndex) continue;
            // Do not overwrite a tracked background task's status with terminal
            // before `processNewReactiveSteps` settles `pendingTasks` and emits
            // its `tool_result`.
            if (this.hasUnsettledPendingBackgroundTaskAtStep(step.step_index) && isTerminalStepStatus(step.status)) {
                continue;
            }
            this.processedReactiveStepStatus.set(step.step_index, step.status);
        }
    }

    /** Synchronize baseline step index when a session is loaded or created. */
    syncBaseline(sessionId: string): void {
        this.baselineInitialized = true;
        const steps = this.readSteps(sessionId);
        const maxIdx = steps.length > 0 ? steps[steps.length - 1].step_index : -1;
        if (maxIdx > this.syncedStepIndex) {
            this.syncedStepIndex = maxIdx;
        }
        if (maxIdx > this.promptEndStepIndex) {
            this.promptEndStepIndex = maxIdx;
        }
        this.recordBaselineStepStatuses(steps, maxIdx);
    }

    /** Record transcript baseline before dispatching `backend.prompt()`. */
    beforePrompt(sessionId: string | null): void {
        this.promptText = '';
        this.promptToolCalls = [];
        this.settledPromptCallIds.clear();
        this.baselineInitialized = true;
        if (!sessionId) {
            this.prePromptMaxStepIndex = -1;
            this.promptEndStepIndex = -1;
            return;
        }
        const steps = this.readSteps(sessionId);
        const maxIdx = steps.length > 0 ? steps[steps.length - 1].step_index : -1;
        this.prePromptMaxStepIndex = maxIdx;
        this.promptEndStepIndex = maxIdx;
        if (this.syncedStepIndex < maxIdx) {
            this.syncedStepIndex = maxIdx;
        }
        this.recordBaselineStepStatuses(steps, maxIdx);
    }

    /** Record ACP-owned final text and tool identities; never feed supplemented messages back here. */
    observePromptUpdate(message: AgentMessage): void {
        if (message.type === 'text' && message.live !== true) this.promptText += message.text;
        if (message.type === 'tool_call') {
            const idx = this.promptToolCalls.findIndex((entry) => entry.id === message.id);
            const record: TrackedToolCall = {
                id: message.id,
                name: message.name,
                input: message.input,
                ...(message.title ? { title: message.title } : {}),
                ...(message.kind ? { kind: message.kind } : {})
            };
            if (idx >= 0) {
                this.promptToolCalls[idx] = record;
            } else {
                this.promptToolCalls.push(record);
            }
        } else if (message.type === 'tool_result') {
            for (const [taskId, task] of this.pendingTasks) {
                if (task.id !== message.id) continue;
                this.pendingTasks.delete(taskId);
                this.settledToolStepIndices.add(task.stepIndex);
            }
            this.settledPromptCallIds.add(message.id);
        }
    }

    /** Only system-initiated continuations belong to the log supplement. A user
     * boundary always returns ownership to ACP. Old background tools may settle
     * in place independently of either boundary. */
    private supplementalSteps(steps: AgyRawTranscriptStep[]): AgyRawTranscriptStep[] {
        let reactive = false;
        return steps.filter((step) => {
            if (step.source === 'USER_EXPLICIT' && step.type === 'USER_INPUT') reactive = false;
            if (step.source === 'SYSTEM' && step.type === 'SYSTEM_MESSAGE') reactive = true;
            return (reactive && step.step_index > this.promptEndStepIndex)
                || (this.hasUnsettledPendingBackgroundTaskAtStep(step.step_index) && isTerminalStepStatus(step.status));
        });
    }

    hasCompletedReactiveReply(sessionId: string): boolean {
        const snapshot = this.readSteps(sessionId);
        const steps = this.supplementalSteps(snapshot);
        const last = steps.at(-1);
        return last?.source === 'MODEL' && last.type === 'PLANNER_RESPONSE'
            && last.status === 'DONE' && (last.tool_calls?.length ?? 0) === 0
            && this.getReactiveFlightState(snapshot) === 'idle';
    }

    getBackgroundTasks(): Array<{ id: string; type: string; description: string }> {
        return [...this.pendingTasks.values()].map((task) => ({
            id: task.taskId, type: task.toolName, description: task.title ?? task.name
        }));
    }

    private isStepUnprocessedForReactive(step: AgyRawTranscriptStep): boolean {
        // Any step backing an unsettled `pendingTasks` entry that has reached a
        // terminal status must always be processed so `pendingTasks` is settled
        // and its original `callId` receives `tool_result` (even across user turns).
        if (this.hasUnsettledPendingBackgroundTaskAtStep(step.step_index) && isTerminalStepStatus(step.status)) {
            return true;
        }
        if (step.step_index <= this.promptEndStepIndex) {
            return false;
        }
        const previousStatus = this.processedReactiveStepStatus.get(step.step_index);
        if (previousStatus === undefined) return true;
        // Any non-terminal step status (`RUNNING`, `BACKGROUND_RUNNING`) must be
        // re-processed if the step subsequently transitions in-place to a terminal status.
        if (!isTerminalStepStatus(previousStatus) && isTerminalStepStatus(step.status)) {
            return true;
        }
        return false;
    }

    /**
     * Checks if new or newly-settled reactive steps have appeared in
     * `transcript_full.jsonl` while the driver is idle between user turns.
     */
    hasUnreadReactiveSteps(sessionId: string | null): boolean {
        if (!sessionId || !this.baselineInitialized) return false;
        const snapshot = this.readSteps(sessionId);
        if (snapshot === this.lastDrainedSnapshot) return false;
        const steps = this.supplementalSteps(snapshot);
        if (steps.length === 0) return false;
        const hasPendingBg = this.pendingTasks.size > 0;
        for (let i = steps.length - 1; i >= 0; i--) {
            const step = steps[i];
            if (step.step_index <= this.promptEndStepIndex && !hasPendingBg) break;
            if (this.isStepUnprocessedForReactive(step)) {
                return true;
            }
        }
        return false;
    }

    /**
     * Wake only for changed supplemental data. An unchanged RUNNING row or a
     * pending background task alone is not another foreground turn.
     */
    hasPendingIdleWork(sessionId: string | null): boolean {
        if (!sessionId) return false;
        return this.hasUnreadReactiveSteps(sessionId);
    }

    /**
     * Best-effort `SkipHistory` `resumeSession` sync at the end of a reactive
     * turn: keeps `pendingResumeSync = true` on transient failure without
     * crashing an already-completed reactive turn.
     */
    async tryFlushPendingResumeSync(
        backend: AcpSdkBackend,
        sessionId: string | null,
        cwd: string,
        mode: AgyMode
    ): Promise<void> {
        if (!this.pendingResumeSync || !sessionId) return;
        try {
            await this.syncBackendHistorySkip(backend, sessionId, cwd, mode);
            this.pendingResumeSync = false;
        } catch (error) {
            logger.debug('[agy-acp] deferred SkipHistory resumeSession sync failed', error);
        }
    }

    /**
     * Strict `SkipHistory` sync gate right before dispatching a new `backend.prompt()`.
     * Throws if `pendingResumeSync` cannot be cleared so the driver never sends a
     * new prompt onto a backend with an unsynced `SkipHistory` cursor.
     */
    async requireResumeSyncBeforePrompt(
        backend: AcpSdkBackend,
        sessionId: string | null,
        cwd: string,
        mode: AgyMode
    ): Promise<void> {
        if (!this.pendingResumeSync || !sessionId) return;
        if (this.getReactiveFlightState(this.readSteps(sessionId)) !== 'idle') {
            throw new AgyReactiveContinuationPendingError();
        }
        await this.syncBackendHistorySkip(backend, sessionId, cwd, mode);
        this.pendingResumeSync = false;
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

        let promptEndStepIndex = this.findSynchronousPromptEndStepIndex(steps, this.prePromptMaxStepIndex);
        // ACP may already include a background continuation (especially with
        // concurrent steering). Consume observed text in order, never replay it
        // merely because a SYSTEM_MESSAGE appears in the same snapshot.
        let textOffset = 0;
        for (const step of steps) {
            if (step.step_index <= this.prePromptMaxStepIndex || step.type !== 'PLANNER_RESPONSE' || !step.content) continue;
            const found = this.promptText.indexOf(step.content, textOffset);
            if (found < 0) continue;
            textOffset = found + step.content.length;
            promptEndStepIndex = Math.max(promptEndStepIndex, step.step_index);
        }
        this.promptEndStepIndex = promptEndStepIndex;
        this.ingestSynchronousTurnSteps(steps, this.prePromptMaxStepIndex, promptEndStepIndex, cwd, onUpdate);
        this.advanceSyncedCursor(promptEndStepIndex);
        this.recordBaselineStepStatuses(steps, promptEndStepIndex);

        await this.drainReactiveLoop(params);
    }

    /**
     * Runs when the idle watcher detects new steps in `transcript_full.jsonl`
     * (or remaining `pendingTasks`) while no user prompt is in flight.
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
                if (toolCalls.every((tc) => tc.name === 'ask_question')) {
                    const nextStep = steps[i + 1];
                    if (!nextStep || (nextStep.source === 'SYSTEM' && nextStep.type === 'SYSTEM_MESSAGE')) {
                        return step.step_index;
                    }
                }
            } else if (step.source === 'SYSTEM' && step.type === 'ERROR_MESSAGE') {
                // Only treat ERROR_MESSAGE as ending the synchronous prompt when no
                // immediate synchronous retry step follows before a reactive SYSTEM_MESSAGE.
                const nextStep = steps[i + 1];
                if (!nextStep || (nextStep.source === 'SYSTEM' && nextStep.type === 'SYSTEM_MESSAGE')) {
                    return step.step_index;
                }
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

                const matchedOpenCall = this.takeMatchingPromptToolCall(meta.toolName, meta.args);
                if (matchedOpenCall && this.settledPromptCallIds.has(matchedOpenCall.id)) continue;
                const fallbackFormatted = formatReactiveToolCall(meta.toolName, meta.args, cwd);
                const tracked: PendingBackgroundTask = {
                    taskId,
                    stepIndex: step.step_index,
                    toolName: meta.toolName,
                    id: matchedOpenCall?.id ?? `call_reactive_${step.step_index}`,
                    name: matchedOpenCall?.name ?? fallbackFormatted.name,
                    input: matchedOpenCall?.input ?? fallbackFormatted.input,
                    ...(matchedOpenCall?.title ? { title: matchedOpenCall.title } : { title: fallbackFormatted.title }),
                    ...(matchedOpenCall?.kind ? { kind: matchedOpenCall.kind } : { kind: fallbackFormatted.kind })
                };
                this.pendingTasks.set(taskId, tracked);
                this.backgroundTaskIdByStep.set(step.step_index, taskId);
            } else if (step.source === 'SYSTEM' && step.type === 'SYSTEM_MESSAGE') {
                this.handleSystemMessageStep(step, onUpdate);
            } else if (step.source === 'MODEL' && step.type === 'GENERIC' && step.status === 'DONE') {
                this.handleManageTaskSettlement(step.content, onUpdate);
            }
        }
    }

    private takeMatchingPromptToolCall(
        toolName: string,
        args: Record<string, unknown>
    ): TrackedToolCall | null {
        if (this.promptToolCalls.length === 0) return null;
        if (toolName === 'run_command') {
            if (typeof args.CommandLine === 'string') {
                const idx = this.promptToolCalls.findIndex(
                    (c) =>
                        (isObject(c.input) && (
                            c.input.CommandLine === args.CommandLine ||
                            c.input.command === args.CommandLine
                        )) ||
                        c.title === args.CommandLine ||
                        c.name === args.CommandLine
                );
                if (idx >= 0) {
                    return this.promptToolCalls.splice(idx, 1)[0];
                }
            }
            const execIdx = this.promptToolCalls.findIndex((c) => c.kind === 'execute');
            if (execIdx >= 0) {
                return this.promptToolCalls.splice(execIdx, 1)[0];
            }
            return null;
        }
        if (toolName === 'schedule' && typeof args.Prompt === 'string') {
            const idx = this.promptToolCalls.findIndex(
                (c) => isObject(c.input) && c.input.Prompt === args.Prompt
            );
            if (idx >= 0) {
                return this.promptToolCalls.splice(idx, 1)[0];
            }
        }
        return this.promptToolCalls.shift() ?? null;
    }

    private failPendingReactiveToolResult(
        expectedStepIndex: number,
        pending: PendingReactiveToolResult,
        reason: string,
        onUpdate: (message: AgentMessage) => void,
        includeNonBlocking = false
    ): void {
        this.pendingReactiveToolResults.delete(expectedStepIndex);
        if (!pending.blocking && !includeNonBlocking) {
            return;
        }
        if (this.settledToolStepIndices.has(expectedStepIndex)) {
            return;
        }
        this.settledToolStepIndices.add(expectedStepIndex);
        const output = formatReactiveToolOutput(pending.toolName, reason, true);
        onUpdate({
            type: 'tool_call',
            id: pending.id,
            name: pending.name,
            input: pending.input,
            status: 'failed',
            ...(pending.title ? { title: pending.title } : {}),
            ...(pending.kind ? { kind: pending.kind } : {})
        });
        onUpdate({
            type: 'tool_result',
            id: pending.id,
            output,
            status: 'failed'
        });
    }

    private settleOrphanedReactiveToolResultsBefore(
        boundaryStepIndex: number,
        existingGenericStepIndices: ReadonlySet<number>,
        reason: string,
        onUpdate: (message: AgentMessage) => void
    ): boolean {
        let settledAny = false;
        for (const [expectedStepIndex, pending] of [...this.pendingReactiveToolResults.entries()]) {
            if (expectedStepIndex >= boundaryStepIndex) continue;
            if (existingGenericStepIndices.has(expectedStepIndex)) continue;
            this.failPendingReactiveToolResult(expectedStepIndex, pending, reason, onUpdate, false);
            settledAny = true;
        }
        return settledAny;
    }

    private settleAllPendingOnServerRestart(
        reason: string,
        onUpdate: (message: AgentMessage) => void
    ): void {
        for (const [taskId, pending] of [...this.pendingTasks.entries()]) {
            this.pendingTasks.delete(taskId);
            this.settledToolStepIndices.add(pending.stepIndex);
            const output = pending.kind === 'execute'
                ? parseAgyCommandOutput(reason)
                : stripStepTimestamps(reason);
            onUpdate({
                type: 'tool_call',
                id: pending.id,
                name: pending.name,
                input: pending.input,
                status: 'failed',
                ...(pending.title ? { title: pending.title } : {}),
                ...(pending.kind ? { kind: pending.kind } : {})
            });
            onUpdate({
                type: 'tool_result',
                id: pending.id,
                output,
                status: 'failed'
            });
        }
        for (const [expectedStepIndex, pending] of [...this.pendingReactiveToolResults.entries()]) {
            this.failPendingReactiveToolResult(expectedStepIndex, pending, reason, onUpdate, true);
        }
    }

    private handleSystemMessageStep(
        step: AgyRawTranscriptStep,
        onUpdate: (message: AgentMessage) => void
    ): void {
        if (isServerRestartSystemMessage(step.content)) {
            this.settleAllPendingOnServerRestart(
                stripStepTimestamps(step.content).trim() || 'Stopped due to Antigravity server restart',
                onUpdate
            );
            return;
        }
        const completion = extractSystemMessageTaskCompletion(step.content);
        if (!completion) return;
        const pending = this.pendingTasks.get(completion.taskId);
        if (!pending) return;
        this.pendingTasks.delete(completion.taskId);
        this.settledToolStepIndices.add(pending.stepIndex);

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
            this.settledToolStepIndices.add(pending.stepIndex);
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
        steps = this.supplementalSteps(steps);
        let emittedOrAdvanced = false;
        const existingGenericStepIndices = new Set<number>();
        let maxInterruptingBoundaryStepIndex = -1;
        for (const step of steps) {
            if (step.step_index <= this.promptEndStepIndex) continue;
            if (step.source === 'MODEL' && step.type === 'GENERIC') {
                existingGenericStepIndices.add(step.step_index);
            }
            if (isBatchInterruptingBoundaryStep(step) && step.step_index > maxInterruptingBoundaryStepIndex) {
                maxInterruptingBoundaryStepIndex = step.step_index;
            }
        }

        for (const step of steps) {
            if (!this.isStepUnprocessedForReactive(step)) continue;

            if (step.source === 'SYSTEM' && step.type === 'SYSTEM_MESSAGE') {
                if (isServerRestartSystemMessage(step.content)) {
                    this.settleOrphanedReactiveToolResultsBefore(
                        step.step_index,
                        existingGenericStepIndices,
                        'Stopped due to Antigravity server restart',
                        onUpdate
                    );
                }
                this.handleSystemMessageStep(step, onUpdate);
                this.processedReactiveStepStatus.set(step.step_index, step.status);
                this.advanceSyncedCursor(step.step_index);
                emittedOrAdvanced = true;
                continue;
            }

            if (step.source === 'SYSTEM' && step.type === 'ERROR_MESSAGE') {
                const detail = stripStepTimestamps(step.content).trim() || 'stream interrupted';
                this.settleOrphanedReactiveToolResultsBefore(
                    step.step_index,
                    existingGenericStepIndices,
                    `Tool interrupted before result was recorded: ${detail}`,
                    onUpdate
                );
                this.processedReactiveStepStatus.set(step.step_index, step.status);
                this.advanceSyncedCursor(step.step_index);
                emittedOrAdvanced = true;
                continue;
            }

            if (step.source === 'MODEL' && step.type === 'PLANNER_RESPONSE') {
                if (step.status === 'RUNNING') {
                    // Only record RUNNING as observed if a later interrupting boundary
                    // (ERROR_MESSAGE / server restart / newer PLANNER_RESPONSE) already
                    // moved past it; even then, `RUNNING` remains non-terminal so an
                    // in-place transition to `DONE` will still be processed!
                    if (step.step_index < maxInterruptingBoundaryStepIndex) {
                        this.processedReactiveStepStatus.set(step.step_index, 'RUNNING');
                        this.advanceSyncedCursor(step.step_index);
                        emittedOrAdvanced = true;
                    }
                    continue;
                }

                this.settleOrphanedReactiveToolResultsBefore(
                    step.step_index,
                    existingGenericStepIndices,
                    'Tool result missing from transcript before next planner turn (interrupted or skipped)',
                    onUpdate
                );

                if (step.status === 'DONE') {
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
                        const isAskQuestion = tc.name === 'ask_question';
                        const record: PendingReactiveToolResult = {
                            plannerStepIndex: step.step_index,
                            expectedStepIndex: resultStepIndex,
                            id: callId,
                            toolName: tc.name,
                            args,
                            name: formatted.name,
                            input: formatted.input,
                            title: formatted.title,
                            kind: formatted.kind,
                            isDaemon: isDaemonToolCall(args),
                            blocking: !isAskQuestion
                        };
                        this.reactiveToolMetaByStep.set(resultStepIndex, record);
                        this.pendingReactiveToolResults.set(resultStepIndex, record);
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
                }

                this.processedReactiveStepStatus.set(step.step_index, step.status);
                this.advanceSyncedCursor(step.step_index);
                emittedOrAdvanced = true;
                continue;
            }

            if (step.source === 'MODEL' && step.type === 'GENERIC') {
                const meta = this.pendingReactiveToolResults.get(step.step_index)
                    ?? this.reactiveToolMetaByStep.get(step.step_index)
                    ?? {
                        plannerStepIndex: step.step_index - 1,
                        expectedStepIndex: step.step_index,
                        id: `call_reactive_${step.step_index}`,
                        toolName: 'run_command',
                        args: {},
                        name: 'Run tool',
                        input: {},
                        title: 'Run tool',
                        kind: 'other',
                        isDaemon: false,
                        blocking: true
                    };

                if (step.status === 'DONE') {
                    this.handleManageTaskSettlement(step.content, onUpdate);
                }

                if (step.status === 'RUNNING') {
                    const taskId = extractRunningTaskId(step.content);
                    if (taskId) {
                        if (!meta.isDaemon && !this.settledToolStepIndices.has(step.step_index)) {
                            this.pendingTasks.set(taskId, {
                                taskId,
                                stepIndex: step.step_index,
                                toolName: meta.toolName,
                                id: meta.id,
                                name: meta.name,
                                input: meta.input,
                                title: meta.title,
                                kind: meta.kind
                            });
                            this.backgroundTaskIdByStep.set(step.step_index, taskId);
                        }
                        this.pendingReactiveToolResults.delete(step.step_index);
                        this.processedReactiveStepStatus.set(step.step_index, 'BACKGROUND_RUNNING');
                        this.advanceSyncedCursor(step.step_index);
                        emittedOrAdvanced = true;
                        continue;
                    }
                    // Non-background RUNNING tool step: only fail if a true interrupting
                    // boundary (ERROR_MESSAGE, server restart, or newer PLANNER_RESPONSE)
                    // has already advanced past this step; keep non-terminal `'RUNNING'`
                    // status and preserved `reactiveToolMetaByStep` for any late terminal update.
                    if (step.step_index < maxInterruptingBoundaryStepIndex) {
                        const existingPending = this.pendingReactiveToolResults.get(step.step_index);
                        if (existingPending) {
                            this.failPendingReactiveToolResult(
                                step.step_index,
                                existingPending,
                                'Tool execution interrupted before completion',
                                onUpdate,
                                false
                            );
                        }
                        this.processedReactiveStepStatus.set(step.step_index, 'RUNNING');
                        this.advanceSyncedCursor(step.step_index);
                        emittedOrAdvanced = true;
                    }
                    continue;
                }

                if (isTerminalStepStatus(step.status)) {
                    const bgTaskId = this.backgroundTaskIdByStep.get(step.step_index);
                    const pendingBg = bgTaskId ? this.pendingTasks.get(bgTaskId) : undefined;
                    if (bgTaskId && pendingBg) {
                        this.pendingTasks.delete(bgTaskId);
                    }

                    // Skip duplicate emission if this step was already settled via
                    // SYSTEM_MESSAGE task completion; otherwise emit terminal result
                    // with the preserved original callId!
                    const alreadySettledViaBgMessage = Boolean(bgTaskId && !pendingBg && this.settledToolStepIndices.has(step.step_index));
                    if (!alreadySettledViaBgMessage) {
                        const effectiveMeta = pendingBg ?? meta;
                        const effectiveToolName = pendingBg?.toolName ?? meta.toolName;
                        const isError = step.status !== 'DONE';
                        const status = isError ? 'failed' : 'completed';
                        const output = formatReactiveToolOutput(effectiveToolName, step.content, isError);
                        this.settledToolStepIndices.add(step.step_index);
                        onUpdate({
                            type: 'tool_call',
                            id: effectiveMeta.id,
                            name: effectiveMeta.name,
                            input: effectiveMeta.input,
                            status,
                            ...(effectiveMeta.title ? { title: effectiveMeta.title } : {}),
                            ...(effectiveMeta.kind ? { kind: effectiveMeta.kind } : {})
                        });
                        onUpdate({
                            type: 'tool_result',
                            id: effectiveMeta.id,
                            output,
                            status
                        });
                    }
                    this.pendingReactiveToolResults.delete(step.step_index);
                    this.processedReactiveStepStatus.set(step.step_index, step.status);
                    this.advanceSyncedCursor(step.step_index);
                    emittedOrAdvanced = true;
                    continue;
                }
            }

            if (isBatchInterruptingBoundaryStep(step)) {
                this.settleOrphanedReactiveToolResultsBefore(
                    step.step_index,
                    existingGenericStepIndices,
                    'Tool result missing from transcript (interrupted or skipped)',
                    onUpdate
                );
            }
            this.processedReactiveStepStatus.set(step.step_index, step.status);
            this.advanceSyncedCursor(step.step_index);
            emittedOrAdvanced = true;
        }
        if (emittedOrAdvanced) {
            this.trailingPlannerHandoff = null;
        }
        return emittedOrAdvanced;
    }

    getReactiveFlightState(steps: AgyRawTranscriptStep[]): AgyReactiveFlightState {
        steps = this.supplementalSteps(steps);
        if (this.hasBlockingPendingReactiveToolResults()) {
            this.trailingPlannerHandoff = null;
            return 'pending-tool-result';
        }
        if (steps.length === 0) {
            this.trailingPlannerHandoff = null;
            return 'idle';
        }

        let maxInterruptingBoundaryStepIndex = -1;
        for (const step of steps) {
            if (step.step_index <= this.promptEndStepIndex) continue;
            if (isBatchInterruptingBoundaryStep(step) && step.step_index > maxInterruptingBoundaryStepIndex) {
                maxInterruptingBoundaryStepIndex = step.step_index;
            }
        }

        // Check if any reactive step not yet superseded by a newer interrupting
        // boundary is still actively RUNNING (excluding background tasks).
        for (const step of steps) {
            if (step.step_index <= this.promptEndStepIndex) continue;
            if (step.status !== 'RUNNING') continue;
            if (step.step_index < maxInterruptingBoundaryStepIndex) continue;
            if (step.source === 'MODEL' && step.type === 'GENERIC' && extractRunningTaskId(step.content) !== null) {
                continue;
            }
            this.trailingPlannerHandoff = null;
            return 'active-step';
        }

        const last = steps[steps.length - 1];
        if (last.step_index <= this.promptEndStepIndex) {
            this.trailingPlannerHandoff = null;
            return 'idle';
        }
        if (last.source === 'MODEL' && last.type === 'PLANNER_RESPONSE') {
            this.trailingPlannerHandoff = null;
            if (last.status === 'RUNNING') return 'active-step';
            if (last.status !== 'DONE') return 'idle';
            const toolCalls = Array.isArray(last.tool_calls) ? last.tool_calls : [];
            if (toolCalls.some((tc) => tc.name !== 'ask_question')) return 'pending-tool-result';
            return 'idle';
        }
        if (
            (last.source === 'SYSTEM' && last.type === 'SYSTEM_MESSAGE' && !isServerRestartSystemMessage(last.content))
            || (last.source === 'MODEL' && last.type === 'GENERIC')
        ) {
            const now = Date.now();
            if (!this.trailingPlannerHandoff || this.trailingPlannerHandoff.stepIndex !== last.step_index) {
                this.trailingPlannerHandoff = { stepIndex: last.step_index, since: now };
            }
            if (now - this.trailingPlannerHandoff.since < this.nextPlannerGraceMs) {
                return 'awaiting-next-planner';
            }
            return 'idle';
        }
        this.trailingPlannerHandoff = null;
        return 'idle';
    }

    private isReactiveTurnMidFlight(steps: AgyRawTranscriptStep[]): boolean {
        return this.getReactiveFlightState(steps) !== 'idle';
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
        const startedAt = Date.now();
        let sawReactiveActivityThisDrain = false;
        let lastActivityAt = startedAt;
        let loggedAwaitingNextPlanner = false;

        while (!isAborted()) {
            const steps = this.readSteps(sessionId);
            this.lastDrainedSnapshot = steps;
            const advanced = this.processNewReactiveSteps(steps, cwd, onUpdate);
            if (advanced) {
                this.pendingResumeSync = true;
                sawReactiveActivityThisDrain = true;
                lastActivityAt = Date.now();
                loggedAwaitingNextPlanner = false;
            }

            const flightState = this.getReactiveFlightState(steps);
            if (flightState === 'awaiting-next-planner' && !loggedAwaitingNextPlanner) {
                loggedAwaitingNextPlanner = true;
                logger.debug('[agy-acp] awaiting follow-up PLANNER_RESPONSE after terminal reactive step');
            }
            const midFlight = flightState !== 'idle';
            const withinQuietWindow = sawReactiveActivityThisDrain && (Date.now() - lastActivityAt < this.quietPeriodMs);

            // A log snapshot is not a lifecycle authority. Pending background
            // tasks and stale RUNNING rows must not hold the foreground loop.
            if ((!midFlight && !withinQuietWindow) || shouldYield() || Date.now() - startedAt >= this.maxDrainMs) break;

            await new Promise<void>((resolve) => {
                const timer = setTimeout(resolve, this.pollIntervalMs);
                timer.unref?.();
            });
        }

        if (this.pendingResumeSync && !isAborted()
            && this.getReactiveFlightState(this.readSteps(sessionId)) === 'idle') {
            await this.tryFlushPendingResumeSync(backend, sessionId, cwd, mode);
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
