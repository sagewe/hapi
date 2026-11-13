import { Component, createRef, useEffect, useState, type ReactNode } from 'react'
import type { GeneratedImageBlock } from '@/chat/types'
import { stripNotifySummaryFooter } from '@hapi/protocol/messages'
import { type ToolGroupBlock } from '@/chat/toolGroups'
import { useHappyChatContext } from '@/components/AssistantChat/context'
import { MarkdownRenderer } from '@/components/MarkdownRenderer'
import { ToolCard } from './ToolCard'
import { useTranslation } from '@/lib/use-translation'

/** Preserve the visible step, not just the enclosing assistant card, when an
 * older history page prepends members inside an already-open process. */
class ProcessReadingAnchor extends Component<{ children: ReactNode; revision: unknown }, object, { id: string; top: number } | null> {
    private root = createRef<HTMLDivElement>()
    getSnapshotBeforeUpdate(previous: { revision: unknown }) {
        if (previous.revision === this.props.revision) return null
        const viewport = this.root.current
        if (!viewport) return null
        const bounds = viewport.getBoundingClientRect()
        const anchor = Array.from(this.root.current!.querySelectorAll<HTMLElement>('[data-execution-step]')).find(element => {
            const rect = element.getBoundingClientRect()
            return rect.bottom > bounds.top && rect.top < bounds.bottom
        })
        return anchor ? { id: anchor.dataset.executionStep!, top: anchor.getBoundingClientRect().top - bounds.top } : null
    }
    componentDidUpdate(_props: unknown, _state: unknown, snapshot: { id: string; top: number } | null) {
        if (!snapshot) return
        const viewport = this.root.current
        const anchor = Array.from(this.root.current?.querySelectorAll<HTMLElement>('[data-execution-step]') ?? [])
            .find(element => element.dataset.executionStep === snapshot.id)
        if (viewport && anchor) viewport.scrollTop += anchor.getBoundingClientRect().top - viewport.getBoundingClientRect().top - snapshot.top
    }
    render() { return <div ref={this.root} data-hapi-nested-scroll="true" className="max-h-[60vh] space-y-3 overflow-y-auto overscroll-contain" tabIndex={0}>{this.props.children}</div> }
}

function ExecutionTimingLabel({ timing }: { timing: ToolGroupBlock['processTiming'] }) {
    const { t } = useTranslation()
    const [now, setNow] = useState(Date.now)
    useEffect(() => {
        if (!timing?.running) return
        setNow(Date.now())
        const timer = window.setInterval(() => setNow(Date.now()), 1000)
        return () => window.clearInterval(timer)
    }, [timing?.running, timing?.startedAt])
    if (timing?.startedAt == null) return <>{t(timing?.running ? 'chat.execution.runningUnknown' : 'chat.execution.unknown')}</>
    const seconds = Math.max(0, Math.floor(((timing.running ? now : timing.endedAt) - timing.startedAt) / 1000))
    const duration = seconds < 60 ? t('chat.execution.seconds', { n: seconds })
        : t('chat.execution.minutes', { m: Math.floor(seconds / 60), s: seconds % 60 })
    return <>{t(timing.running ? 'chat.execution.running' : 'chat.execution.elapsed', { duration })}</>
}

/** All providers share this outer disclosure; inner views retain tool semantics. */
export function ExecutionProcessCard({ block, renderMedia }: { block: ToolGroupBlock; renderMedia: (block: GeneratedImageBlock) => ReactNode }) {
    const ctx = useHappyChatContext()
    const { t } = useTranslation()
    const open = ctx.openExecutionProcesses?.has(block.id) ?? false
    // Keep each inspected step mounted as its state changes; regrouping completed
    // tools would discard an open detail dialog and move the reading position.
    const members = block.processBlocks ?? []
    return <section data-testid="execution-process" className="min-w-0">
        <button type="button" aria-expanded={open} className="flex min-h-11 items-center gap-2 text-xs text-[var(--app-hint)] hover:text-[var(--app-fg)]"
            onClick={() => {
                ctx.setExecutionProcessOpen?.(block.id, !open)
                if (!open) ctx.onNestedScrollFollowChange?.(false)
            }}>
            <span><ExecutionTimingLabel timing={block.processTiming} /></span>
            <span aria-hidden="true">{open ? '⌄' : '›'}</span>
        </button>
        {open ? <div className="space-y-3 border-l border-[var(--app-border)] pl-3">
            {block.needsOlderHistory ? <p className="text-xs text-[var(--app-hint)]">{t('chat.executionProcess.partial')}</p> : null}
            <ProcessReadingAnchor revision={members}>
                {members.map(member => <div key={member.id} data-execution-step={member.id}>
                    {member.kind === 'tool-call'
                            ? <ToolCard block={member} api={ctx.api} sessionId={ctx.sessionId}
                                metadata={ctx.metadata} terminalToolDisplayMode={ctx.terminalToolDisplayMode} disabled={ctx.disabled} onDone={ctx.onRefresh} />
                            : member.kind === 'generated-image' ? renderMedia(member)
                            : member.kind === 'agent-text' || member.kind === 'agent-reasoning'
                                ? <div className={member.kind === 'agent-reasoning' ? 'text-[var(--app-hint)]' : undefined}>
                                    <MarkdownRenderer content={ctx.showSessionSummaryInChat ? member.text : stripNotifySummaryFooter(member.text)} />
                                </div>
                                : null}
                </div>)}
            </ProcessReadingAnchor>
        </div> : null}
    </section>
}
