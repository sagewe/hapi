import { useEffect, useRef, useState } from 'react'
import { getDocument, GlobalWorkerOptions, type PDFDocumentProxy } from 'pdfjs-dist/legacy/build/pdf.mjs'
import workerUrl from 'pdfjs-dist/legacy/build/pdf.worker.min.mjs?url'

GlobalWorkerOptions.workerSrc = workerUrl

function Page({ document, number }: { document: PDFDocumentProxy; number: number }) {
    const host = useRef<HTMLDivElement>(null)
    const canvas = useRef<HTMLCanvasElement>(null)
    const [error, setError] = useState(false)
    useEffect(() => {
        let disposed = false
        let rendering: { cancel(): void } | undefined
        const observer = new IntersectionObserver(entries => {
            if (!entries.some(entry => entry.isIntersecting)) return
            observer.disconnect()
            void (async () => {
                const page = await document.getPage(number)
                if (disposed || !canvas.current || !host.current) return
                const width = host.current.clientWidth
                const scale = width / page.getViewport({ scale: 1 }).width
                const ratio = Math.min(window.devicePixelRatio || 1, 2)
                const viewport = page.getViewport({ scale: scale * ratio })
                canvas.current.width = Math.ceil(viewport.width)
                canvas.current.height = Math.ceil(viewport.height)
                const task = page.render({ canvas: canvas.current, viewport })
                rendering = task
                await task.promise
                if (!disposed) canvas.current?.setAttribute('data-rendered', 'true')
            })().catch(() => { if (!disposed) setError(true) })
        }, { rootMargin: '600px' })
        if (host.current) observer.observe(host.current)
        return () => { disposed = true; observer.disconnect(); rendering?.cancel() }
    }, [document, number])
    return <div ref={host} className="mx-auto mb-4 w-full max-w-3xl bg-white" style={{ minHeight: 300 }}>
        <canvas ref={canvas} aria-label={`报告第 ${number} 页`} className="block h-auto w-full" />
        {error && <p role="alert" className="p-4 text-sm text-gray-600">此页暂未加载，请保存文件查看。</p>}
    </div>
}

export default function AssistantPdfPreview({ blob }: { blob: Blob }) {
    const [document, setDocument] = useState<PDFDocumentProxy>()
    const [error, setError] = useState(false)
    useEffect(() => {
        let disposed = false
        let loading: ReturnType<typeof getDocument> | undefined
        void blob.arrayBuffer().then(async buffer => {
            if (disposed) return
            loading = getDocument({ data: new Uint8Array(buffer), useSystemFonts: true })
            const pdf = await loading.promise
            if (!disposed) setDocument(pdf)
        }).catch(() => { if (!disposed) setError(true) })
        return () => { disposed = true; void loading?.destroy() }
    }, [blob])
    return <div className="min-h-0 flex-1 overflow-auto bg-black/5 p-3" aria-label="PDF 内容">
        {document ? Array.from({ length: document.numPages }, (_, index) => <Page key={index} document={document} number={index + 1} />)
            : <p className="p-6 text-center text-sm">{error ? '暂时无法预览，请保存文件查看。' : '正在打开报告…'}</p>}
    </div>
}
