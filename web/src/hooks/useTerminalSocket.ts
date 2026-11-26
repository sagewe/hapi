import { useCallback, useEffect, useRef, useState } from 'react'
import { buildV1TerminalWsUrl } from '@/api/v1Adapters'

type TerminalConnectionState =
    | { status: 'idle' }
    | { status: 'connecting' }
    | { status: 'connected' }
    | { status: 'error'; error: string }

type UseTerminalSocketOptions = {
    baseUrl: string
    token: string
    sessionId: string
    terminalId: string
}

type ServerTerminalFrame =
    | { type: 'ready'; session_id?: string; terminal_id?: string; terminalId?: string }
    | { type: 'output'; session_id?: string; terminal_id?: string; terminalId?: string; data?: string }
    | { type: 'exit'; session_id?: string; terminal_id?: string; terminalId?: string; code?: number | null; signal?: string | null }
    | { type: 'error'; terminal_id?: string; terminalId?: string; message?: string }
    | { type: 'pong' }

const RECONNECT_BASE_DELAY_MS = 1_000
const RECONNECT_MAX_DELAY_MS = 5_000

export function useTerminalSocket(options: UseTerminalSocketOptions): {
    state: TerminalConnectionState
    connect: (cols: number, rows: number) => void
    write: (data: string) => void
    resize: (cols: number, rows: number) => void
    disconnect: () => void
    onOutput: (handler: (data: string) => void) => void
    onExit: (handler: (code: number | null, signal: string | null) => void) => void
} {
    const [state, setState] = useState<TerminalConnectionState>({ status: 'idle' })
    const wsRef = useRef<WebSocket | null>(null)
    const reconnectTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
    const reconnectAttemptRef = useRef(0)
    const manualCloseRef = useRef(false)
    const outputHandlerRef = useRef<(data: string) => void>(() => {})
    const exitHandlerRef = useRef<(code: number | null, signal: string | null) => void>(() => {})
    const sessionIdRef = useRef(options.sessionId)
    const terminalIdRef = useRef(options.terminalId)
    const tokenRef = useRef(options.token)
    const baseUrlRef = useRef(options.baseUrl)
    const lastSizeRef = useRef<{ cols: number; rows: number } | null>(null)

    useEffect(() => {
        sessionIdRef.current = options.sessionId
        terminalIdRef.current = options.terminalId
        baseUrlRef.current = options.baseUrl
    }, [options.sessionId, options.terminalId, options.baseUrl])

    const isCurrentTerminal = useCallback(
        (terminalId?: string) => terminalId === terminalIdRef.current,
        []
    )

    const sendFrame = useCallback((ws: WebSocket | null, frame: Record<string, unknown>) => {
        if (!ws || ws.readyState !== WebSocket.OPEN) {
            return
        }
        ws.send(JSON.stringify(frame))
    }, [])

    const emitOpen = useCallback((ws: WebSocket, size: { cols: number; rows: number }) => {
        sendFrame(ws, {
            type: 'open',
            terminal_id: terminalIdRef.current,
            cols: size.cols,
            rows: size.rows
        })
    }, [sendFrame])

    const setErrorState = useCallback((message: string) => {
        setState({ status: 'error', error: message })
    }, [])

    const clearReconnectTimer = useCallback(() => {
        if (reconnectTimerRef.current) {
            clearTimeout(reconnectTimerRef.current)
            reconnectTimerRef.current = null
        }
    }, [])

    const openSocket = useCallback((cols: number, rows: number) => {
        clearReconnectTimer()
        const token = tokenRef.current
        const sessionId = sessionIdRef.current
        const terminalId = terminalIdRef.current

        if (!token || !sessionId || !terminalId) {
            setErrorState('Missing terminal credentials.')
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
        setState({ status: 'connecting' })

        const url = buildV1TerminalWsUrl(baseUrlRef.current, sessionId, token)
        const ws = new WebSocket(url)
        wsRef.current = ws

        ws.onopen = () => {
            if (wsRef.current !== ws) return
            reconnectAttemptRef.current = 0
            const size = lastSizeRef.current ?? { cols, rows }
            setState({ status: 'connecting' })
            emitOpen(ws, size)
        }

        ws.onmessage = (event) => {
            if (wsRef.current !== ws || typeof event.data !== 'string') return
            let frame: ServerTerminalFrame
            try {
                frame = JSON.parse(event.data) as ServerTerminalFrame
            } catch {
                return
            }
            if (frame.type === 'pong') return
            const frameTerminalId = frame.terminal_id ?? frame.terminalId
            if (!isCurrentTerminal(frameTerminalId)) {
                return
            }
            if (frame.type === 'ready') {
                setState({ status: 'connected' })
            } else if (frame.type === 'output' && typeof frame.data === 'string') {
                outputHandlerRef.current(frame.data)
            } else if (frame.type === 'exit') {
                manualCloseRef.current = true
                exitHandlerRef.current(frame.code ?? null, frame.signal ?? null)
                setErrorState('Terminal exited.')
            } else if (frame.type === 'error') {
                setErrorState(frame.message || 'Terminal error')
            }
        }

        ws.onerror = () => {
            if (wsRef.current !== ws) return
            setErrorState('Connection error')
        }

        ws.onclose = (event) => {
            if (wsRef.current !== ws) return
            wsRef.current = null
            if (manualCloseRef.current) {
                setState({ status: 'idle' })
                return
            }
            const reason = event.reason || `code ${event.code}`
            setErrorState(`Disconnected: ${reason}`)
            const delay = Math.min(
                RECONNECT_BASE_DELAY_MS * (2 ** reconnectAttemptRef.current),
                RECONNECT_MAX_DELAY_MS
            )
            reconnectAttemptRef.current += 1
            reconnectTimerRef.current = setTimeout(() => {
                reconnectTimerRef.current = null
                if (!manualCloseRef.current) {
                    const size = lastSizeRef.current ?? { cols, rows }
                    openSocket(size.cols, size.rows)
                }
            }, delay)
        }
    }, [clearReconnectTimer, emitOpen, isCurrentTerminal, setErrorState])

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
            const size = lastSizeRef.current ?? { cols: 80, rows: 24 }
            openSocket(size.cols, size.rows)
        }
    }, [options.token, clearReconnectTimer, openSocket])

    const connect = useCallback((cols: number, rows: number) => {
        lastSizeRef.current = { cols, rows }
        const ws = wsRef.current
        if (ws && ws.readyState === WebSocket.OPEN) {
            emitOpen(ws, { cols, rows })
            setState({ status: 'connecting' })
            return
        }
        openSocket(cols, rows)
    }, [emitOpen, openSocket])

    const write = useCallback((data: string) => {
        sendFrame(wsRef.current, {
            type: 'write',
            terminal_id: terminalIdRef.current,
            data
        })
    }, [sendFrame])

    const resize = useCallback((cols: number, rows: number) => {
        lastSizeRef.current = { cols, rows }
        sendFrame(wsRef.current, {
            type: 'resize',
            terminal_id: terminalIdRef.current,
            cols,
            rows
        })
    }, [sendFrame])

    const disconnect = useCallback(() => {
        manualCloseRef.current = true
        clearReconnectTimer()
        const ws = wsRef.current
        if (!ws) {
            return
        }
        if (ws.readyState === WebSocket.OPEN) {
            sendFrame(ws, { type: 'close', terminal_id: terminalIdRef.current })
        }
        ws.onopen = null
        ws.onmessage = null
        ws.onerror = null
        ws.onclose = null
        ws.close()
        wsRef.current = null
        setState({ status: 'idle' })
    }, [clearReconnectTimer, sendFrame])

    const onOutput = useCallback((handler: (data: string) => void) => {
        outputHandlerRef.current = handler
    }, [])

    const onExit = useCallback((handler: (code: number | null, signal: string | null) => void) => {
        exitHandlerRef.current = handler
    }, [])

    return {
        state,
        connect,
        write,
        resize,
        disconnect,
        onOutput,
        onExit
    }
}
