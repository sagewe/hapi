import { sessionIsUnread } from '@/lib/sessionAttention'
import { getSessionLastSeenAt, getSessionManualUnreadAt, useSessionLastSeenVersion } from '@/lib/sessionLastSeen'
import { createContext, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useLocation, useNavigate } from '@tanstack/react-router'
import type { ApiClient } from '@/api/client'
import type { Machine, SessionSummary } from '@/types/api'
import type { ClientQuickAction } from '@hapi/protocol/apiTypes'
import { useClientProfile } from '@/lib/client-profile'
import { defaultPreset } from '@/components/AssistantModelPresetPicker'
import { getSessionTitle } from '@/lib/sessionTitle'
import { AssistantDraftTransaction, sceneTitle, scenePlaceholder } from './transaction'
import './assistant-workspace.css'

const Context = createContext<{ history: () => void; create: (codex?: boolean) => void } | null>(null)
export const useAssistantWorkspace = () => useContext(Context)
export function SceneIcon({ index }: { index: number }) {
    const paths = ['M4 21V6l8-3v18M4 11h8M7 7v1m0 5v1m0 3v1m9-9h4v12M2 21h20',
        'M3 4h18v16H3zM7 9a2 2 0 1 0 4 0 2 2 0 1 0-4 0M5 17c0-4 8-4 8 0m2-8h3m-3 4h3',
        'M6 2h9l4 4v15H6zM15 2v5h4M9 11h6m-6 4h4M17 17l5 5m-1-5a4 4 0 1 1-8 0 4 4 0 0 1 8 0',
        'M12 2L3 6v6c0 5 9 10 9 10s9-5 9-10V6zM12 7v6m0 3v1']
    return <svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d={paths[index % 4]} /></svg>
}
export function AssistantWorkspace(props: { api: ApiClient; machines: Machine[]; sessions: SessionSummary[]; refresh: () => unknown; children: ReactNode }) {
    const profile = useClientProfile()!
    useSessionLastSeenVersion()
    const isUnread = (s: SessionSummary) => sessionIsUnread(s, { lastSeenAt: getSessionLastSeenAt(s.id), manualUnreadAt: getSessionManualUnreadAt(s.id, s.readState) })
    const historyKind = (s: SessionSummary) => {
        const text = (s.metadata?.tags ?? []).join(' ')
        return /风险|制裁|sanction|high.risk|ofac/i.test(text) ? 3 : /单据|合同|水单/.test(text) ? 2 : /自然人|实控人/.test(text) ? 1 : 0
    }
    const navigate = useNavigate()
    const pathname = useLocation({ select: l => l.pathname })
    const blank = pathname === '/sessions' || pathname === '/sessions/' || pathname === '/sessions/new'
    const [open, setOpen] = useState(false)
    const [text, setText] = useState('')
    const [scene, setScene] = useState<ClientQuickAction>()
    const [files, setFiles] = useState<File[]>([])
    const [presetId, setPresetId] = useState(() => {
        try { const id = localStorage.getItem('assistant.preset'); return profile.modelPresets?.some(p => p.id === id) ? id! : defaultPreset(profile)?.id ?? '' } catch { return defaultPreset(profile)?.id ?? '' }
    })
    const [codex, setCodex] = useState(false)
    const [busy, setBusy] = useState(false)
    const [error, setError] = useState('')
    const [query, setQuery] = useState('')
    const [tag, setTag] = useState('')
    const [archives, setArchives] = useState(false)
    const [attachmentsOpen, setAttachmentsOpen] = useState(false)
    const [recording, setRecording] = useState(false)
    const [transcribing, setTranscribing] = useState(false)
    const [editing, setEditing] = useState(false)
    const transaction = useRef(new AssistantDraftTransaction(props.api))
    const fileInput = useRef<HTMLInputElement>(null)
    const cameraInput = useRef<HTMLInputElement>(null)
    const photoInput = useRef<HTMLInputElement>(null)
    const editor = useRef<HTMLTextAreaElement>(null)
    const recorder = useRef<MediaRecorder | null>(null)
    const stream = useRef<MediaStream | null>(null)
    const voiceHeld = useRef(false)
    const [drag, setDrag] = useState(0)
    const start = useRef<{ x: number; y: number } | null>(null)
    const preset = profile.modelPresets?.find(p => p.id === presetId) ?? defaultPreset(profile)
    const actions = profile.quickActions ?? []
    const tags = Array.from(new Set(props.sessions.flatMap(s => s.metadata?.tags ?? []))).sort()
    const rows = props.sessions.filter(s => (archives || s.metadata?.lifecycleState !== 'archived') && (!query || getSessionTitle(s).toLowerCase().includes(query.toLowerCase())) && (!tag || s.metadata?.tags?.includes(tag)))
        .sort((a, b) => b.updatedAt - a.updatedAt)
    const reset = (useCodex = false) => {
        if (busy) return
        setText(''); setScene(undefined); setFiles([]); setError(''); setCodex(useCodex); setOpen(false)
        transaction.current = new AssistantDraftTransaction(props.api)
        void navigate({ to: '/sessions' })
    }
    const send = async () => {
        if (busy || (!text.trim() && !files.length)) return
        setBusy(true); setError('')
        try {
            const machines = props.machines.filter(m => m.active)
            if (machines.length !== 1) throw new Error('后台调查服务暂时离线，请稍后重试')
            const id = await transaction.current.send({ text, scene, files, profile, preset, machineId: machines[0]!.id, codex })
            props.refresh(); setText(''); setFiles([]); setScene(undefined)
            transaction.current = new AssistantDraftTransaction(props.api)
            await navigate({ to: '/sessions/$sessionId', params: { sessionId: id } })
        } catch { setError('资料暂未发送成功，重试会继续当前调查') }
        finally { setBusy(false) }
    }
    const addFiles = (list: FileList | null) => {
        if (!list) return
        const accepted = Array.from(list).filter(f => f.size <= 50 * 1024 * 1024)
        if (accepted.length !== list.length) setError('请选择 50 MB 以内的文件')
        setFiles(previous => [...previous, ...accepted]); setAttachmentsOpen(false); editor.current?.focus()
    }
    const startVoice = async () => {
        voiceHeld.current = true
        try {
            const media = await navigator.mediaDevices.getUserMedia({ audio: true })
            if (!voiceHeld.current) { media.getTracks().forEach(t => t.stop()); return }
            stream.current = media
            const rec = new MediaRecorder(media); recorder.current = rec
            const chunks: Blob[] = []; rec.ondataavailable = event => { if (event.data.size) chunks.push(event.data) }
            rec.onstop = () => {
                media.getTracks().forEach(t => t.stop()); stream.current = null; setRecording(false)
                if (!chunks.length) return
                setTranscribing(true)
                void (async () => {
                    try {
                        const { providers } = await props.api.fetchTranscriptionProviders()
                        const provider = providers.find(p => p.id === 'openai-compatible') ?? providers[0]
                        if (!provider) throw Error()
                        const blob = new Blob(chunks, { type: rec.mimeType })
                        const result = await props.api.transcribeVoice({ file: new File([blob], rec.mimeType.includes('mp4') ? 'voice.m4a' : 'voice.webm', { type: rec.mimeType }), provider: provider.id, mode: 'standard', draft: text })
                        setText(old => old + (old ? ' ' : '') + result.text)
                    } catch { setError('语音暂未识别，请重试') }
                    finally { setTranscribing(false) }
                })()
            }
            rec.start(); setRecording(true)
        } catch { setError('请允许浏览器访问麦克风') }
    }
    const endVoice = () => { voiceHeld.current = false; if (recorder.current?.state === 'recording') recorder.current.stop() }
    useEffect(() => () => {
        voiceHeld.current = false
        if (recorder.current) { recorder.current.onstop = null; if (recorder.current.state === 'recording') recorder.current.stop() }
        stream.current?.getTracks().forEach(t => t.stop())
    }, [])
    const previews = useMemo(() => files.map(file => file.type.startsWith('image/') ? URL.createObjectURL(file) : undefined), [files])
    useEffect(() => () => { previews.forEach(url => { if (url) URL.revokeObjectURL(url) }) }, [previews])
    return <Context.Provider value={{ history: () => setOpen(true), create: reset }}>
        <div className="assistant-workspace" onTouchStart={e => {
            const p = e.touches[0]!; if (open || p.clientX < 24) start.current = { x: p.clientX, y: p.clientY }
        }} onTouchMove={e => { const p = e.touches[0]!; if (start.current && Math.abs(p.clientX - start.current.x) > Math.abs(p.clientY - start.current.y)) setDrag(p.clientX - start.current.x) }}
        onTouchEnd={() => { if (start.current) { setOpen(open ? drag > -70 : drag > 70); setDrag(0); start.current = null } }}>
            {blank ? <div className="assistant-blank">
                <header className="assistant-top"><button className="assistant-circle" aria-label="历史调查" onClick={() => setOpen(true)}>☰{props.sessions.some(s => s.thinking || isUnread(s)) && <span className="assistant-unread-dot" />}</button><span />{codex && <span className="assistant-quiet">交叉核验</span>}</header>
                <main className="assistant-welcome" style={editing ? { visibility: 'hidden', pointerEvents: 'none' } : undefined}>
                    <div className="assistant-greeting"><h1>合规调查助手</h1><p>需要核查哪笔交易？</p></div>
                    <div className="assistant-scenes">{actions.map((action, index) => <button type="button" key={action.id} className="assistant-scene" disabled={busy} onClick={() => { setScene(action); if (sceneTitle(action) === '单据审核') setAttachmentsOpen(true); else editor.current?.focus() }}>
                        <span className={`assistant-badge color-${index % 4}`}><SceneIcon index={index} /></span><strong>{sceneTitle(action)}</strong>
                    </button>)}</div>
                </main>
                <div className="assistant-draft-wrap"><form className="assistant-draft" style={busy ? { pointerEvents: 'none', opacity: 0.75 } : undefined} onSubmit={e => { e.preventDefault(); void send() }}>
                    {scene && <button type="button" className="assistant-scene-chip" onClick={() => { setScene(undefined); editor.current?.blur() }}>{sceneTitle(scene)} <span>×</span></button>}
                    {!!files.length && <div className="assistant-files">{files.map((file, i) => <span key={i}>{previews[i] ? <img src={previews[i]} alt="" style={{ width: 28, height: 28, borderRadius: 7, objectFit: 'cover' }} /> : '▤'} {file.name}<button type="button" aria-label={`移除 ${file.name}`} onClick={() => setFiles(files.filter((_, at) => at !== i))}>×</button></span>)}</div>}
                    <textarea ref={editor} aria-label="调查线索" placeholder={scenePlaceholder(scene)} value={text} disabled={busy} onFocus={() => setEditing(true)} onBlur={() => setEditing(false)} onChange={e => setText(e.target.value)} rows={2} />
                    <div className="assistant-composer-tools">
                        <button type="button" aria-label="添加资料" className="assistant-add" onClick={() => setAttachmentsOpen(true)}>＋</button>
                        {codex ? <span className="assistant-quiet">交叉核验</span> : <button type="button" className="assistant-mode" onClick={() => {
                            const list = profile.modelPresets ?? []; const i = list.findIndex(p => p.id === preset?.id); const next = list[(i + 1) % list.length]
                            if (next) { setPresetId(next.id); try { localStorage.setItem('assistant.preset', next.id) } catch { /* private browsing */ } }
                        }}>{preset?.label === '快速' ? 'ϟ' : '✦'} {preset?.label ?? '深度'}</button>}
                        <button type="button" className={`assistant-voice ${recording ? 'recording' : ''}`} disabled={busy || transcribing} onPointerDown={e => { e.currentTarget.setPointerCapture(e.pointerId); void startVoice() }} onPointerUp={endVoice} onPointerCancel={endVoice}>{transcribing ? '转文字中…' : recording ? '松开转文字' : '按住说话'}</button>
                        <button type="submit" aria-label="发送调查" className="assistant-send" disabled={busy || recording || transcribing || (!text.trim() && !files.length)}>{busy ? '…' : '↑'}</button>
                    </div>
                    {error && <p role="alert" className="assistant-error">{error}</p>}
                </form></div>
            </div> : props.children}
            {(open || drag > 0) && <button type="button" className="assistant-scrim" aria-label="关闭历史调查" onClick={() => setOpen(false)} />}
            <aside className="assistant-history" style={{ transform: `translateX(${open ? Math.min(0, drag) : -360 + Math.max(0, drag)}px)`, visibility: open || drag > 0 ? 'visible' : 'hidden' }} aria-label="调查记录">
                <h2>调查记录</h2><input type="search" placeholder="搜索调查" value={query} onChange={e => setQuery(e.target.value)} />
                <div className="assistant-history-filters"><select aria-label="按标签筛选" value={tag} onChange={e => setTag(e.target.value)}><option value="">全部标签</option>{tags.map(t => <option key={t}>{t}</option>)}</select><button type="button" aria-pressed={archives} onClick={() => setArchives(!archives)}>归档</button></div>
                <div className="assistant-history-rows">{rows.map(s => <button type="button" className="assistant-history-row" key={s.id} onClick={() => { setOpen(false); void navigate({ to: '/sessions/$sessionId', params: { sessionId: s.id } }) }}>
                    <span className={`assistant-badge color-${historyKind(s)}`}><SceneIcon index={historyKind(s)} /></span>
                    <span><strong>{getSessionTitle(s)}{isUnread(s) && <b className="assistant-row-dot" />}</strong><span className="assistant-history-tags">{s.metadata?.tags?.slice(0, 2).map(t => <i key={t} className={/风险|制裁/.test(t) ? 'risk' : ''}>{t}</i>)}</span>
                        {s.pendingRequestsCount > 0 && s.pendingRequestKinds?.includes('input') ? <small className="risk">待回复</small> : s.active && s.thinking ? <small>● 调查中</small> : null}</span>
                </button>)}</div>
                <button type="button" className="assistant-settings" onClick={() => { setOpen(false); void navigate({ to: '/settings' }) }}>⚙ 设置</button>
            </aside>
            {attachmentsOpen && <div className="assistant-attachment-layer"><button className="assistant-scrim" aria-label="关闭添加资料" onClick={() => setAttachmentsOpen(false)} /><div className="assistant-attachment-sheet"><button onClick={() => cameraInput.current?.click()}>拍照</button><button onClick={() => photoInput.current?.click()}>相册图片</button><button onClick={() => fileInput.current?.click()}>选择 PDF 文件</button><button onClick={() => setAttachmentsOpen(false)}>取消</button></div></div>}
            <input ref={fileInput} type="file" accept="application/pdf,image/*" multiple hidden onChange={e => { addFiles(e.target.files); e.currentTarget.value = '' }} />
            <input ref={photoInput} type="file" accept="image/*" multiple hidden onChange={e => { addFiles(e.target.files); e.currentTarget.value = '' }} />
            <input ref={cameraInput} type="file" accept="image/*" capture="environment" hidden onChange={e => { addFiles(e.target.files); e.currentTarget.value = '' }} />
        </div>
    </Context.Provider>
}
