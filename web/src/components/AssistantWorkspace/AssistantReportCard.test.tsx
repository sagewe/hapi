import { cleanup, render, fireEvent, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { ApiClient } from '@/api/client'
import type { GeneratedImageBlock } from '@/chat/types'
import { HappyChatProvider } from '@/components/AssistantChat/context'
import { AssistantReportCard } from './AssistantReportCard'
vi.mock('./AssistantPdfPreview', () => ({ default: ({ blob }: { blob: Blob }) => <div aria-label="PDF 内容">{blob.size} bytes</div> }))
afterEach(() => { cleanup(); vi.restoreAllMocks() })
const base = { showSessionSummaryInChat: false, sessionId: 'case', metadata: null, terminalToolDisplayMode: 'compact' as const, disabled: false, onRefresh: vi.fn(), hasMoreMessages: false, isSyncingTail: false, isLoadingMoreMessages: false, loadOlderMessagesPreservingScroll: async () => 'terminal-stop' as const }
function tree(api: ApiClient) {
    return <HappyChatProvider value={{ ...base, api }}><AssistantReportCard block={{ kind: 'generated-image', id: 'report', imageId: 'report', fileName: '调查报告.pdf', mimeType: 'application/pdf', createdAt: 1 } as GeneratedImageBlock} /></HappyChatProvider>
}
it('one preview tap downloads and opens the actual report without a second tap', async () => {
    const fetch = vi.fn().mockResolvedValue(new Blob(['pdf'], { type: 'application/pdf' }))
    vi.stubGlobal('URL', Object.assign(URL, { createObjectURL: vi.fn().mockReturnValue('blob:test'), revokeObjectURL: vi.fn() }))
    render(tree({ getGeneratedImageBlob: fetch } as unknown as ApiClient))
    expect(fetch).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: '预览' }))
    expect(await screen.findByRole('dialog', { name: '报告预览' })).toBeInTheDocument()
    expect(await screen.findByLabelText('PDF 内容')).toHaveTextContent('3 bytes')
    expect(fetch).toHaveBeenCalledTimes(1)
})
it('one forward tap fetches and opens file sharing directly', async () => {
    const fetch = vi.fn().mockResolvedValue(new Blob(['pdf'], { type: 'application/pdf' }))
    const share = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('URL', Object.assign(URL, { createObjectURL: vi.fn().mockReturnValue('blob:test'), revokeObjectURL: vi.fn() }))
    Object.defineProperty(navigator, 'canShare', { value: () => true, configurable: true })
    Object.defineProperty(navigator, 'share', { value: share, configurable: true })
    render(tree({ getGeneratedImageBlob: fetch } as unknown as ApiClient))
    fireEvent.click(screen.getByRole('button', { name: '转发' }))
    await waitFor(() => expect(share).toHaveBeenCalledWith(expect.objectContaining({ files: [expect.any(File)] })))
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('dialog')).toBeNull()
})
