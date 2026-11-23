import { createPortal } from 'react-dom'
import { lazy, Suspense, useEffect, useRef, useState } from 'react'
import type { GeneratedImageBlock } from '@/chat/types'
import { useHappyChatContext } from '@/components/AssistantChat/context'
import { SceneIcon } from './AssistantWorkspace'

const PdfPreview = lazy(() => import('./AssistantPdfPreview'))

export function AssistantReportCard({ block }: { block: GeneratedImageBlock }) {
    const ctx = useHappyChatContext()
    const [busy, setBusy] = useState(false)
    const [error, setError] = useState(false)
    const [preview, setPreview] = useState(false)
    const [url, setUrl] = useState<string>()
    const blob = useRef<Blob | undefined>(undefined)
    const pending = useRef<Promise<Blob> | null>(null)
    const ownedUrl = useRef<string | undefined>(undefined)
    const mounted = useRef(true)
    const pdf = block.mimeType === 'application/pdf' || block.fileName.toLowerCase().endsWith('.pdf')
    const zip = block.fileName.toLowerCase().endsWith('.zip')
    useEffect(() => { mounted.current = true; return () => { mounted.current = false; if (ownedUrl.current) URL.revokeObjectURL(ownedUrl.current) } }, [])
    const load = async () => {
        if (blob.current) return blob.current
        if (!pending.current) pending.current = ctx.api.getGeneratedImageBlob(ctx.sessionId, block.imageId)
        try {
            const bytes = await pending.current
            blob.current = bytes
            if (mounted.current && !ownedUrl.current) { ownedUrl.current = URL.createObjectURL(bytes); setUrl(ownedUrl.current) }
            return bytes
        } finally { pending.current = null }
    }
    const open = async (share: boolean) => {
        setBusy(true); setError(false)
        try {
            const bytes = await load()
            if (!mounted.current) return
            if (!share) { setPreview(true); return }
            const file = new File([bytes], block.fileName, { type: block.mimeType ?? undefined })
            if (navigator.canShare?.({ files: [file] })) {
                try { await navigator.share({ files: [file], title: block.fileName }); return }
                catch (error) { if (error instanceof Error && error.name === 'AbortError') return }
            }
            const anchor = document.createElement('a'); anchor.href = ownedUrl.current!; anchor.download = block.fileName; anchor.click()
        } catch { if (mounted.current) setError(true) }
        finally { if (mounted.current) setBusy(false) }
    }
    return <div className="assistant-report" data-testid="assistant.report-card">
        <div className="assistant-report-heading">
            <span className={`assistant-badge ${pdf ? '' : zip ? 'color-3' : 'color-2'}`} style={pdf ? { color: '#c76b87', background: '#c76b871f', width: 40, height: 40 } : { width: 40, height: 40 }}><SceneIcon index={2} /></span>
            <div><strong>{block.fileName}</strong><small>{pdf ? 'PDF 报告' : zip ? '证据包' : '交付文件'}</small></div>
        </div>
        <div className="assistant-report-actions"><button disabled={busy} type="button" onClick={() => void open(false)}>{busy ? '准备中…' : '预览'}</button><button disabled={busy} type="button" onClick={() => void open(true)}>转发</button></div>
        {error && <p className="assistant-error" role="alert">文件暂不可用，可重试或请助手重新发送</p>}
        {preview && url && createPortal(<div role="dialog" aria-modal="true" aria-label="报告预览" className="fixed inset-0 z-[100] flex flex-col bg-[var(--app-bg)]">
            <header className="flex min-h-14 items-center gap-4 p-4"><strong className="min-w-0 flex-1 text-sm break-words">{block.fileName}</strong><button onClick={() => setPreview(false)}>关闭</button></header>
            {pdf && blob.current ? <Suspense fallback={<p className="p-6">正在打开报告…</p>}><PdfPreview blob={blob.current} /></Suspense> : <p className="p-6 text-sm text-[var(--app-hint)]">证据文件已准备好，可以保存或转发。</p>}
            <div className="flex justify-around p-4"><a href={url} download={block.fileName}>保存文件</a><button onClick={() => void open(true)}>转发</button></div>
        </div>, document.body)}
    </div>
}
