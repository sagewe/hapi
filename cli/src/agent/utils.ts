import { isObject } from '@hapi/protocol';
import type { PermissionRequest } from './types';

export function deriveToolInput(request: PermissionRequest): unknown {
    return request.rawInput !== undefined ? request.rawInput : request.rawOutput ?? null;
}

type ToolNameSource = 'title' | 'raw_input_name' | 'raw_input_tool' | 'kind' | 'default';

export type CanonicalDiffToolInput =
    | { name: 'Edit'; input: { file_path: string; old_string: string; new_string: string; replace_all?: boolean } }
    | { name: 'Write'; input: { file_path: string; content: string } };

export type CanonicalQuestionToolInput = {
    name: 'AskUserQuestion';
    input: Record<string, unknown> | null;
};

const QUESTION_TOOL_HINTS = new Set([
    'ask_question',
    'run ask_question',
    'askuserquestion',
    'ask_user_question',
]);

/**
 * Normalizes native `ask_question` tool calls (e.g. Antigravity `Run ask_question`
 * with `{ questions: [{ question, options: string[], is_multi_select?: boolean }] }`)
 * into the canonical `AskUserQuestion` tool name and `{ questions: [{ question,
 * multiSelect, options: [{ label, description? }] }] }` input shape expected by
 * Web, iOS, and Mac Catalyst question cards.
 */
export function canonicalizeQuestionToolInput(
    rawInput: unknown,
    semanticHint: string | null
): CanonicalQuestionToolInput | null {
    const hint = semanticHint?.trim().toLowerCase() ?? null;
    if (!hint || !QUESTION_TOOL_HINTS.has(hint)) {
        return null;
    }

    if (!isObject(rawInput)) {
        return { name: 'AskUserQuestion', input: null };
    }

    if (!Array.isArray(rawInput.questions)) {
        return { name: 'AskUserQuestion', input: rawInput };
    }

    const questions = rawInput.questions
        .map((entry): Record<string, unknown> | null => {
            if (!isObject(entry)) return null;
            const question = typeof entry.question === 'string' ? entry.question : '';
            if (!question) return null;
            const header = typeof entry.header === 'string' && entry.header.trim().length > 0
                ? entry.header.trim()
                : undefined;
            const multiSelect = entry.multiSelect === true || entry.is_multi_select === true;
            const rawOptions = Array.isArray(entry.options) ? entry.options : [];
            const options: Array<{ label: string; description?: string }> = [];
            for (const opt of rawOptions) {
                if (typeof opt === 'string') {
                    const trimmed = opt.trim();
                    if (trimmed.length > 0) {
                        options.push({ label: trimmed });
                    }
                } else if (isObject(opt) && typeof opt.label === 'string' && opt.label.trim().length > 0) {
                    const description = typeof opt.description === 'string' && opt.description.trim().length > 0
                        ? opt.description
                        : undefined;
                    options.push({
                        label: opt.label,
                        ...(description ? { description } : {})
                    });
                }
            }
            return {
                ...entry,
                question,
                ...(header ? { header } : {}),
                multiSelect,
                options
            };
        })
        .filter((entry): entry is Record<string, unknown> => entry !== null);

    return {
        name: 'AskUserQuestion',
        input: {
            ...rawInput,
            questions
        }
    };
}

function firstString(value: unknown, keys: readonly string[]): string | null {
    if (!isObject(value)) return null;
    for (const key of keys) {
        const candidate = value[key];
        if (typeof candidate === 'string') return candidate;
    }
    return null;
}

/**
 * Detects diff/write-shaped tool inputs emitted by ACP agents that keep their
 * native argument shapes (OpenCode: `{filePath, oldString, newString}` for
 * edit and `{filePath, content}` for write) and normalizes them to the
 * Claude-shaped inputs the web Edit/Write views render.
 *
 * Gated on the tool's semantic name/kind: only known edit/write aliases are
 * canonicalized. The Edit shape (path + both old/new strings) is unambiguous on
 * its own, but Write is just `{path, content}` — a shape many non-edit MCP
 * tools also accept — so without the gate those tools would be renamed to
 * Write and their extra args dropped. The gate keeps the OpenCode native-shape
 * cases (OpenCode maps both edit and write to kind 'edit', which is in the
 * allow-list) while avoiding that misclassification.
 *
 * Returns null when the semantic hint is missing/unknown, or the input shape
 * doesn't match, so callers keep their existing fallback.
 */
export function canonicalizeDiffToolInput(rawInput: unknown, semanticHint: string | null): CanonicalDiffToolInput | null {
    const kind = semanticHint?.trim().toLowerCase() ?? null;
    if (!kind || !['edit', 'write', 'write_file', 'replace', 'modify', 'file_edit'].includes(kind)) {
        return null;
    }

    const filePath = firstString(rawInput, ['filePath', 'file_path']);
    if (filePath === null || filePath.length === 0) return null;

    const oldString = firstString(rawInput, ['oldString', 'old_string']);
    const newString = firstString(rawInput, ['newString', 'new_string']);
    if (oldString !== null && newString !== null) {
        // OpenCode streams camelCase replaceAll; already-canonical inputs may
        // carry snake_case replace_all. Accept both so the execution argument
        // survives every call site.
        let replaceAll: boolean | undefined;
        if (isObject(rawInput)) {
            if (typeof rawInput.replaceAll === 'boolean') {
                replaceAll = rawInput.replaceAll;
            } else if (typeof rawInput.replace_all === 'boolean') {
                replaceAll = rawInput.replace_all;
            }
        }
        return {
            name: 'Edit',
            input: {
                file_path: filePath,
                old_string: oldString,
                new_string: newString,
                ...(replaceAll === undefined ? {} : { replace_all: replaceAll }),
            },
        };
    }

    const content = firstString(rawInput, ['content']);
    if (content !== null) {
        return { name: 'Write', input: { file_path: filePath, content } };
    }

    return null;
}

function normalizeToolName(value: unknown): string | null {
    if (typeof value !== 'string') {
        return null;
    }
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
}

export function isPlaceholderToolName(name: string): boolean {
    const normalized = name.trim().toLowerCase();
    return normalized === '' || normalized === 'tool' || normalized === 'unknown' || normalized === 'other';
}

export function deriveToolNameWithSource(input: {
    title?: string | null;
    kind?: string | null;
    rawInput?: unknown;
    metaKind?: string | null;
}): { name: string; source: ToolNameSource } {
    const title = normalizeToolName(input.title);
    if (title) {
        return { name: title, source: 'title' };
    }

    if (isObject(input.rawInput)) {
        const fromName = normalizeToolName(input.rawInput.name);
        if (fromName) {
            return { name: fromName, source: 'raw_input_name' };
        }

        const fromTool = normalizeToolName(input.rawInput.tool);
        if (fromTool) {
            return { name: fromTool, source: 'raw_input_tool' };
        }
    }

    // ACP agents (Gemini, Kimi) use kind=edit/write/replace with _meta.kind to
    // distinguish write_file (add) from replace (modify). Normalise the kind
    // so aliases like 'write', 'replace', 'modify' are handled the same way.
    const normalizedKind = typeof input.kind === 'string'
        ? input.kind.toLowerCase().trim()
        : null;
    if (normalizedKind === 'edit' || normalizedKind === 'write' || normalizedKind === 'write_file' || normalizedKind === 'replace' || normalizedKind === 'modify' || normalizedKind === 'file_edit') {
        if (input.metaKind === 'add') {
            return { name: 'Write', source: 'kind' };
        }
        if (input.metaKind === 'modify') {
            return { name: 'Edit', source: 'kind' };
        }
    }

    const kind = normalizeToolName(input.kind);
    if (kind && !isPlaceholderToolName(kind)) {
        return { name: kind, source: 'kind' };
    }

    return { name: 'Tool', source: 'default' };
}

export function deriveToolName(input: {
    title?: string | null;
    kind?: string | null;
    rawInput?: unknown;
    metaKind?: string | null;
}): string {
    return deriveToolNameWithSource(input).name;
}
