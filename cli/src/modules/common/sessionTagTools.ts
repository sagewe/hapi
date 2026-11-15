import { z } from 'zod'
import { AgentSessionTagsRequestSchema } from '@hapi/protocol'

/** Shared by HTTP MCP, STDIO MCP and root-owned Codex completion projection. */
export const ChangeSessionTitleInputSchema = z.object({
    title: z.string().optional().describe('Concise task title; omitted for append-only tags'),
    tags: AgentSessionTagsRequestSchema.shape.tags.optional().describe('One to three stable topic tags to append; reuse list_tags vocabulary first'),
}).strict().refine((input) => input.title !== undefined || input.tags !== undefined, {
    message: 'Provide a title, tags, or both',
})

export type ChangeSessionTitleInput = z.infer<typeof ChangeSessionTitleInputSchema>

export function sessionTagsInstruction(listTool: string, changeTool: string): string {
    const addTool = listTool.replace(/list_tags$/, 'add_tags')
    return `When the initial objective is clear, first call ${listTool} to read existing topic tags and the current session tags, then call ${changeTool} once with a concise title and 1–3 stable topic tags. Prefer relevant existing tags; create a new short topic tag when no existing tag fits. Tags are append-only: do not remove or replace user tags. Do not retag for routine progress, status, substeps or implementation details. If change_title is disabled or the title is locked, use ${addTool} to append tags independently; preserve the user's name. If tag tools are unavailable on an older Hub, report that limitation; never write tags through raw metadata.`
}
