// Embedded iOS terminal. Reuses the web's xterm and Socket.IO versions.
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { Manager, Socket } from 'socket.io-client'
const post = (message: object) => (window as any).webkit.messageHandlers.terminal.postMessage(message)
const term = new Terminal({ cursorBlink: true, convertEol: true, scrollback: 5000, fontSize: 14, disableStdin: false,
    theme: { background: '#101114', foreground: '#eeeeee' } })
const fit = new FitAddon()
term.loadAddon(fit)
term.open(document.getElementById('terminal')!)
let socket: Socket | null = null
let terminalId = '', sessionId = '', ready = false, direct = false, paused = true, retry = 0
term.attachCustomKeyEventHandler(() => direct)
if (term.textarea) term.textarea.readOnly = true
document.addEventListener('paste', event => { if (!direct) { event.preventDefault(); event.stopImmediatePropagation() } }, true)
let timer: ReturnType<typeof setTimeout> | undefined
let readyTimer: ReturnType<typeof setTimeout> | undefined
const status = (state: string, message = '') => post({ type: 'status', state, message })
function refit() {
    if (!document.getElementById('terminal')!.clientHeight) return
    fit.fit()
    if (ready) socket?.emit('terminal:resize', { terminalId, cols: term.cols, rows: term.rows })
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
    socket?.removeAllListeners(); socket?.disconnect(); socket = null
}
function send(data: string): boolean {
    if (!ready || !socket?.connected) return false // Never queue keystrokes across reconnects.
    socket.emit('terminal:write', { terminalId, data }); return true
}
// Gate user keyboard/paste input above, not xterm protocol replies: shells
// may wait for a cursor-position response before displaying their prompt.
term.onData(data => { send(data) })
;(window as any).HapiTerminal = {
    start(options: { baseURL: string; token: string; sessionId: string; terminalId: string }) {
        detach(); paused = false; terminalId = options.terminalId; sessionId = options.sessionId
        // Hub replays its scrollback on reattachment; avoid duplicate transcript.
        term.reset(); refit(); status('connecting')
        const manager = new Manager(options.baseURL, { path: '/socket.io/', autoConnect: false,
            transports: ['websocket'], reconnection: false, timeout: 10000 })
        const current = manager.socket('/terminal', { auth: { token: options.token } }); socket = current
        const ours = (p: any) => current === socket && p?.terminalId === terminalId
        current.on('connect', () => {
            current.emit('terminal:create', { sessionId, terminalId, cols: term.cols, rows: term.rows })
            readyTimer = setTimeout(() => { if (current === socket && !ready) { paused = true; detach(); status('error', 'Terminal did not become ready. Retry to reconnect.') } }, 15000)
        })
        current.on('terminal:ready', p => {
            if (!ours(p)) return
            // Parse replayed scrollback while input is still disabled. Old
            // cursor queries must not inject replies into the current prompt.
            term.write('', () => {
                if (current !== socket || !current.connected) return
                ready = true; clearTimeout(readyTimer); readyTimer = undefined
                retry = 0; status('connected'); refit()
            })
        })
        current.on('terminal:output', p => { if (ours(p) && typeof p.data === 'string') term.write(p.data) })
        current.on('terminal:exit', p => { if (ours(p)) { paused = true; detach(); status('exited', String(p.code ?? '')) } })
        current.on('terminal:error', p => { if (ours(p)) { paused = true; detach(); status('error', p.message || 'Terminal error') } })
        current.on('connect_error', error => { if (current !== socket) return; status('error', error.message); schedule(/auth|token|jwt|unauthorized/i.test(error.message)) })
        current.on('disconnect', () => { if (current === socket) { status('connecting'); schedule() } })
        current.connect()
    },
    send,
    mode(value: boolean) { direct = value; if (term.textarea) term.textarea.readOnly = !value; if (value) term.focus(); else term.blur() },
    selection() { return term.getSelection() },
    snapshot() {
        const buffer = term.buffer.active
        return Array.from({ length: buffer.length }, (_, i) => buffer.getLine(i)?.translateToString(true) ?? '').join('\n')
    },
    suspend() { paused = true; detach(); status('idle') },
    close() { paused = true; if (socket?.connected) socket.emit('terminal:close', { terminalId }); detach(); term.dispose() }
}
post({ type: 'loaded' })
