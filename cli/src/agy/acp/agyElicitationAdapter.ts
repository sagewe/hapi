import { randomUUID } from 'node:crypto';
import { asString, isObject } from '@hapi/protocol';
import type { AcpSdkBackend } from '@/agent/backends/acp';
import type { PermissionResponseMessage } from '@/agent/permissionAdapter';
import type { ApiSessionClient } from '@/api/apiSession';
import type { AgentState } from '@/api/types';
import { logger } from '@/ui/logger';

interface ParsedElicitationOption {
    constId: string;
    label: string;
}

interface ParsedElicitationQuestion {
    qNum: number;
    choiceKey: string | null;
    otherKey: string | null;
    question: string;
    multiSelect: boolean;
    options: ParsedElicitationOption[];
}

interface PendingElicitationRequest {
    id: string;
    sessionId: string;
    questions: ParsedElicitationQuestion[];
    toolArguments: {
        questions: Array<{
            question: string;
            multiSelect: boolean;
            options: Array<{ label: string }>;
        }>;
    };
    resolve: (result: { action: 'accept' | 'decline' | 'cancel'; content?: Record<string, unknown> }) => void;
}

function parseEnumOptions(rawList: unknown): ParsedElicitationOption[] {
    if (!Array.isArray(rawList)) return [];
    const options: ParsedElicitationOption[] = [];
    for (const item of rawList) {
        if (!isObject(item)) continue;
        const constId = asString(item.const);
        if (!constId) continue;
        const label = asString(item.title) ?? constId;
        options.push({ constId, label });
    }
    return options;
}

export function parseAgyElicitationQuestions(
    requestedSchema: unknown,
    fallbackMessage: string | null
): ParsedElicitationQuestion[] {
    if (!isObject(requestedSchema) || !isObject(requestedSchema.properties)) {
        return [];
    }
    const properties = requestedSchema.properties;
    const qNums = new Set<number>();
    for (const key of Object.keys(properties)) {
        const match = /^q(\d+)(?:_other)?$/.exec(key);
        if (match) {
            const num = Number.parseInt(match[1], 10);
            if (Number.isFinite(num) && num > 0) {
                qNums.add(num);
            }
        }
    }

    const sortedNums = Array.from(qNums).sort((a, b) => a - b);
    const questions: ParsedElicitationQuestion[] = [];

    for (const qNum of sortedNums) {
        const choiceKey = `q${qNum}`;
        const otherKey = `q${qNum}_other`;
        const choiceProp = isObject(properties[choiceKey]) ? properties[choiceKey] : null;
        const otherProp = isObject(properties[otherKey]) ? properties[otherKey] : null;

        const questionText =
            (choiceProp ? asString(choiceProp.title) : null) ??
            (otherProp ? asString(otherProp.title) : null) ??
            fallbackMessage ??
            `Question ${qNum}`;

        const multiSelect = choiceProp ? asString(choiceProp.type) === 'array' : false;
        let options: ParsedElicitationOption[] = [];
        if (choiceProp) {
            if (multiSelect && isObject(choiceProp.items)) {
                options = parseEnumOptions(choiceProp.items.anyOf);
            } else {
                options = parseEnumOptions(choiceProp.oneOf);
            }
        }

        questions.push({
            qNum,
            choiceKey: choiceProp ? choiceKey : null,
            otherKey: otherProp ? otherKey : null,
            question: questionText,
            multiSelect,
            options
        });
    }

    return questions;
}

/**
 * Bridges Antigravity (`agy acp`) `elicitation/create` requests to HAPI's
 * interactive `AskUserQuestion` permission flow across Web, iOS, and Mac Catalyst.
 */
export class AgyElicitationAdapter {
    private readonly pending = new Map<string, PendingElicitationRequest>();

    constructor(
        private readonly session: ApiSessionClient,
        private readonly backend: AcpSdkBackend
    ) {
        this.backend.registerExtensionRequestHandler('elicitation/create', async (params, requestId) => {
            return await this.handleElicitationCreate(params, requestId);
        });
    }

    private async handleElicitationCreate(
        params: unknown,
        requestId: string | number | null
    ): Promise<{ action: 'accept' | 'decline' | 'cancel'; content?: Record<string, unknown> }> {
        const payload = isObject(params) ? params : {};
        const sessionId = asString(payload.sessionId) ?? '';
        const toolCallId = asString(payload.toolCallId);
        const message = asString(payload.message);
        const id = toolCallId ?? (requestId !== null ? String(requestId) : randomUUID());

        const questions = parseAgyElicitationQuestions(payload.requestedSchema, message);
        if (questions.length === 0) {
            logger.debug(`[agy-acp] elicitation/create had no parseable questions (${id}), declining`);
            return { action: 'decline' };
        }

        const toolArguments = {
            questions: questions.map((q) => ({
                question: q.question,
                multiSelect: q.multiSelect,
                options: q.options.map((opt) => ({ label: opt.label }))
            }))
        };

        return await new Promise<{ action: 'accept' | 'decline' | 'cancel'; content?: Record<string, unknown> }>((resolve) => {
            this.pending.set(id, {
                id,
                sessionId,
                questions,
                toolArguments,
                resolve
            });

            this.session.updateAgentState((currentState) => ({
                ...currentState,
                requests: {
                    ...currentState.requests,
                    [id]: {
                        tool: 'AskUserQuestion',
                        arguments: toolArguments,
                        createdAt: Date.now()
                    }
                }
            }));

            logger.debug(`[agy-acp] Elicitation question request queued: AskUserQuestion (${id})`);
        });
    }

    async handlePermissionResponse(response: PermissionResponseMessage): Promise<boolean> {
        const pending = this.pending.get(response.id);
        if (!pending) {
            return false;
        }

        this.pending.delete(response.id);
        const decision = response.decision ?? (response.approved ? 'approved' : 'denied');

        if (decision === 'abort') {
            pending.resolve({ action: 'cancel' });
            if (pending.sessionId) {
                await this.backend.cancelPrompt(pending.sessionId);
            }
            await this.cancelAll('User aborted');
        } else if (!response.approved || decision === 'denied') {
            pending.resolve({ action: 'decline' });
        } else {
            const content: Record<string, unknown> = {};
            const rawAnswersMap = response.answers ?? {};

            pending.questions.forEach((q, idx) => {
                const rawSelected = Array.isArray(rawAnswersMap[String(idx)])
                    ? rawAnswersMap[String(idx)]
                    : [];
                const selectedIds: string[] = [];
                const otherTexts: string[] = [];

                for (const rawValue of rawSelected) {
                    if (typeof rawValue !== 'string') continue;
                    const trimmed = rawValue.trim();
                    if (!trimmed) continue;

                    const matchedOption = q.options.find(
                        (opt) =>
                            opt.label === rawValue ||
                            opt.constId === rawValue ||
                            opt.label.trim() === trimmed
                    );
                    if (matchedOption) {
                        selectedIds.push(matchedOption.constId);
                    } else {
                        otherTexts.push(trimmed);
                    }
                }

                if (q.choiceKey && selectedIds.length > 0) {
                    content[q.choiceKey] = q.multiSelect ? selectedIds : selectedIds[0];
                }
                if (q.otherKey && otherTexts.length > 0) {
                    content[q.otherKey] = otherTexts.join('\n');
                }
            });

            pending.resolve({
                action: 'accept',
                content
            });
        }

        this.session.updateAgentState((currentState) => {
            const requestEntry = currentState.requests?.[response.id];
            const { [response.id]: _, ...remaining } = currentState.requests ?? {};
            const status = response.approved
                ? 'approved'
                : decision === 'abort'
                    ? 'canceled'
                    : 'denied';

            return {
                ...currentState,
                requests: remaining,
                completedRequests: {
                    ...currentState.completedRequests,
                    [response.id]: {
                        tool: 'AskUserQuestion',
                        arguments: pending.toolArguments,
                        createdAt: requestEntry?.createdAt ?? Date.now(),
                        completedAt: Date.now(),
                        status,
                        decision,
                        ...(response.answers ? { answers: response.answers } : {})
                    }
                }
            } satisfies AgentState;
        });

        logger.debug(`[agy-acp] Elicitation response ${response.approved ? 'accepted' : 'declined'} (${response.id})`);
        return true;
    }

    async cancelAll(reason: string): Promise<void> {
        if (this.pending.size === 0) return;
        const entries = Array.from(this.pending.values());
        this.pending.clear();

        for (const entry of entries) {
            entry.resolve({ action: 'cancel' });
        }

        this.session.updateAgentState((currentState) => {
            const pendingRequests = { ...(currentState.requests ?? {}) };
            const completedRequests = { ...(currentState.completedRequests ?? {}) };

            for (const entry of entries) {
                const req = pendingRequests[entry.id];
                delete pendingRequests[entry.id];
                completedRequests[entry.id] = {
                    tool: req?.tool ?? 'AskUserQuestion',
                    arguments: req?.arguments ?? entry.toolArguments,
                    createdAt: req?.createdAt ?? Date.now(),
                    completedAt: Date.now(),
                    status: 'canceled',
                    reason,
                    decision: 'abort'
                };
            }

            return {
                ...currentState,
                requests: pendingRequests,
                completedRequests
            } satisfies AgentState;
        });
    }
}
