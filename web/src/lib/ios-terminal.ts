// Embedded iOS terminal. Uses Reins Native v1 JSON WebSocket (/v1/sessions/{id}/terminal).
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { buildV1TerminalWsUrl } from '@/api/v1Adapters'

const post = (message: object) => (window as any).webkit.messageHandlers.terminal.postMessage(message)
const term = new Terminal({ cursorBlink: true, convertEol: true, scrollback: 5000, fontSize: 14, disableStdin: false,
    theme: { background: '#101114', foreground: '#eeeeee' } })
const fit = new FitAddon()
term.loadAddon(fit)
term.open(document.getElementById('terminal')!)
let ws: WebSocket | null = null
let terminalId = '', sessionId = '', ready = false, direct = false, paused = true, retry = 0
term.attachCustomKeyEventHandler(() => direct)
if (term.textarea) term.textarea.readOnly = true
document.addEventListener('paste', event => { if (!direct) { event.preventDefault(); event.stopImmediatePropagation() } }, true)
let timer: ReturnType<typeof setTimeout> | undefined
let readyTimer: ReturnType<typeof setTimeout> | undefined
const status = (state: string, message = '') => post({ type: 'status', state, message })

function sendFrame(frame: Record<string, unknown>): boolean {
    if (!ws || ws.readyState !== WebSocket.OPEN) return false
    ws.send(JSON.stringify(frame))
    return true
}

function refit() {
    if (!document.getElementById('terminal')!.clientHeight) return
    fit.fit()
    if (ready) sendFrame({ type: 'resize', terminal_id: terminalId, cols: term.cols, rows: term.rows })
}
new ResizeObserver(() => requestAnimationFrame(refit)).observe(document.getElementById('terminal')!)
function schedule(auth = false) {
    ready = false
    if (paused || timer) return
    timer = setTimeout(() => { timer = undefined; if (!paused) post({ type: 'credentials', unauthorized: auth }) }, Math.min(1000 * ++retry, 5000))
}
function detach() {
    ready = false
    clearTimeout(readyTimer); readyTimer = undefined
    clearTimeout(timer); timer = undefined
    if (ws) {
        ws.onopen = null
        ws.onmessage = null
        ws.onerror = null
        ws.onclose = null
        ws.close()
        ws = null
    }
}
function send(data: string): boolean {
    if (!ready || !ws || ws.readyState !== WebSocket.OPEN) return false // Never queue keystrokes across reconnects.
    return sendFrame({ type: 'write', terminal_id: terminalId, data })
}
// Gate user keyboard/paste input above, not xterm protocol replies: shells
// may wait for a cursor-position response before displaying their prompt.
term.onData(data => { send(data) })
;(window as any).HapiTerminal = {
    start(options: { baseURL: string; token: string; sessionId: string; terminalId: string }) {
        detach(); paused = false; terminalId = options.terminalId; sessionId = options.sessionId
        // Hub replays its scrollback on reattachment; avoid duplicate transcript.
        term.reset(); refit(); status('connecting')
        const url = buildV1TerminalWsUrl(options.baseURL, sessionId, options.token)
        const current = new WebSocket(url)
        ws = current
        const ours = (p: any) => current === ws && (p?.terminal_id === terminalId || p?.terminalId === terminalId)
        current.onopen = () => {
            if (current !== ws) return
            sendFrame({ type: 'open', terminal_id: terminalId, cols: term.cols, rows: term.rows })
            readyTimer = setTimeout(() => {
                if (current === ws && !ready) {
                    paused = true
                    detach()
                    status('error', 'Terminal did not become ready. Retry to reconnect.')
                }
            }, 15000)
        }
        current.onmessage = (event) => {
            if (current !== ws || typeof event.data !== 'string') return
            let p: any
            try {
                p = JSON.parse(event.data)
            } catch {
                return
            }
            if (p?.type === 'pong') return
            if (!ours(p)) return
            if (p.type === 'ready') {
                // Parse replayed scrollback while input is still disabled. Old
                // cursor queries must not inject replies into the current prompt.
                term.write('', () => {
                    if (current !== ws || current.readyState !== WebSocket.OPEN) return
                    ready = true; clearTimeout(readyTimer); readyTimer = undefined
                    retry = 0; status('connected'); refit()
                })
            } else if (p.type === 'output' && typeof p.data === 'string') {
                term.write(p.data)
            } else if (p.type === 'exit') {
                paused = true; detach(); status('exited', String(p.code ?? ''))
            } else if (p.type === 'error') {
                paused = true; detach(); status('error', p.message || 'Terminal error')
            }
        }
        current.onerror = () => {
            if (current !== ws) return
            status('error', 'Connection error')
        }
        current.onclose = (event) => {
            if (current !== ws) return
            const isAuthErr = event.code === 1008 || /auth|token|jwt|unauthorized/i.test(event.reason || '')
            status('connecting')
            schedule(isAuthErr)
        }
    },
    send,
    mode(value: boolean) { direct = value; if (term.textarea) term.textarea.readOnly = !value; if (value) term.focus(); else term.blur() },
    selection() { return term.getSelection() },
    snapshot() {
        const buffer = term.buffer.active
        return Array.from({ length: buffer.length }, (_, i) => buffer.getLine(i)?.translateToString(true) ?? '').join('\n')
    },
    suspend() { paused = true; detach(); status('idle') },
    close() { paused = true; if (ws?.readyState === WebSocket.OPEN) sendFrame({ type: 'close', terminal_id: terminalId }); detach(); term.dispose() }
}
post({ type: 'loaded' })
