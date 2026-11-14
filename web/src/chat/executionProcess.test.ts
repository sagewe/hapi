import { describe, expect, it } from 'vitest'
import { buildExecutionProcessBlocks, completedExecutionRounds, executionRoundTimings, stripNormalizedAgentSummaries } from './executionProcess'
import { initialResponseState } from './initialResponse'
import { normalizeDecryptedMessage } from './normalize'
import { buildSourceMessageIdsByBlock } from '@/lib/assistant-runtime'
import type { ChatBlock, ToolCallBlock, NormalizedMessage } from './types'
import type { ToolGroupBlock } from './toolGroups'
const text = (id: string, phase?: string): ChatBlock => ({ kind: 'agent-text', id, localId: null, createdAt: 1, text: id, meta: phase ? { assistantPhase: phase } : undefined })
const user = (id = 'u'): ChatBlock => ({ kind: 'user-text', id, localId: null, createdAt: 0, text: 'request' })
function tool(id: string, name = 'Bash', state: ToolCallBlock['tool']['state'] = 'completed'): ToolCallBlock {
    return { kind: 'tool-call', id, localId: null, createdAt: 1, children: [],
        tool: { id, name, state, input: {}, createdAt: 1, startedAt: 1, completedAt: 2, execStartedAt: null, execCompletedAt: null, description: null, result: 'ok' } }
}
const options = { isRunning: false, completedRounds: new Set(['u']), hasMoreMessages: false }
const process = (blocks: ReturnType<typeof buildExecutionProcessBlocks>) => blocks.filter((b): b is ToolGroupBlock => b.kind === 'tool-group' && b.processRole !== 'header')

describe('execution process projection', () => {
    it.each(['CodexBash', 'run_command', 'Bash', 'Shell'])('uses the same outer grouping for %s', (name) => {
        const input = [user(), text('progress', 'progress'), tool('tool', name), text('answer', 'final')]
        const output = buildExecutionProcessBlocks(input, options)
        expect(output.map(b => b.kind)).toEqual(['user-text', 'tool-group', 'agent-text'])
        expect(process(output)[0].processBlocks?.map(b => b.id)).toEqual(['progress', 'tool'])
        expect(process(output)[0].defaultOpen).toBe(false)
        expect(input).toHaveLength(4)
    })
    it('keeps interleaved failures and concurrent tools in one process per turn', () => {
        const input = [user(), text('progress', 'progress'), tool('failed', 'Bash', 'error'),
            tool('parallel-a', 'Bash', 'running'), text('update', 'progress'), tool('finished'),
            tool('parallel-b', 'Bash', 'running'), text('answer', 'final')]
        const output = buildExecutionProcessBlocks(input, { ...options, isRunning: true })
        expect(process(output)).toHaveLength(1)
        expect(output.filter(b => b.kind === 'tool-call')).toHaveLength(0)
        expect(process(output)[0].summary).toMatchObject({ runningCount: 2, errorCount: 1 })
        expect(process(output)[0].processBlocks?.map(b => b.id)).toEqual(input.slice(1, -1).map(b => b.id))
    })
    it('keeps current activity visible, then folds it under the same identity on completion', () => {
        const input = [user(), tool('earlier'), text('progress', 'progress'), tool('tool')]
        const first = buildExecutionProcessBlocks(input, { ...options, isRunning: true, completedRounds: new Set() })
        expect(first.map(b => b.kind)).toEqual(['user-text', 'tool-group', 'tool-group', 'agent-text', 'tool-group'])
        expect(first.filter(b => b.kind === 'agent-text').map(b => b.id)).toEqual(['progress'])
        expect(process(first).flatMap(group => group.tools.map(b => b.id))).toEqual(['earlier', 'tool'])
        expect(input.at(-1)).not.toHaveProperty('executionActivity')
        const next = buildExecutionProcessBlocks([...input, text('answer', 'final')], { ...options, previousGroups: process(first) })
        expect(process(next)[0].id).toBe(process(first)[0].id)
        expect(process(next)[0].processBlocks?.map(b => b.id)).toEqual(['earlier', 'progress', 'tool'])
        expect(next.at(-1)?.id).toBe('answer')
    })
    it.each(['progress', undefined])('retains the latest explanation through tool activity (%s)', phase => {
        const input = [user(), text('intro', phase), text('detail', phase)]
        for (const state of ['running', 'completed', 'error'] as const) {
            const steps = [...input, tool('first', 'Bash', state), tool('second', 'Bash', 'running')]
            const live = buildExecutionProcessBlocks(steps, { ...options, isRunning: true })
            expect(live.filter(b => b.kind === 'agent-text').map(b => b.id)).toEqual(['intro', 'detail'])
            const updated = buildExecutionProcessBlocks([...steps, text('update', phase), tool('third')], { ...options, isRunning: true })
            expect(updated.filter(b => b.kind === 'agent-text').map(b => b.id)).toEqual(['intro', 'detail', 'update'])
            const final = buildExecutionProcessBlocks([...steps, text('answer', 'final')], { ...options, isRunning: true })
            expect(final.filter(b => b.kind === 'agent-text').map(b => b.id)).toEqual(['answer'])
            expect(process(final)).toHaveLength(1)
        }
    })
    it('uses the full round span and freezes on completion, independent of parallel tools', () => {
        const input = [user(), { ...text('progress', 'progress'), createdAt: 1000 }, tool('a', 'Bash', 'running'), tool('b', 'Bash', 'running')]
        const roundTimings = new Map([['u', { startedAt: 1000, endedAt: 41000 }]])
        const live = buildExecutionProcessBlocks(input, { ...options, isRunning: true, roundTimings })
        expect(live.map(b => b.kind)).toEqual(['user-text', 'tool-group', 'agent-text', 'tool-group'])
        expect((live[1] as ToolGroupBlock).processTiming).toEqual({ startedAt: 1000, endedAt: 41000, running: true })
        const settled = buildExecutionProcessBlocks([...input, text('answer', 'final')], { ...options, roundTimings, previousGroups: process(live) })
        expect(process(settled)[0].processTiming?.running).toBe(false)
        expect(process(settled)[0]).not.toBe(process(live)[0])
        const partial = buildExecutionProcessBlocks(input.slice(1), { ...options, hasMoreMessages: true })
        expect(process(partial)[0].processTiming?.startedAt).toBeNull()
    })
    it('times invocation through root ready, ignoring sidechains and child completion', () => {
        const base = { localId: null, isSidechain: false, createdAt: 5000 }
        const messages: NormalizedMessage[] = [
            { ...base, id: 'u', role: 'user', invokedAt: 1000, content: { type: 'text', text: 'request' } },
            { ...base, id: 'text', role: 'agent', content: [{ type: 'text', text: 'work', uuid: 'text', parentUUID: null }] },
            { ...base, id: 'ready', createdAt: 12000, role: 'event', content: { type: 'ready' } },
            { ...base, id: 'late', createdAt: 88000, role: 'agent', content: [{ type: 'tool-result', tool_use_id: 'tool', content: 'late output', is_error: false, uuid: 'late', parentUUID: null }] },
            { ...base, id: 'read-image', createdAt: 90000, role: 'agent', content: [{ type: 'generated-image', imageId: 'img', fileName: 'input.png', mimeType: 'image/png', uuid: 'read-image', parentUUID: null, source: { ingress: 'tool_result', toolName: 'view_image' } }] },
            { ...base, id: 'child', createdAt: 99000, role: 'event', content: { type: 'ready', agentId: 'child' } }
        ]
        expect(executionRoundTimings(messages).get('u')).toEqual({ startedAt: 1000, endedAt: 12000 })
    })
    it('folds inspected screenshots but preserves explicit display and generated media', () => {
        const inspected: ChatBlock = { kind: 'generated-image', id: 'inspect', localId: null, createdAt: 3,
            imageId: 'image', fileName: 'input.png', mimeType: 'image/png',
            source: { ingress: 'tool_result', toolName: 'view_image' } }
        const live = buildExecutionProcessBlocks([user(), text('progress', 'progress'), tool('read'), inspected], { ...options, isRunning: true })
        expect(live.map(b => b.kind)).toEqual(['user-text', 'tool-group', 'agent-text', 'tool-group'])
        expect(process(live)[0].processBlocks).toContain(inspected)
        for (const source of [undefined, { ingress: 'mcp' as const, toolName: 'display_image' }, { ingress: 'tool_result' as const, toolName: 'hapi_display_image' }]) {
            const displayed = { ...inspected, source }
            expect(buildExecutionProcessBlocks([user(), tool('read'), displayed], { ...options, isRunning: true })).toContain(displayed)
        }
    })
    it('keeps all live prose in order and protects the timeline while it is being read', () => {
        const input = [user(), text('first', 'progress'), tool('a'), text('second', 'progress'), tool('b')]
        const live = buildExecutionProcessBlocks(input, { ...options, isRunning: true })
        expect(live.map(b => b.kind === 'tool-group' ? b.processRole : b.id)).toEqual(['u', 'header', 'first', 'tools', 'second', 'tools'])
        const held = buildExecutionProcessBlocks([...input, text('final', 'final')], { ...options, previousGroups: process(live), keepVisibleIds: new Set(['first']) })
        expect(held.filter(b => b.kind === 'agent-text').map(b => b.id)).toEqual(['first', 'second', 'final'])
        expect(process(held).map(b => b.id)).toEqual(process(live).map(b => b.id))
        const settled = buildExecutionProcessBlocks([...input, text('final', 'final')], { ...options, previousGroups: process(live) })
        expect(settled.map(b => b.kind)).toEqual(['user-text', 'tool-group', 'agent-text'])
    })
    it('keeps pending requests, questions, plans and user shell commands outside', () => {
        const permission = tool('permission'); permission.tool.permission = { id: 'p', status: 'pending' }
        const shell = tool('shell'); shell.tool.input = { command_source: 'userShell' }
        const protectedBlocks = [permission,
            tool('question', 'request_user_input'), tool('plan', 'ExitPlanMode'), shell]
        const output = buildExecutionProcessBlocks([user(), tool('work'), ...protectedBlocks, tool('later-work'), text('answer')], options)
        for (const block of protectedBlocks) expect(output.some(value => value.id === block.id)).toBe(true)
        expect(process(output)).toHaveLength(1)
        expect(process(output)[0].tools.map(tool => tool.id)).toEqual(['work', 'later-work'])
    })
    it('keeps decision context visible with an unanswered question', () => {
        const context = text('decision-context', 'progress')
        const question = tool('question', 'request_user_input')
        const output = buildExecutionProcessBlocks([user(), tool('work'), context, question], { ...options, isRunning: true })
        expect(output).toContain(context)
        expect(output).toContain(question)
    })
    it('folds explicitly resolved questions while retaining their recorded answers', () => {
        const answered = tool('answered', 'request_user_input')
        answered.tool.permission = { id: 'answer-request', status: 'resolved', answers: { question: ['Yes'] } }
        const output = buildExecutionProcessBlocks([user(), answered, text('answer')], options)
        expect(process(output)[0].tools[0].tool.permission?.answers).toEqual({ question: ['Yes'] })
        expect(output).not.toContain(answered)
    })
    it('does not hide multiple answer paragraphs, including legacy unmarked streaming text', () => {
        const input = [user(), tool('work'), text('part-1'), text('part-2')]
        for (const isRunning of [true, false]) {
            const output = buildExecutionProcessBlocks(input, { ...options, isRunning })
            expect(output.filter(b => b.kind === 'agent-text').map(b => b.id)).toEqual(['part-1', 'part-2'])
        }
    })
    it('honors a native final phase even if more tools arrive later', () => {
        const answer = text('answer', 'final')
        const output = buildExecutionProcessBlocks([user(), answer, tool('late-tool'), text('late-progress', 'progress')], options)
        expect(output).toContain(answer)
    })
    it('pins content the user is reading and preserves source ids for search/fork ownership', () => {
        const progress = text('progress', 'progress')
        const output = buildExecutionProcessBlocks([user(), progress, tool('work'), text('answer')], { ...options, keepVisibleIds: new Set(['progress']) })
        expect(output).toContain(progress)
        const grouped = buildExecutionProcessBlocks([user(), progress, tool('work'), text('answer')], options)
        expect(buildSourceMessageIdsByBlock(grouped).get(process(grouped)[0])).toEqual(['progress', 'answer'])
    })
    it('keeps partial-history group identities stable when an older page arrives', () => {
        const first = buildExecutionProcessBlocks([tool('second'), tool('third'), text('answer')], { ...options, hasMoreMessages: true })
        expect(process(first)[0].needsOlderHistory).toBe(true)
        const next = buildExecutionProcessBlocks([user(), tool('first'), tool('second'), tool('third'), text('answer')], { ...options, previousGroups: process(first) })
        expect(process(next)[0].id).toBe(process(first)[0].id)
        expect(process(next)[0].needsOlderHistory).toBe(false)
    })
    it('keeps identities unique when a previously grown process gains an error', () => {
        const first = buildExecutionProcessBlocks([tool('c'), tool('d'), text('answer')], options)
        const grown = buildExecutionProcessBlocks([tool('a'), tool('b'), tool('c'), tool('d'), text('answer')], { ...options, previousGroups: process(first) })
        const split = buildExecutionProcessBlocks([tool('a'), tool('b'), tool('error', 'Bash', 'error'), tool('c'), tool('d'), text('answer')], { ...options, previousGroups: process(grown) })
        expect(process(split)).toHaveLength(1)
        expect(new Set(split.map(block => block.id)).size).toBe(split.length)
    })
    it('reuses settled process objects across unrelated streaming updates', () => {
        const prefix = [user(), text('progress', 'progress'), tool('work')]
        const first = buildExecutionProcessBlocks([...prefix, text('live', 'final')], options)
        const next = buildExecutionProcessBlocks([...prefix, text('live', 'final')], { ...options, previousGroups: process(first) })
        expect(process(next)[0]).toBe(process(first)[0])
    })
    it('does not cross a user boundary', () => {
        const output = buildExecutionProcessBlocks([user('u1'), tool('one'), text('a1'), user('u2'), tool('two'), text('a2')], options)
        expect(process(output).map(group => group.processBlocks?.map(b => b.id))).toEqual([['one'], ['two']])
    })
    it('uses explicit root completion events and invalidates them when a continuation starts', () => {
        const base = { localId: null, createdAt: 1, isSidechain: false }
        const rows: NormalizedMessage[] = [
            { ...base, id: 'u', role: 'user', content: { type: 'text', text: 'request' } },
            { ...base, id: 'ready', role: 'event', content: { type: 'ready' } }
        ]
        expect(completedExecutionRounds(rows).has('u')).toBe(true)
        rows.push({ ...base, id: 'new', role: 'agent', content: [{ type: 'text', text: 'continue', uuid: 'new', parentUUID: null }] })
        expect(completedExecutionRounds(rows).has('u')).toBe(false)
    })
    it('withholds execution-timer header while a running round only has non-substantive events', () => {
        const eventOnly: ChatBlock = {
            kind: 'agent-event',
            id: 'title-event',
            createdAt: 4177,
            event: { type: 'message', message: 'Title' }
        }
        const blankReasoning: ChatBlock = {
            kind: 'agent-reasoning',
            id: 'blank-reasoning',
            localId: null,
            createdAt: 4200,
            text: '   '
        }
        const beforeOutput = buildExecutionProcessBlocks([user(), eventOnly, blankReasoning], {
            ...options,
            isRunning: true,
            completedRounds: new Set()
        })
        expect(beforeOutput.some(b => b.id.startsWith('execution-timer:'))).toBe(false)
        expect(initialResponseState(beforeOutput, { isSending: false, isRunning: true, isActive: true })).toBe('waiting')

        const afterOutput = buildExecutionProcessBlocks([user(), eventOnly, text('progress', 'progress')], {
            ...options,
            isRunning: true,
            completedRounds: new Set()
        })
        expect(afterOutput.some(b => b.id === 'execution-timer:u')).toBe(true)
        expect(initialResponseState(afterOutput, { isSending: false, isRunning: true, isActive: true })).toBeNull()
    })
    it('ignores summary items in timings and completion and strips them via stripNormalizedAgentSummaries', () => {
        const summaryWire = normalizeDecryptedMessage({
            id: 'sum-1',
            seq: 3,
            localId: null,
            createdAt: 4177,
            content: { role: 'agent', content: { type: 'output', data: { type: 'summary', summary: 'Hapi iOS Missing Quick Mode' } } }
        })
        if (!summaryWire) throw new Error('Expected summary wire message to normalize')
        expect(stripNormalizedAgentSummaries(summaryWire)).toBeNull()

        const mixed: NormalizedMessage = {
            id: 'mixed',
            localId: null,
            createdAt: 5000,
            isSidechain: false,
            role: 'agent',
            content: [
                { type: 'summary', summary: 'Ignored title' },
                { type: 'text', text: 'real reply', uuid: 'r1', parentUUID: null }
            ]
        }
        expect(stripNormalizedAgentSummaries(mixed)).toEqual({
            ...mixed,
            content: [{ type: 'text', text: 'real reply', uuid: 'r1', parentUUID: null }]
        })

        const userRow: NormalizedMessage = {
            id: 'u',
            localId: 'loc-1',
            createdAt: 1000,
            invokedAt: 1000,
            isSidechain: false,
            role: 'user',
            content: { type: 'text', text: 'hello' }
        }
        const readyRow: NormalizedMessage = {
            id: 'ready-1',
            localId: null,
            createdAt: 3000,
            isSidechain: false,
            role: 'event',
            content: { type: 'ready' }
        }
        expect(executionRoundTimings([userRow, { ...summaryWire, createdAt: 4177 }, readyRow]).get('u')).toEqual({
            startedAt: 1000,
            endedAt: 3000
        })
        expect(completedExecutionRounds([userRow, readyRow, summaryWire]).has('u')).toBe(true)
    })
})
