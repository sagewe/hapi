import { createContext, useContext, type ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'
import { ClientProfileSchema, type ClientProfile } from '@hapi/protocol/apiTypes'
import type { ApiClient } from '@/api/client'

export const ClientProfileContext = createContext<ClientProfile | undefined>(undefined)
export const useClientProfile = () => useContext(ClientProfileContext)

export function ClientProfileProvider(props: { api: ApiClient; baseUrl: string; children: ReactNode }) {
    const storageKey = `hapi:client-profile:${props.baseUrl}`
    const query = useQuery({
        queryKey: ['client-profile', props.baseUrl],
        queryFn: async () => {
            const settings = await props.api.getHubSettings()
            try {
                if (settings.clientProfile) localStorage.setItem(storageKey, JSON.stringify(settings.clientProfile))
                else localStorage.removeItem(storageKey)
            } catch { /* Storage may be unavailable in private browsing. */ }
            return settings.clientProfile ?? null
        },
        initialData: () => {
            try {
                const raw = localStorage.getItem(storageKey)
                if (!raw) return undefined
                const parsed = ClientProfileSchema.safeParse(JSON.parse(raw))
                return parsed.success ? parsed.data : undefined
            } catch { return undefined }
        },
        initialDataUpdatedAt: 0,
        refetchInterval: 30_000,
        refetchOnWindowFocus: true,
        retry: false
    })
    if (query.isPending) return <div className="p-6 text-center" role="status">正在连接…</div>
    return <ClientProfileContext.Provider value={query.data ?? undefined}>{props.children}</ClientProfileContext.Provider>
}

export function useHideExecutionDetails(): boolean {
    const profile = useClientProfile()
    return profile?.mode === 'assistant' && profile.hideExecutionDetails !== false
}

export function assistantPermissionMode(profile: ClientProfile, agent: string) {
    if (agent === 'codex') return ['always-proceed', 'yolo'].includes(profile.defaultPermissionMode ?? '') ? 'yolo' as const : 'default' as const
    return profile.defaultPermissionMode
}
