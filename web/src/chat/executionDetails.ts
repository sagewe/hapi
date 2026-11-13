import type { ChatBlock, ToolCallBlock } from './types'
export type ExecutionDetailSection = { id: string; kind: 'text'; block: ChatBlock }
    | { id: string; kind: 'tools'; blocks: ChatBlock[]; tools: ToolCallBlock[] }
/** Consecutive activity folds together; prose keeps its original position. */
export function executionDetailSections(blocks: readonly ChatBlock[], previous: readonly ExecutionDetailSection[] = []): ExecutionDetailSection[] {
    const result: ExecutionDetailSection[] = []
    const oldIDs = new Map(previous.flatMap(section => section.kind === 'tools' ? section.blocks.map(b => [b.id, section.id] as const) : []))
    const used = new Set<string>()
    let pending: ChatBlock[] = []
    const flush = () => {
        if (!pending.length) return
        const prior = pending.map(b => oldIDs.get(b.id)).find(id => id && !used.has(id))
        const id = prior ?? `execution-detail:${pending[0].id}`
        used.add(id)
        result.push({ kind: 'tools', id, blocks: pending, tools: pending.filter((b): b is ToolCallBlock => b.kind === 'tool-call') })
        pending = []
    }
    for (const block of blocks) {
        if (block.kind === 'tool-call' || (block.kind === 'generated-image' && block.source?.toolName === 'view_image' && block.source.ingress === 'tool_result')) pending.push(block)
        else { flush(); result.push({ id: block.id, kind: 'text', block }) }
    }
    flush()
    return result
}
