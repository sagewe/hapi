import type { FixtureCase } from '../fixtureTypes'
import { T0, wireMessage } from './support'

/**
 * agy (Antigravity) flavor: NOT the codex family — entries arrive through the
 * Claude-style output envelope (content.type === 'output') with
 * data.type === 'agy_message' (planner prose) and 'agy_tool_action' (a DONE
 * tool action whose content is its result). See normalizeAgent.ts (agy
 * branches) and cli/src/api/apiSession.ts sendAgySessionMessage.
 */
export const agyCases: FixtureCase[] = [
    {
        name: 'agy-message',
        description: 'agy flavor: agy_message planner prose becomes a plain agent-text block (per-turn data.model is footer metadata outside the normative projection; meta.sentFrom cli is carried on the wire but dropped).',
        messages: [
            wireMessage({
                id: 'msg-agy-721',
                seq: 1,
                createdAt: T0,
                content: {
                    role: 'agent',
                    content: {
                        type: 'output',
                        data: {
                            type: 'agy_message',
                            content: 'Looking at the failing build, the Gradle wrapper version is stale. I will bump it and rerun.',
                            model: 'Gemini 3 Pro (High)'
                        }
                    },
                    meta: { sentFrom: 'cli' }
                }
            })
        ]
    },
    {
        name: 'agy-tool-action-run-command',
        description: 'agy flavor: agy_tool_action RUN_COMMAND with a paired run_command invocation maps to a canonical Bash tool-call (input.CommandLine/Cwd translated to command/cwd, bookkeeping args dropped) already COMPLETED (paired tool-result), keyed by data.toolUseId with the Created At/Completed At preamble stripped from the result.',
        messages: [
            wireMessage({
                id: 'msg-agy-731',
                seq: 1,
                createdAt: T0,
                content: {
                    role: 'agent',
                    content: {
                        type: 'output',
                        data: {
                            type: 'agy_tool_action',
                            name: 'RUN_COMMAND',
                            toolName: 'run_command',
                            toolUseId: 'conv-7c1b:12',
                            input: {
                                CommandLine: './gradlew --version',
                                Cwd: '/repo/android',
                                toolSummary: 'Check Gradle version',
                                WaitMsBeforeAsync: 5000,
                                Blocking: true
                            },
                            content: 'Created At: 2025-08-12T11:20:04Z\nCompleted At: 2025-08-12T11:20:06Z\nThe command completed successfully.\nOutput:\nGradle 8.7'
                        }
                    },
                    meta: { sentFrom: 'cli' }
                }
            })
        ]
    }
]

// Canonical wire payloads emitted by the personal ACP driver for live tools
// and transcript-only continuations. Driver tests separately pin the native
// arguments -> wire transform; these pin Web/native rendering parity.
agyCases.push(...[
    { suffix: 'delete-edit', name: 'Edit', input: { file_path: '/repo/a.txt', old_string: 'remove me', new_string: '' }, output: {} },
    { suffix: 'empty-write', name: 'Write', input: { file_path: '/repo/empty.txt', content: '' }, output: {} },
    { suffix: 'shell', name: 'Bash', input: { command: 'printf done', cwd: '/repo' }, output: { stdout: 'done', exit_code: 0 } },
    { suffix: 'artifact-plan', name: 'ExitPlanMode', input: { plan: '# Task plan\n\nCheck the test result.' }, output: {} },
    { suffix: 'subagent', name: 'Task', input: { description: 'Review', prompt: 'Inspect the changes', subagent_type: 'reviewer' }, output: {} },
    { suffix: 'mcp', name: 'mcp__docs__search', input: { query: 'tool cards' }, output: { text: 'Found' } }
].map(({ suffix, name, input, output }): FixtureCase => ({
    name: `agy-acp-canonical-${suffix}`,
    description: 'agy ACP canonical tool wire contract: stable callId, meaningful empty strings and canonical tool selection.',
    messages: [
        wireMessage({ id: `agy-${suffix}-call`, seq: 1, createdAt: T0,
            content: { role: 'agent', content: { type: 'codex', data: {
                type: 'tool-call', callId: `agy-${suffix}`, name, input, status: 'completed'
            } } } }),
        wireMessage({ id: `agy-${suffix}-result`, seq: 2, createdAt: T0 + 1000,
            content: { role: 'agent', content: { type: 'codex', data: {
                type: 'tool-call-result', callId: `agy-${suffix}`, output, is_error: false
            } } } })
    ]
})));
