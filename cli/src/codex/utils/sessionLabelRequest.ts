import { AgentSessionTagsRequestSchema } from '@hapi/protocol/apiTypes';
import { normalizeSessionDisplayTitle } from '@/agent/sessionDisplayRename';
import { ChangeSessionTitleInputSchema } from '@/modules/common/sessionTagTools';

type Labels = { title?: string; tags?: string[] };
const object = (value: unknown): Record<string, unknown> | undefined =>
    value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : undefined;

/** Native descendants share an MCP server; only the owning projection applies labels. */
export function parseSessionLabelRequest(tool: string, raw: unknown): Labels | undefined {
    if (tool !== 'change_title' && tool !== 'add_tags') return;
    if (tool === 'add_tags') {
        const parsed = AgentSessionTagsRequestSchema.safeParse(raw);
        return parsed.success ? { tags: parsed.data.tags } : undefined;
    }
    const parsedArgs = ChangeSessionTitleInputSchema.safeParse(raw);
    if (!parsedArgs.success) return;
    const args = parsedArgs.data;
    const title = tool === 'change_title' && args.title !== undefined
        ? normalizeSessionDisplayTitle(args.title) ?? undefined : undefined;
    if (args.title !== undefined && !title) return;
    const parsed = args.tags === undefined ? undefined : AgentSessionTagsRequestSchema.safeParse({ tags: args.tags });
    if (parsed && !parsed.success) return;
    const tags = parsed?.success ? parsed.data.tags : undefined;
    if (!title && !tags) return;
    return { ...(title ? { title } : {}), ...(tags ? { tags } : {}) };
}

/** A legacy server can accept a title while discarding unknown tags. Require explicit deferral proof. */
export function isDeferredSessionLabelResult(raw: unknown): boolean {
    let value = object(raw);
    if (!value || 'Err' in value || value.isError === true) return false;
    if ('Ok' in value) value = object(value.Ok);
    if (!value || value.isError === true) return false;
    const structured = object(value.structuredContent);
    if (structured) return structured.success === true && structured.deferred === true;
    for (const part of Array.isArray(value.content) ? value.content : []) {
        const item = object(part);
        if (item?.type !== 'text' || typeof item.text !== 'string' || item.text.length > 16_384) continue;
        try {
            // The bridge keeps a human-readable first line, followed by the
            // same machine outcome as its final JSON line.
            const result = object(JSON.parse(item.text.trim().split(/\r?\n/).at(-1)!));
            if (result?.success === true && result.deferred === true) return true;
        } catch { /* Human-readable legacy results do not prove tag support. */ }
    }
    return false;
}
