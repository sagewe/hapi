import { useRef, useState } from 'react'
import type { ToolCallBlock } from '@/chat/types'
import { useHappyChatContext } from '@/components/AssistantChat/context'
import { useTranslation } from '@/lib/use-translation'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog'
import { getToolPresentation } from './knownTools'
import { ToolDetailDialogContent, ToolStatusIcon } from './ToolCard'

export function InlineExecutionTool({ block }: { block: ToolCallBlock }) {
    const ctx = useHappyChatContext()
    const { t } = useTranslation()
    const [fullOpen, setFullOpen] = useState(false)
    const fullTrigger = useRef<HTMLButtonElement>(null)
    const key = `execution-tool:${block.id}`
    const open = ctx.openExecutionProcesses?.has(key) ?? false
    const presentation = getToolPresentation({ toolName: block.tool.name, input: block.tool.input,
        result: block.tool.result, childrenCount: block.children.length,
        description: block.tool.nativeTitle ?? block.tool.description, metadata: ctx.metadata }, t)
    return <div data-execution-step={block.id}>
        <button type="button" aria-expanded={open} className="flex min-h-11 w-full items-center gap-2 text-left text-sm text-[var(--app-hint)]"
            onClick={() => { ctx.setExecutionProcessOpen?.(key, !open); ctx.onNestedScrollFollowChange?.(false) }}>
            <ToolStatusIcon state={block.tool.state} />
            <span className="min-w-0 flex-1 truncate">{presentation.title}{presentation.subtitle ? <span className="ml-2 opacity-70">{presentation.subtitle}</span> : null}</span>
            <span aria-hidden="true">{open ? '⌄' : '›'}</span>
        </button>
        {open ? <div className="pl-4">
            <ToolDetailDialogContent block={block} metadata={ctx.metadata} inline />
            <Dialog open={fullOpen} onOpenChange={setFullOpen}>
                <DialogTrigger asChild><button ref={fullTrigger} type="button" className="min-h-11 text-xs text-[var(--app-link)]">{t('chat.execution.fullDetails')}</button></DialogTrigger>
                <DialogContent className="max-w-3xl" onCloseAutoFocus={event => { event.preventDefault(); fullTrigger.current?.focus({ preventScroll: true }) }}><DialogHeader><DialogTitle>{presentation.title}</DialogTitle></DialogHeader>
                    <ToolDetailDialogContent block={block} metadata={ctx.metadata} />
                </DialogContent>
            </Dialog>
        </div> : null}
    </div>
}
