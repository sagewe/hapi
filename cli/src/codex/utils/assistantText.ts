import { stripNotifySummaryFooter } from '@hapi/protocol/messages';

/** Keep turn summaries out of explicitly intermediate Codex output. */
export function codexAssistantText(text: string, phase: unknown): string {
    if (phase === 'commentary' || phase === 'partial_answer') {
        return stripNotifySummaryFooter(text);
    }
    // Missing/unknown phases provide no evidence that a message is interim.
    return text;
}

/** Common presentation phase, preserving native evidence rather than guessing prose. */
export function codexAssistantPhase(phase: unknown): 'progress' | 'final' | undefined {
    if (phase === 'final_answer') return 'final';
    if (phase === 'commentary' || phase === 'partial_answer') return 'progress';
    return undefined;
}
