import { isSubagentToolName } from './subagentTool'
import { isObject } from '@hapi/protocol'
import type { ChatBlock, NormalizedMessage, ToolCallBlock } from './types'
import { isInteractiveToolBlock, summarizeToolGroup, type ToolGroupBlock, type VisibleChatBlock } from './toolGroups'

/** Receive timestamps span the root round; parallel tool durations are never summed. */
export function executionRoundTimings(messages: readonly NormalizedMessage[]): Map<string, { startedAt: number; endedAt: number }> {
    const result = new Map<string, { startedAt: number; endedAt: number }>()
    let round = 'initial'
    for (const message of messages) {
        if (message.isSidechain) continue
        if (message.role === 'user') {
            round = message.id
            if (message.invokedAt != null) result.set(round, { startedAt: message.invokedAt, endedAt: message.invokedAt })
            continue
        }
        const agent = message.role === 'agent' && message.content.some(content => content.type !== 'tool-result'
            && !(content.type === 'generated-image' && content.source?.ingress === 'tool_result' && content.source.toolName === 'view_image'))
        const ready = message.role === 'event' && message.content.type === 'ready'
            && (!('agentId' in message.content) || !message.content.agentId)
        const prior = result.get(round)
        if (agent || (ready && prior)) result.set(round, {
            startedAt: prior?.startedAt ?? message.createdAt,
            endedAt: Math.max(prior?.endedAt ?? message.createdAt, message.createdAt)
        })
    }
    return result
}

export const INITIAL_EXECUTION_ROUND = 'initial'

/** Ready is a lifecycle signal, not a phrase guessed from the agent's prose. */
export function completedExecutionRounds(messages: readonly NormalizedMessage[]): Set<string> {
    const completed = new Set<string>()
    let round = INITIAL_EXECUTION_ROUND
    for (const message of messages) {
        if (message.isSidechain) continue
        if (message.role === 'user') round = message.id
        else if (message.role === 'event' && message.content.type === 'ready' && (!('agentId' in message.content) || message.content.agentId == null || message.content.agentId === '')) completed.add(round)
        else if (message.role === 'agent' && message.content.length > 0) completed.delete(round)
    }
    return completed
}

function protectedTool(block: ToolCallBlock): boolean {
    const permission = block.tool.permission
    const handled = permission && ['approved', 'resolved', 'canceled'].includes(permission.status) && !permission.reason
    if (isInteractiveToolBlock(block) && !handled) return true
    const name = block.tool.name.toLowerCase().replace(/[^a-z0-9]/g, '')
    if (['exitplanmode', 'cursorcreateplan'].includes(name)) return true
    const input = block.tool.input
    if (isObject(input) && String(input.command_source ?? input.commandSource ?? '').toLowerCase() === 'usershell') return true
    return block.children.some(child => (child.kind === 'tool-call' && protectedTool(child))
        || (child.kind === 'agent-event' && ['error', 'limit-reached'].includes(child.event.type)))
}

const activityCache = new WeakMap<ToolCallBlock, ToolCallBlock>()
function asActivity(block: ToolCallBlock): ToolCallBlock {
    const cached = activityCache.get(block)
    if (cached) return cached
    const value = { ...block, executionActivity: true }
    activityCache.set(block, value)
    return value
}
function activityPresentation(block: ChatBlock, keepInspector: boolean): ChatBlock {
    if (block.kind !== 'tool-call') return block
    if (keepInspector) return asActivity(block)
    if (block.tool.state === 'error' || isInteractiveToolBlock(block) || isSubagentToolName(block.tool.name) || block.children.length > 0) return block
    const name = block.tool.name.toLowerCase().replace(/[^a-z0-9]/g, '')
    if (['exitplanmode', 'cursorcreateplan'].includes(name)) return block
    if (isObject(block.tool.input) && String(block.tool.input.command_source ?? block.tool.input.commandSource ?? '').toLowerCase() === 'usershell') return block
    return asActivity(block)
}

function foldable(block: ChatBlock): boolean {
    if (block.kind === 'agent-text') return !isObject(block.meta) || block.meta.assistantPhase !== 'final'
    if (block.kind === 'agent-reasoning') return true
    if (block.kind === 'generated-image') return block.source?.ingress === 'tool_result' && block.source.toolName === 'view_image'
    return block.kind === 'tool-call' && !protectedTool(block)
}

export type ExecutionProcessOptions = {
    roundTimings?: ReadonlyMap<string, { startedAt: number; endedAt: number }>
    completedRounds: ReadonlySet<string>
    isRunning: boolean
    hasMoreMessages: boolean
    keepVisibleIds?: ReadonlySet<string>
    previousGroups?: readonly ToolGroupBlock[]
    previousActivityIds?: ReadonlySet<string>
}

/** Presentation only: canonical history, tool identities and results are retained.
 * This outer layer is provider-neutral; tool-specific views remain inside it. */
export function buildExecutionProcessBlocks(blocks: readonly ChatBlock[], options: ExecutionProcessOptions): VisibleChatBlock[] {
    const output: VisibleChatBlock[] = []
    const used = new Set<string>()
    const rawIds = new Set(blocks.map(block => block.id))
    const reserved = new Set([...rawIds, ...(options.previousGroups ?? []).map(group => group.id)])
    const previousByMember = new Map<string, ToolGroupBlock>()
    for (const group of options.previousGroups ?? []) for (const member of group.processBlocks ?? []) {
        if (!previousByMember.has(member.id)) previousByMember.set(member.id, group)
    }
    let roundId = INITIAL_EXECUTION_ROUND
    let round: ChatBlock[] = []
    const flush = (tail: boolean) => {
        if (!round.length) return
        const completed = options.completedRounds.has(roundId) && !(tail && options.isRunning)
        const roundStartIndex = output.length
        const observed = options.roundTimings?.get(roundId)
        const timestamps = round.flatMap(block => block.kind === 'tool-call'
            ? [block.createdAt, block.tool.completedAt ?? block.createdAt] : [block.createdAt])
        const processTiming = {
            startedAt: options.hasMoreMessages && roundId === INITIAL_EXECUTION_ROUND ? null : observed?.startedAt ?? Math.min(...timestamps),
            endedAt: observed?.endedAt ?? Math.max(...timestamps),
            running: tail && options.isRunning
        }
        let lastWork = -1
        round.forEach((block, index) => { if (block.kind === 'tool-call' || block.kind === 'agent-reasoning') lastWork = index })
        // Preserve all trailing answer paragraphs for older providers without phase metadata.
        const replies = new Set(round.filter((block, index) => block.kind === 'agent-text' && index > lastWork
            && (!isObject(block.meta) || block.meta.assistantPhase !== 'progress')).map(block => block.id))
        if (replies.size === 0) processTiming.endedAt = Math.max(processTiming.endedAt, ...timestamps)
        // A pending decision must keep the prose that explains what the user is answering.
        const decisionContext = new Set<string>()
        round.forEach((block, index) => {
            if (block.kind !== 'tool-call' || !isInteractiveToolBlock(block) || !protectedTool(block)) return
            for (let cursor = index - 1; cursor >= 0; cursor -= 1) {
                const prior = round[cursor]
                if (prior.kind === 'tool-call' || prior.kind === 'user-text' || prior.kind === 'cli-output') break
                if (prior.kind === 'agent-text') decisionContext.add(prior.id)
            }
        })
        // Tool events advance activity, not the explanation the user is reading.
        // Keep consecutive prose/reasoning until a new explanation or answer arrives.
        const explanation = new Set<string>()
        const hasFinal = round.some(block => block.kind === 'agent-text' && isObject(block.meta) && block.meta.assistantPhase === 'final')
        if (!completed && !hasFinal) {
            let cursor = round.findLastIndex(block => block.kind === 'agent-text' || block.kind === 'agent-reasoning')
            for (; cursor >= 0; cursor -= 1) {
                const block = round[cursor]
                if (block.kind === 'agent-event') continue
                if (block.kind !== 'agent-text' && block.kind !== 'agent-reasoning') break
                explanation.add(block.id)
            }
        }
        const latest = round.findLast(block => block.kind !== 'agent-event')?.id
        let members: ChatBlock[] = []
        const emit = () => {
            if (!members.length) return
            const previous = members.map(block => previousByMember.get(block.id))
                .find((group): group is ToolGroupBlock => Boolean(group && !used.has(group.id) && !rawIds.has(group.id)))
            const base = `execution-process:${members[0].id}`
            let id = previous?.id ?? base
            if (!previous) {
                let suffix = 2
                while (used.has(id) || reserved.has(id)) id = `${base}#${suffix++}`
            }
            used.add(id)
            const partial = options.hasMoreMessages && roundId === INITIAL_EXECUTION_ROUND
            if (previous?.processTiming?.startedAt === processTiming.startedAt && previous.processTiming.endedAt === processTiming.endedAt
                && previous.processTiming.running === processTiming.running
                && previous?.processBlocks?.length === members.length && previous.needsOlderHistory === partial
                && previous.processBlocks.every((block, index) => block === members[index])) {
                output.push(previous)
                members = []
                return
            }
            const tools = members.filter((block): block is ToolCallBlock => block.kind === 'tool-call')
            output.push({ kind: 'tool-group', id, createdAt: members[0].createdAt, invokedAt: members[0].invokedAt,
                firstToolId: members[0].id, lastToolId: members[members.length - 1].id, tools,
                processBlocks: members, processTiming, defaultOpen: false, needsOlderHistory: partial,
                historyState: partial ? 'needs-older-history' : 'complete', summary: summarizeToolGroup(tools),
                roundSummary: members.flatMap(block => 'roundSummary' in block && block.roundSummary ? [block.roundSummary] : [])[0] })
            members = []
        }
        let insertionIndex: number | null = null
        for (const block of round) {
            if (!foldable(block) || replies.has(block.id) || explanation.has(block.id) || decisionContext.has(block.id) || options.keepVisibleIds?.has(block.id)
                || ((!completed || replies.size === 0) && block.id === latest && block.kind !== 'tool-call' && block.kind !== 'generated-image')) {
                output.push(activityPresentation(block, Boolean(options.keepVisibleIds?.has(block.id) && options.previousActivityIds?.has(block.id))))
            } else {
                insertionIndex ??= output.length
                members.push(block)
            }
        }
        emit()
        if (insertionIndex !== null) {
            const group = output.pop()!
            output.splice(roundStartIndex, 0, group)
        }
        round = []
    }
    for (const block of blocks) {
        if (block.kind === 'user-text' || (block.kind === 'cli-output' && block.source === 'user')) {
            flush(false)
            roundId = block.id
            output.push(block)
        } else round.push(block)
    }
    flush(true)
    return output
}
