// Exercises the real message window, reducer, assistant runtime and scroll logic.
// Only the transport is fake; no Hub, Runner or user configuration is touched.
import { useMemo, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { AssistantRuntimeProvider } from '@assistant-ui/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import '../src/index.css'
import type { ApiClient } from '../src/api/client'
import type { DecryptedMessage, Session } from '../src/types/api'
import type { ChatBlock } from '../src/chat/types'
import { normalizeDecryptedMessage } from '../src/chat/normalize'
import { reduceChatBlocks } from '../src/chat/reducer'
import { reconcileChatBlocks } from '../src/chat/reconcile'
import { buildVisibleChatBlocks } from '../src/chat/toolGroups'
import { useHappyRuntime } from '../src/lib/assistant-runtime'
import { getMessageWindowState } from '../src/lib/message-window-store'
import { useMessages } from '../src/hooks/queries/useMessages'
import { I18nProvider } from '../src/lib/i18n-context'
import { HappyThread } from '../src/components/AssistantChat/HappyThread'
import { StatusBar } from '../src/components/AssistantChat/StatusBar'

const SESSION = 'pending-context-preview'
const BASE = 1_700_000_000_000
const requests = {
    question: { tool: 'AskUserQuestion', toolCallId: 'question-call:"[]', createdAt: BASE + 21,
        arguments: { questions: [{ header: 'Approach', question: 'Which historical approach?', multiSelect: false,
            options: [{ label: 'Small patch', description: 'Preserve scope' }] }] } },
    approval: { tool: 'Bash', toolCallId: 'approval-call', createdAt: BASE + 41, arguments: { command: 'git status --short' } }
}
const session = { id: SESSION, active: true, thinking: false, agentState: { requests },
    metadata: { path: '/tmp/fixture', host: 'fixture' } } as unknown as Session
const rows: DecryptedMessage[] = Array.from({ length: 100 }, (_, i) => ({
    id: `stored-${i + 1}`, seq: i + 1, localId: null, createdAt: BASE + i + 1, invokedAt: BASE + i + 1,
    content: i === 20 || i === 40 ? { role: 'agent', content: { type: 'codex', data: {
        type: 'tool-call', callId: i === 20 ? requests.question.toolCallId : requests.approval.toolCallId,
        name: i === 20 ? 'AskUserQuestion' : 'Bash', input: i === 20 ? requests.question.arguments : requests.approval.arguments
    } } } : { role: 'user', content: { type: 'text', text: `Historical context row ${i + 1}` } }
}))
const calls: string[] = []
const completedCalls: string[] = []
let releaseQuestion = () => {}
const questionGate = new URLSearchParams(location.search).has('holdQuestion')
    ? new Promise<void>(resolve => { releaseQuestion = resolve }) : null
Object.assign(window, { __pendingContextCalls: calls, __pendingContextCompleted: completedCalls, __releasePendingQuestion: () => releaseQuestion() })
const api = {
    getHubSettings: async () => ({ sessionSummaryInChat: false }),
    getMessages: async () => ({ messages: rows.slice(-8), page: {
        direction: 'latest', limit: 8, epoch: 0, reset: false, hasMore: true,
        nextBeforeAt: BASE + 93, nextBeforeSeq: 93, nextAfterAt: BASE + 100, nextAfterSeq: 100,
        snapshotHeadAt: BASE + 100, snapshotHeadSeq: 100
    } }),
    getMessageContext: async (_session: string, alias: string) => {
        calls.push(alias)
        if (alias.includes('question') && questionGate) await questionGate
        await new Promise(resolve => setTimeout(resolve, alias.includes('question') ? 180 : 30))
        completedCalls.push(alias)
        const seq = alias === `tool-call:${requests.question.toolCallId}` ? 21 : 41
        return { messages: rows.slice(seq - 5, seq + 8), targetMessageId: `stored-${seq}`, page: {
            epoch: 0, nextBeforeAt: BASE + seq - 4, nextBeforeSeq: seq - 4,
            snapshotHeadAt: BASE + 100, snapshotHeadSeq: 100, hasMore: true
        } }
    }
} as unknown as ApiClient

function Preview() {
    const [target, setTarget] = useState<{ id: string; version: number } | null>(null)
    const [selection, setSelection] = useState('none')
    const sequence = useRef(0)
    const windowState = useMessages(api, SESSION)
    const previous = useRef(new Map<string, ChatBlock>())
    const normalized = useMemo(() => windowState.messages.map(normalizeDecryptedMessage).filter(v => v !== null), [windowState.messages])
    const reduced = useMemo(() => reduceChatBlocks(normalized, session.agentState, { pendingRequestTargetId: target?.id }), [normalized, target])
    const reconciled = useMemo(() => reconcileChatBlocks(reduced.blocks, previous.current), [reduced.blocks])
    previous.current = reconciled.byId
    const blocks = useMemo(() => buildVisibleChatBlocks(reconciled.blocks, { hasMoreMessages: windowState.hasMore }), [reconciled.blocks, windowState.hasMore])
    const runtime = useHappyRuntime({ session, blocks, messagesVersion: windowState.messagesVersion,
        historyVersion: windowState.historyVersion, isSending: false, onSendMessage: () => {}, onAbort: async () => {} })
    const selected = selection === 'question' ? requests.question : requests.approval
    return <AssistantRuntimeProvider runtime={runtime}>
        <main className="flex h-dvh min-h-0 flex-col bg-[var(--app-bg)] text-[var(--app-fg)]">
            <header className="shrink-0 p-3 text-xs">
                <span id="selection">{selection}</span>
                <span id="context-calls">{calls.join('|')}</span>
                <span id="window-ids">{getMessageWindowState(SESSION).messages.map(m => m.id).join(',')}</span>
            </header>
            <HappyThread api={api} session={session} sessionId={SESSION} metadata={session.metadata} disabled={false}
                onRefresh={() => {}} onViewModeChange={windowState.setViewMode}
                isSyncingTail={windowState.isSyncingTail} messagesWarning={windowState.warning}
                hasMoreMessages={false} isLoadingMoreMessages={windowState.isLoadingMore}
                onLoadMore={async () => ({ kind: 'exhausted' })} onCancelLoadMore={windowState.cancelLoadMore}
                messagesVersion={windowState.messagesVersion} historyVersion={windowState.historyVersion}
                rawMessagesCount={windowState.messages.length} normalizedMessagesCount={normalized.length}
                initialTargetMessageId={target ? `tool-call:${selected.toolCallId}` : undefined}
                targetHighlightKind="pending-request" searchRequestId={target?.version}
                onLoadMessageContext={windowState.loadMessageContext} onInitialTargetConsumed={() => setTarget(null)}
            />
            <footer className="shrink-0 border-t border-[var(--app-border)] p-3">
                <StatusBar active thinking={false} agentState={session.agentState} onPendingRequestClick={id => {
                    setSelection(id)
                    setTarget({ id, version: ++sequence.current })
                }} />
            </footer>
        </main>
    </AssistantRuntimeProvider>
}
createRoot(document.getElementById('root')!).render(<QueryClientProvider client={new QueryClient()}><I18nProvider><Preview /></I18nProvider></QueryClientProvider>)
