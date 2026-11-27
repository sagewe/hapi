import { useCallback, useEffect, useRef, useState } from 'react'
import { buildV1TerminalWsUrl } from '@/api/v1Adapters'

type AgentTerminalConnectionState =
    | { status: 'idle' }
    | { status: 'connecting' }
    | { status: 'connected' }
    | { status: 'error'; error: string }

type UseAgentTerminalSocketOptions = {
    baseUrl: string
    token: string
    sessionId: string
    onAuthError?: () => void
}

type ServerTerminalFrame = {
    type?: string
    terminal_id?: string
    terminalId?: string
    data?: string
    message?: string
}

const AGENT_TERMINAL_ID = 'agent'
const RECONNECT_BASE_DELAY_MS = 1_000
const RECONNECT_MAX_DELAY_MS = 5_000

export function useAgentTerminalSocket(options: UseAgentTerminalSocketOptions): {
    state: AgentTerminalConnectionState
    connect: () => void
    disconnect: () => void
    resubscribe: () => void
    unsubscribe: () => void
    onOutput: (handler: (data: string) => void) => void
    resize: (cols: number, rows: number) => void
    sendInput: (data: string) => void
} {
    const [state, setState] = useState<AgentTerminalConnectionState>({ status: 'idle' })
    const wsRef = useRef<WebSocket | null>(null)
    const reconnectTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
    const reconnectAttemptRef = useRef(0)
    const consecutivePreOpenFailuresRef = useRef(0)
    const manualCloseRef = useRef(false)
    const exitedRef = useRef(false)
    const outputHandlerRef = useRef<(data: string) => void>(() => {})
    const onAuthErrorRef = useRef(options.onAuthError)
    const sessionIdRef = useRef(options.sessionId)
    const tokenRef = useRef(options.token)
    const baseUrlRef = useRef(options.baseUrl)
    const lastSizeRef = useRef<{ cols: number; rows: number }>({ cols: 80, rows: 24 })
    // Whether the viewer currently wants the PTY streamed. Connecting alone must
    // NOT subscribe — SessionChat mounts this hidden for every PTY session, and
    // an unconditional subscribe-on-connect would stream the high-frequency raw
    // TUI even when the terminal is never opened. Subscribe is gated on this so
    // (re)connects only re-subscribe when the terminal is actually visible.
    const subscribedRef = useRef(false)

    useEffect(() => {
        sessionIdRef.current = options.sessionId
        baseUrlRef.current = options.baseUrl
        onAuthErrorRef.current = options.onAuthError
    }, [options.sessionId, options.baseUrl, options.onAuthError])

    const clearReconnectTimer = useCallback(() => {
        if (reconnectTimerRef.current) {
            clearTimeout(reconnectTimerRef.current)
            reconnectTimerRef.current = null
        }
    }, [])

    const sendFrame = useCallback((ws: WebSocket | null, frame: Record<string, unknown>) => {
        if (!ws || ws.readyState !== WebSocket.OPEN) {
            return
        }
        ws.send(JSON.stringify(frame))
    }, [])

    const openSocket = useCallback(() => {
        clearReconnectTimer()
        const token = tokenRef.current
        const sessionId = sessionIdRef.current

        if (!token || !sessionId) {
            setState({ status: 'error', error: 'Missing terminal credentials.' })
            return
        }

        const existing = wsRef.current
        if (existing) {
            existing.onopen = null
            existing.onmessage = null
            existing.onerror = null
            existing.onclose = null
            if (existing.readyState === WebSocket.OPEN || existing.readyState === WebSocket.CONNECTING) {
                existing.close()
            }
            wsRef.current = null
        }

        manualCloseRef.current = false
        exitedRef.current = false
        setState({ status: 'connecting' })

        const url = buildV1TerminalWsUrl(baseUrlRef.current, sessionId, token)
        const ws = new WebSocket(url)
        let didOpen = false
        wsRef.current = ws

        ws.onopen = () => {
            if (wsRef.current !== ws) return
            didOpen = true
            reconnectAttemptRef.current = 0
            consecutivePreOpenFailuresRef.current = 0
            // Re-subscribe across reconnects only if the viewer still wants it.
            if (subscribedRef.current) {
                const { cols, rows } = lastSizeRef.current
                sendFrame(ws, {
                    type: 'open',
                    terminal_id: AGENT_TERMINAL_ID,
                    cols,
                    rows
                })
            }
            setState({ status: 'connected' })
        }

        ws.onmessage = (event) => {
            if (wsRef.current !== ws || typeof event.data !== 'string') return
            let frame: ServerTerminalFrame
            try {
                frame = JSON.parse(event.data) as ServerTerminalFrame
            } catch {
                return
            }
            const tid = frame.terminal_id ?? frame.terminalId
            if (tid !== AGENT_TERMINAL_ID) return
            if (frame.type === 'ready') {
                setState({ status: 'connected' })
            } else if (frame.type === 'output' && typeof frame.data === 'string') {
                outputHandlerRef.current(frame.data)
            } else if (frame.type === 'exit') {
                exitedRef.current = true
                manualCloseRef.current = true
                clearReconnectTimer()
                setState({ status: 'error', error: 'Terminal exited.' })
                ws.close()
            } else if (frame.type === 'error') {
                setState({ status: 'error', error: frame.message || 'Terminal error' })
            }
        }

        ws.onerror = () => {
            if (wsRef.current !== ws) return
            setState({ status: 'error', error: 'Connection error' })
        }

        ws.onclose = (event) => {
            if (wsRef.current !== ws) return
            wsRef.current = null
            if (exitedRef.current) {
                return
            }
            if (manualCloseRef.current) {
                setState({ status: 'idle' })
                return
            }
            const isExplicitAuthClose = event.code === 1008 || /auth|token|jwt|unauthorized/i.test(event.reason || '')
            if (!didOpen) {
                consecutivePreOpenFailuresRef.current += 1
            }
            if (isExplicitAuthClose || consecutivePreOpenFailuresRef.current >= 2) {
                onAuthErrorRef.current?.()
            }
            const reason = event.reason || `code ${event.code}`
            setState({ status: 'error', error: `Disconnected: ${reason}` })
            const delay = Math.min(
                RECONNECT_BASE_DELAY_MS * (2 ** reconnectAttemptRef.current),
                RECONNECT_MAX_DELAY_MS
            )
            reconnectAttemptRef.current += 1
            reconnectTimerRef.current = setTimeout(() => {
                reconnectTimerRef.current = null
                if (!manualCloseRef.current && !exitedRef.current) {
                    openSocket()
                }
            }, delay)
        }
    }, [clearReconnectTimer, sendFrame])

    useEffect(() => {
        tokenRef.current = options.token
        const ws = wsRef.current
        if (!ws) {
            return
        }
        if (!options.token) {
            manualCloseRef.current = true
            clearReconnectTimer()
            ws.close()
            wsRef.current = null
            return
        }
        if (ws.readyState === WebSocket.OPEN) {
            openSocket()
        }
    }, [options.token, clearReconnectTimer, openSocket])

    const connect = useCallback(() => {
        const ws = wsRef.current
        if (ws) {
            if (ws.readyState === WebSocket.OPEN) {
                setState({ status: 'connected' })
                return
            }
            if (ws.readyState === WebSocket.CONNECTING) {
                return
            }
        }
        openSocket()
    }, [openSocket])

    const disconnect = useCallback(() => {
        manualCloseRef.current = true
        clearReconnectTimer()
        const ws = wsRef.current
        if (!ws) {
            return
        }
        if (ws.readyState === WebSocket.OPEN && subscribedRef.current) {
            sendFrame(ws, { type: 'close', terminal_id: AGENT_TERMINAL_ID })
        }
        ws.onopen = null
        ws.onmessage = null
        ws.onerror = null
        ws.onclose = null
        ws.close()
        wsRef.current = null
        setState({ status: 'idle' })
    }, [clearReconnectTimer, sendFrame])

    useEffect(() => () => disconnect(), [disconnect])

    const resubscribe = useCallback(() => {
        subscribedRef.current = true
        const ws = wsRef.current
        const sessionId = sessionIdRef.current
        if (ws?.readyState === WebSocket.OPEN && sessionId) {
            const { cols, rows } = lastSizeRef.current
            sendFrame(ws, {
                type: 'open',
                terminal_id: AGENT_TERMINAL_ID,
                cols,
                rows
            })
        }
    }, [sendFrame])

    // Tell the hub we're no longer viewing, so the CLI can stop streaming the PTY
    // when no viewers remain. (Safe to miss — the runner keeps streaming until it
    // hears this, never the other way around, so a missed unsubscribe never
    // causes a black screen.)
    const unsubscribe = useCallback(() => {
        subscribedRef.current = false
        const ws = wsRef.current
        const sessionId = sessionIdRef.current
        if (ws?.readyState === WebSocket.OPEN && sessionId) {
            sendFrame(ws, { type: 'close', terminal_id: AGENT_TERMINAL_ID })
        }
    }, [sendFrame])

    const resize = useCallback((cols: number, rows: number) => {
        if (cols < 1 || rows < 1) {
            return
        }
        lastSizeRef.current = { cols, rows }
        const ws = wsRef.current
        const sessionId = sessionIdRef.current
        if (ws?.readyState !== WebSocket.OPEN || !sessionId) {
            return
        }
        sendFrame(ws, {
            type: 'resize',
            terminal_id: AGENT_TERMINAL_ID,
            cols,
            rows
        })
    }, [sendFrame])

    const onOutput = useCallback((handler: (data: string) => void) => {
        outputHandlerRef.current = handler
    }, [])

    const sendInput = useCallback((data: string) => {
        const ws = wsRef.current
        const sessionId = sessionIdRef.current
        if (ws?.readyState !== WebSocket.OPEN || !sessionId || !data) {
            return
        }
        sendFrame(ws, {
            type: 'write',
            terminal_id: AGENT_TERMINAL_ID,
            data
        })
    }, [sendFrame])

    return {
        state,
        connect,
        disconnect,
        resubscribe,
        unsubscribe,
        onOutput,
        resize,
        sendInput
    }
}
