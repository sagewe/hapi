import { lazy, Suspense, useCallback, useEffect, useState } from 'react'
import { RealtimeVoiceSession } from './RealtimeVoiceSession'
import type { RealtimeVoiceSessionProps } from './RealtimeVoiceSession'
import { fetchVoiceBackend } from '@/api/voice'
import { resolveSelectedVoiceBackend } from '@/lib/voicePickerPreferences'
import type { ApiClient } from '@/api/client'
import type { VoiceBackendType } from '@hapi/protocol/voice'

// Lazy-load alternative backends to avoid bundling when using ElevenLabs
const GeminiLiveVoiceSession = lazy(() =>
    import('./GeminiLiveVoiceSession').then((m) => ({ default: m.GeminiLiveVoiceSession }))
)
const QwenVoiceSession = lazy(() =>
    import('./QwenVoiceSession').then((m) => ({ default: m.QwenVoiceSession }))
)

export type VoiceBackendSessionProps = RealtimeVoiceSessionProps & {
    api: ApiClient
    onReadyChange?: (ready: boolean) => void
}

/**
 * Selects voice session from user preference (when multiple backends configured) or hub default.
 * Queries GET /voice/backend once on mount and renders the appropriate component.
 * Only signals readiness after the selected backend has mounted and registered its session.
 */
const SUPPORTED_REALTIME_VOICE_BACKENDS = new Set<VoiceBackendType>([
    'elevenlabs',
    'gemini-live',
    'qwen-realtime'
])

function isSupportedRealtimeBackend(value: string | null | undefined): value is VoiceBackendType {
    return typeof value === 'string' && SUPPORTED_REALTIME_VOICE_BACKENDS.has(value as VoiceBackendType)
}

export function VoiceBackendSession(props: VoiceBackendSessionProps) {
    const [backend, setBackend] = useState<VoiceBackendType | null>(null)

    useEffect(() => {
        let cancelled = false
        setBackend(null)
        fetchVoiceBackend(props.api).then((resp) => {
            if (!cancelled) {
                const supportedBackends = resp.backends.filter(isSupportedRealtimeBackend)
                const supportedDefault = isSupportedRealtimeBackend(resp.backend) ? resp.backend : null
                setBackend(resolveSelectedVoiceBackend(supportedBackends, supportedDefault))
            }
        }).catch((err: unknown) => {
            if (!cancelled) {
                // Detection runs on mount for every session, not in response to a user action,
                // so it must not raise the global voice error banner. Leaving `backend` null
                // keeps `onReadyChange` false, which disables the voice button.
                console.error('Could not detect voice backend:', err)
            }
        })
        return () => {
            cancelled = true
            props.onReadyChange?.(false)
        }
    }, [props.api]) // eslint-disable-line react-hooks/exhaustive-deps

    const handleRegistered = useCallback(() => {
        props.onReadyChange?.(true)
    }, [props.onReadyChange])

    if (!backend) return null

    if (backend === 'gemini-live') {
        return (
            <Suspense fallback={null}>
                <GeminiLiveVoiceSession {...props} onRegistered={handleRegistered} />
            </Suspense>
        )
    }

    if (backend === 'qwen-realtime') {
        return (
            <Suspense fallback={null}>
                <QwenVoiceSession {...props} onRegistered={handleRegistered} />
            </Suspense>
        )
    }

    return <RealtimeVoiceSession {...props} onRegistered={handleRegistered} />
}
