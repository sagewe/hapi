import { useCallback, useEffect, useState } from 'react'

export const DEFAULT_SHOW_ARCHIVED_SESSIONS = false

function getShowArchivedSessionsStorageKey(): string {
    return 'hapi-show-archived-sessions'
}

function isBrowser(): boolean {
    return typeof window !== 'undefined' && typeof document !== 'undefined'
}

function safeGetItem(key: string): string | null {
    if (!isBrowser()) {
        return null
    }
    try {
        return localStorage.getItem(key)
    } catch {
        return null
    }
}

function safeSetItem(key: string, value: string): void {
    if (!isBrowser()) {
        return
    }
    try {
        localStorage.setItem(key, value)
    } catch {
        // Ignore storage errors
    }
}

function safeRemoveItem(key: string): void {
    if (!isBrowser()) {
        return
    }
    try {
        localStorage.removeItem(key)
    } catch {
        // Ignore storage errors
    }
}

function parseShowArchivedSessions(raw: string | null): boolean {
    if (raw === 'true') {
        return true
    }
    return DEFAULT_SHOW_ARCHIVED_SESSIONS
}

export function getInitialShowArchivedSessions(): boolean {
    return parseShowArchivedSessions(safeGetItem(getShowArchivedSessionsStorageKey()))
}

export function useShowArchivedSessions(): {
    showArchivedSessions: boolean
    setShowArchivedSessions: (value: boolean) => void
} {
    const [showArchivedSessions, setShowArchivedSessionsState] = useState<boolean>(getInitialShowArchivedSessions)

    useEffect(() => {
        if (!isBrowser()) {
            return
        }

        const onStorage = (event: StorageEvent) => {
            if (event.key !== getShowArchivedSessionsStorageKey()) {
                return
            }
            setShowArchivedSessionsState(parseShowArchivedSessions(event.newValue))
        }

        const onLocalChange = (event: Event) => setShowArchivedSessionsState((event as CustomEvent<boolean>).detail)
        window.addEventListener('storage', onStorage)
        window.addEventListener('hapi-archived-display-change', onLocalChange)
        return () => {
            window.removeEventListener('storage', onStorage)
            window.removeEventListener('hapi-archived-display-change', onLocalChange)
        }
    }, [])

    const setShowArchivedSessions = useCallback((value: boolean) => {
        setShowArchivedSessionsState(value)

        if (value === DEFAULT_SHOW_ARCHIVED_SESSIONS) {
            safeRemoveItem(getShowArchivedSessionsStorageKey())
        } else {
            safeSetItem(getShowArchivedSessionsStorageKey(), String(value))
        }
        if (isBrowser()) window.dispatchEvent(new CustomEvent('hapi-archived-display-change', { detail: value }))
    }, [])

    return { showArchivedSessions, setShowArchivedSessions }
}
