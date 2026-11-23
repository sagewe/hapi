import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { splitAgyModelSelection } from '@hapi/protocol'
import type { ClientModelPreset, ClientProfile } from '@hapi/protocol/apiTypes'
import type { ApiClient } from '@/api/client'
import type { Session } from '@/types/api'
import { queryKeys } from '@/lib/query-keys'

export function defaultPreset(profile: ClientProfile): ClientModelPreset | undefined {
    return profile.modelPresets?.find(p => p.isDefault) ?? profile.modelPresets?.find(p => p.model === profile.defaultModel) ?? profile.modelPresets?.[0]
}
export function AssistantModelPresetPicker(props: { presets: ClientModelPreset[]; value: string; disabled?: boolean; onSelect: (preset: ClientModelPreset) => void }) {
    return <div role="group" aria-label="调查模式" className="inline-flex shrink-0 gap-1 rounded-lg bg-[var(--app-secondary-bg)] p-1">
        {props.presets.map(p => <button key={p.id} type="button" aria-pressed={props.value === p.id}
            disabled={props.disabled} onClick={() => props.onSelect(p)}
            className={`min-h-8 rounded-md px-3 text-sm disabled:opacity-50 ${props.value === p.id ? 'bg-[var(--app-bg)] font-semibold shadow-sm' : 'text-[var(--app-hint)]'}`}>{p.label}</button>)}
    </div>
}
export function AssistantChatModelPicker(props: { profile: ClientProfile; api: ApiClient; session: Pick<Session, 'id' | 'active' | 'model' | 'effort'> }) {
    const queryClient = useQueryClient()
    const [failed, setFailed] = useState(false)
    const mutation = useMutation({
        mutationFn: (preset: ClientModelPreset) => props.api.setModel(props.session.id, preset.model, { effort: preset.effort ?? null }),
        onSuccess: () => { void queryClient.invalidateQueries({ queryKey: queryKeys.session(props.session.id) }); setFailed(false) },
        onError: () => setFailed(true)
    })
    const selected = props.profile.modelPresets?.find(p => {
        const split = splitAgyModelSelection(p.model)
        return (props.session.model === p.model || props.session.model === split.model)
            && (!p.effort || props.session.effort === p.effort || (!props.session.effort && props.session.model === p.model))
    })
    const list = props.profile.modelPresets ?? []
    return <div><button type="button" className="assistant-mode" aria-label="切换调查档位"
        disabled={mutation.isPending || !props.session.active || !list.length}
        onClick={() => { const index = list.findIndex(p => p.id === selected?.id); const next = list[(index + 1) % list.length]; if (next) mutation.mutate(next) }}>
        {selected?.label === '快速' ? 'ϟ' : '✦'} {selected?.label ?? '深度'}
    </button>{failed && <span role="alert" className="text-xs text-red-600">切换暂未成功，请重试</span>}</div>
}
