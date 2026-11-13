import type { InitialResponseState } from '@/chat/initialResponse'
import { Spinner } from '@/components/Spinner'
import { useTranslation } from '@/lib/use-translation'

export function InitialResponseFeedback({ state }: { state: InitialResponseState | null }) {
    const { t } = useTranslation()
    if (!state) return null
    return <div data-testid="chat-response-feedback" data-hapi-share-exclude="true" role="status" aria-live="polite"
        className="flex min-h-7 items-center gap-2 px-1 text-sm text-[var(--app-hint)]">
        <Spinner size="sm" label={null} className="motion-reduce:animate-none" />
        <span>{t(`chat.response.${state}`)}</span>
    </div>
}
