import type { FixtureCase } from '../fixtureTypes'
import { T0, wireMessage } from './support'

const question = { question: 'Which mode?', options: [{ label: 'One' }], multiSelect: false }
const call = (input: unknown) => wireMessage({ id: 'agy-form-call', seq: 1, createdAt: T0, content: {
    role: 'agent', content: { type: 'output', data: {
        type: 'assistant', uuid: 'agy-form-call', parentUuid: null,
        message: { role: 'assistant', content: [{ type: 'tool_use', id: 'agy-question', name: 'AskUserQuestion', input }] }
    } }
} })

export const agyFormCases: FixtureCase[] = [
    {
        name: 'agy-form-fixed-choice-pending',
        description: 'A pending agy form adds the missing allowFreeText=false flag to an earlier tool call; labels and input are retained.',
        messages: [call({ questions: [question] })],
        agentState: { requests: { 'agy-question': {
            tool: 'AskUserQuestion', arguments: { questions: [{ ...question, allowFreeText: false }] }, createdAt: T0 + 1
        } } }
    },
    {
        name: 'agy-form-text-only-pending',
        description: 'A free-text-only agy form has no choices and explicitly permits typed answers, including synthesized request-only cards.',
        messages: [wireMessage({ id: 'agy-text-user', seq: 1, createdAt: T0 - 1, content: {
            role: 'user', content: { type: 'text', text: 'Ask me for an explanation.' }
        } })],
        agentState: { requests: { 'agy-text': {
            tool: 'AskUserQuestion', arguments: { questions: [{ question: 'Explain?', options: [], multiSelect: false, allowFreeText: true }] }, createdAt: T0
        } } }
    },
    {
        name: 'agy-form-fixed-choice-completed',
        description: 'Historical completed form metadata retains the fixed-choice policy and the actual chosen label.',
        messages: [call({ questions: [question] })],
        agentState: { completedRequests: { 'agy-question': {
            tool: 'AskUserQuestion', arguments: { questions: [{ ...question, allowFreeText: false }] }, createdAt: T0 + 1,
            completedAt: T0 + 2, status: 'approved', answers: { '0': ['One'] }
        } } }
    }
]
