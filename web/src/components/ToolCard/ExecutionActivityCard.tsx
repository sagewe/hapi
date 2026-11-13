import { useMemo, useState } from 'react'
import { isInteractiveToolBlock } from '@/chat/toolGroups'
import type { ToolCallBlock } from '@/chat/types'
import { useHappyChatContext } from '@/components/AssistantChat/context'
import { getToolPresentation } from './knownTools'
import { ToolCard, ToolDetailDialogContent, ToolStatusIcon } from './ToolCard'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog'
import { useTranslation } from '@/lib/use-translation'

/** The current ordinary step uses the same compact shell for every provider. */
export function ExecutionActivityCard({ block }: { block: ToolCallBlock }) {
    const ctx = useHappyChatContext()
    const { t } = useTranslation()
    const [open, setOpen] = useState(false)
    const presentation = useMemo(() => getToolPresentation({ toolName: block.tool.name,
        input: block.tool.input, result: block.tool.result, childrenCount: block.children.length,
        description: block.tool.nativeTitle ?? block.tool.description, metadata: ctx.metadata }, t), [block, ctx.metadata, t])
    return <Dialog open={open} onOpenChange={(value) => {
        if (value) { ctx.onExecutionInspect?.(block.id); ctx.onNestedScrollFollowChange?.(false) }
        setOpen(value)
    }}>
        {block.tool.state === 'error' || isInteractiveToolBlock(block)
            ? <ToolCard block={block} api={ctx.api} sessionId={ctx.sessionId} metadata={ctx.metadata}
                terminalToolDisplayMode={ctx.terminalToolDisplayMode} disabled={ctx.disabled} onDone={ctx.onRefresh} />
            : <DialogTrigger asChild>
            <button type="button" data-testid="execution-activity" className="flex min-h-11 w-full items-center gap-2 text-left text-sm text-[var(--app-hint)] hover:text-[var(--app-fg)]">
                <ToolStatusIcon state={block.tool.state} />
                <span className="min-w-0 flex-1 truncate">{presentation.title}{presentation.subtitle ? <span className="ml-2 opacity-70">{presentation.subtitle}</span> : null}</span>
                <span aria-hidden="true">›</span>
            </button>
        </DialogTrigger>}
        <DialogContent className="max-w-3xl">
            <DialogHeader><DialogTitle>{presentation.title}</DialogTitle></DialogHeader>
            <ToolDetailDialogContent block={block} metadata={ctx.metadata} />
        </DialogContent>
    </Dialog>
}
