import { expect, it } from 'vitest'
import type { ChatBlock, ToolCallBlock } from './types'
import { executionDetailSections } from './executionDetails'
const text = (id: string): ChatBlock => ({ kind: 'agent-text', id, localId: null, createdAt: 1, text: id })
const tool = (id: string): ToolCallBlock => ({ kind: 'tool-call', id, localId: null, createdAt: 1, children: [], tool: {
    id, name: 'Bash', input: {}, state: 'completed', result: 'ok', description: null, createdAt: 1,
    startedAt: 1, completedAt: 2, execStartedAt: null, execCompletedAt: null } })
it('preserves prose between consecutive tool groups without dropping steps', () => {
    const blocks = [text('plan'), tool('a'), tool('b'), text('progress'), tool('c')]
    const sections = executionDetailSections(blocks)
    expect(sections.map(s => s.kind)).toEqual(['text', 'tools', 'text', 'tools'])
    expect(sections.flatMap(s => s.kind === 'tools' ? s.blocks : [s.block])).toEqual(blocks)
})
it('keeps an expanded group identity when older tools are prepended or results update', () => {
    const before = executionDetailSections([tool('b'), tool('c')])
    const after = executionDetailSections([tool('a'), tool('b'), tool('c')], before)
    expect(after[0].id).toBe(before[0].id)
})
