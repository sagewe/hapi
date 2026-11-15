import { describe, expect, it } from 'vitest'
import { ChangeSessionTitleInputSchema, sessionTagsInstruction } from './sessionTagTools'
import { TITLE_INSTRUCTION } from '@/codex/utils/systemPrompt'
import { getSystemPrompt as getClaudeSystemPrompt } from '@/claude/utils/systemPrompt'
import { HAPI_MCP_BRIDGE_PROMPT } from './hapiMcpBridgePrompt'

describe('session tag tool instructions and request validation', () => {
    it('accepts a title, tags, or both while rejecting an empty request', () => {
        expect(ChangeSessionTitleInputSchema.safeParse({ title: 'Topic' }).success).toBe(true)
        expect(ChangeSessionTitleInputSchema.parse({ tags: [' Topic ', 'topic'] })).toEqual({ tags: ['Topic'] })
        expect(ChangeSessionTitleInputSchema.safeParse({ title: 'Topic', tags: ['network'] }).success).toBe(true)
        expect(ChangeSessionTitleInputSchema.safeParse({}).success).toBe(false)
        expect(ChangeSessionTitleInputSchema.safeParse({ tags: ['a', 'b', 'c', 'd'] }).success).toBe(false)
        expect(ChangeSessionTitleInputSchema.safeParse({ tags: ['topic'], sessionId: 'other' }).success).toBe(false)
    })

    it('instructs actual Codex, Claude and common MCP paths to reuse vocabulary without progress retagging', () => {
        for (const [prompt, prefix] of [[TITLE_INSTRUCTION, 'functions.hapi__'], [getClaudeSystemPrompt(), 'mcp__hapi__'], [HAPI_MCP_BRIDGE_PROMPT, 'hapi_']]) {
            expect(prompt).toContain(`${prefix}list_tags`)
            expect(prompt).toContain(`${prefix}add_tags`)
            expect(prompt).toContain('1–3 stable topic tags')
            expect(prompt).toContain('do not remove or replace user tags')
            expect(prompt).toContain('Do not retag for routine progress')
        }
        expect(sessionTagsInstruction('hapi_list_tags', 'hapi_change_title')).toContain('never write tags through raw metadata')
    })
})
