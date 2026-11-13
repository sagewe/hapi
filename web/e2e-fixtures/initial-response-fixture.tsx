import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { AssistantRuntimeProvider } from '@assistant-ui/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { buildExecutionProcessBlocks } from '../src/chat/executionProcess'
import { useHappyRuntime } from '../src/lib/assistant-runtime'
import { HappyThread } from '../src/components/AssistantChat/HappyThread'
import { I18nProvider } from '../src/lib/i18n-context'
import type { ApiClient } from '../src/api/client'
import type { Session } from '../src/types/api'
import type { ChatBlock } from '../src/chat/types'
import '../src/index.css'

type Phase = 'idle' | 'sending' | 'waiting' | 'thinking' | 'output' | 'failed' | 'stopped'
const api = { getSubscriptionUsage: async () => ({ providers: [] }) } as unknown as ApiClient
function Fixture() {
    const [phase, setPhase] = useState<Phase>('idle')
    const [sessionId, setSessionId] = useState('response-fixture')
    const running = ['waiting', 'thinking', 'output'].includes(phase)
    const blocks: ChatBlock[] = phase === 'idle' ? [] : [{ kind: 'user-text', id: 'u', localId: 'local', createdAt: 1000,
        invokedAt: ['thinking', 'output'].includes(phase) ? 1100 : null,
        text: 'Hello', status: phase === 'failed' ? 'failed' : phase === 'sending' ? 'sending' : 'sent' }]
    if (phase === 'output') blocks.push({ kind: 'agent-text', id: 'a', localId: null, createdAt: 2000, text: 'First reply arrives here.' })
    const session = { id: sessionId, active: true, thinking: running, activeTurnStartedAt: running ? 1000 : null,
        metadata: { path: '/tmp/fixture', host: 'fixture', flavor: 'codex' } } as Session
    const version = ['idle', 'sending', 'waiting', 'thinking', 'output', 'failed', 'stopped'].indexOf(phase)
    const runtime = useHappyRuntime({ session, blocks: buildExecutionProcessBlocks(blocks, { isRunning: running, hasMoreMessages: false, completedRounds: new Set() }), messagesVersion: version, historyVersion: 0,
        isSending: phase === 'sending', isRunning: running, completedRounds: new Set(phase === 'stopped' ? ['u'] : []),
        onSendMessage: () => setPhase('sending'), onAbort: async () => setPhase('stopped') })
    return <AssistantRuntimeProvider runtime={runtime}>
        <main className="mx-auto flex h-screen max-w-2xl flex-col">
            <header className="flex flex-wrap shrink-0 gap-3 p-3">
                {(['sending', 'waiting', 'thinking', 'output', 'failed', 'stopped'] as Phase[]).map(next =>
                    <button key={next} onClick={() => setPhase(next)}>{next}</button>)}
                <button onClick={() => { setPhase('idle'); setSessionId('other-session') }}>Switch session</button>
            </header>
            <HappyThread api={api} session={session} sessionId={sessionId} metadata={session.metadata} disabled={false}
                onRefresh={() => {}} onViewModeChange={() => {}} isSyncingTail={false} hasMoreMessages={false} isLoadingMoreMessages={false}
                unseenCount={0} messagesVersion={version} historyVersion={0} />
        </main>
    </AssistantRuntimeProvider>
}
createRoot(document.getElementById('root')!).render(<QueryClientProvider client={new QueryClient()}><I18nProvider><Fixture /></I18nProvider></QueryClientProvider>)
