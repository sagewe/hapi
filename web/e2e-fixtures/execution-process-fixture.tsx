import { useMemo, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { AssistantRuntimeProvider } from '@assistant-ui/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { buildExecutionProcessBlocks } from '../src/chat/executionProcess'
import type { ChatBlock, ToolCallBlock } from '../src/chat/types'
import type { ToolGroupBlock } from '../src/chat/toolGroups'
import { useHappyRuntime } from '../src/lib/assistant-runtime'
import { HappyThread } from '../src/components/AssistantChat/HappyThread'
import { I18nProvider } from '../src/lib/i18n-context'
import type { ApiClient } from '../src/api/client'
import type { Session } from '../src/types/api'
import '../src/index.css'

const flavor = new URLSearchParams(location.search).get('agent') ?? 'codex'
const api = { getSubscriptionUsage: async () => ({ providers: [] }) } as unknown as ApiClient
const text = (id: string, value: string, phase: string): ChatBlock => ({ kind: 'agent-text', id, createdAt: 1, localId: null, text: value, meta: flavor === 'codex' ? { assistantPhase: phase } : undefined })
function tool(id: string, running = false, failed = false): ToolCallBlock {
    return { kind: 'tool-call', id, localId: null, createdAt: 2, children: [], tool: {
        id, name: flavor === 'codex' ? 'CodexBash' : 'run_command', state: failed ? 'error' : running ? 'running' : 'completed',
        input: { command: `echo ${id}`, CommandLine: `echo ${id}` }, result: { output: `${id} finished` }, description: null,
        createdAt: 2, startedAt: 2, completedAt: running ? null : 3, execStartedAt: null, execCompletedAt: null
    } }
}
function Fixture() {
    const [done, setDone] = useState(false)
    const [failed, setFailed] = useState(false)
    const [extra, setExtra] = useState(false)
    const [held, setHeld] = useState<ReadonlySet<string>>(new Set())
    const previous = useRef<ToolGroupBlock[]>([])
    const previousActivityIds = useRef<ReadonlySet<string>>(new Set())
    const session = { id: 'process-fixture', active: true, thinking: !done, agentState: null,
        metadata: { path: '/tmp/fixture', host: 'fixture', flavor } } as unknown as Session
    const blocks = useMemo(() => {
        const canonical: ChatBlock[] = [
            { kind: 'user-text', id: 'user', localId: null, createdAt: 0, text: 'Inspect and report' },
            text('progress', 'Inspecting the fixture.', 'progress'), tool('first-check'),
            text('progress-2', 'Checking the result.', 'progress'), tool('current-check', !done, failed),
            ...(done ? [text('final', 'Final answer stays visible.', 'final')] : []),
            ...(extra ? [text('extra', 'Additional final paragraph.', 'final')] : [])
        ]
        const projected = buildExecutionProcessBlocks(canonical, { isRunning: !done, hasMoreMessages: false, keepVisibleIds: held, previousActivityIds: previousActivityIds.current,
            completedRounds: done ? new Set(['user']) : new Set(), previousGroups: previous.current })
        previousActivityIds.current = new Set(projected.filter(block => block.kind === 'tool-call' && block.executionActivity).map(block => block.id))
        previous.current = projected.filter((b): b is ToolGroupBlock => b.kind === 'tool-group')
        return projected
    }, [done, extra, held, failed])
    ;(window as unknown as { completeProcess: () => void }).completeProcess = () => setDone(true)
    ;(window as unknown as { failProcess: () => void }).failProcess = () => { setFailed(true); setDone(true) }
    const runtime = useHappyRuntime({ session, blocks, messagesVersion: Number(done) + Number(extra), historyVersion: 0,
        isRunning: !done, isSending: false, onSendMessage: () => {}, onAbort: async () => {} })
    return <AssistantRuntimeProvider runtime={runtime}>
        <main className="mx-auto flex h-screen max-w-2xl flex-col" onPointerDownCapture={(event) => {
            if (event.target instanceof Element && event.target.closest('[data-hapi-message-role="assistant"]')) {
                setHeld(previous => new Set([...previous, ...blocks.filter(block => block.kind !== 'tool-group').map(block => block.id)]))
            }
        }}>
            <header className="flex shrink-0 gap-4 p-3">
                <button onClick={() => setDone(true)}>Complete turn</button>
                <button onClick={() => setExtra(true)}>Add paragraph</button>
            </header>
            <HappyThread api={api} session={session} sessionId={session.id} metadata={session.metadata} disabled={false}
                onRefresh={() => {}} onExecutionInspect={(id) => setHeld(previous => new Set([...previous, id]))} onViewModeChange={() => {}} isSyncingTail={false} hasMoreMessages={false} isLoadingMoreMessages={false}
                unseenCount={0} messagesVersion={Number(done) + Number(extra)} historyVersion={0} />
        </main>
    </AssistantRuntimeProvider>
}
createRoot(document.getElementById('root')!).render(<QueryClientProvider client={new QueryClient()}><I18nProvider><Fixture /></I18nProvider></QueryClientProvider>)
