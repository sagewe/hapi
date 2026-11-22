import { assistantPermissionMode } from '@/lib/client-profile'
import { AssistantModelPresetPicker, defaultPreset } from '@/components/AssistantModelPresetPicker'
import { useState } from 'react'
import type { ClientProfile } from '@hapi/protocol/apiTypes'
import type { ApiClient } from '@/api/client'
import type { Machine } from '@/types/api'
import { useSpawnSession } from '@/hooks/mutations/useSpawnSession'
import { saveDraft } from '@/lib/composer-drafts'

export function AssistantNewSession(props: {
    api: ApiClient; machines: Machine[]; profile: ClientProfile;
    onSuccess: (id: string) => void; onCancel: () => void
}) {
    const { spawnSession, isPending } = useSpawnSession(props.api)
    const [error, setError] = useState<string | null>(null)
    const [codex, setCodex] = useState(false)
    const [presetId, setPresetId] = useState(() => defaultPreset(props.profile)?.id ?? '')
    const preset = props.profile.modelPresets?.find(p => p.id === presetId)
    const create = async (prompt?: string) => {
        setError(null)
        const machines = props.machines.filter(m => m.active)
        if (machines.length !== 1) { setError('后台调查服务暂时离线，请稍后重试'); return }
        if (!props.profile.defaultDirectory) { setError('调查服务尚未配置完成，请联系管理员'); return }
        try {
            const result = await spawnSession({ machineId: machines[0]!.id,
                directory: props.profile.defaultDirectory, agent: codex ? 'codex' : props.profile.defaultAgent ?? 'agy',
                model: codex ? undefined : preset?.model ?? props.profile.defaultModel,
                effort: codex ? undefined : preset?.effort,
                permissionMode: assistantPermissionMode(props.profile, codex ? 'codex' : props.profile.defaultAgent ?? 'agy') })
            if (result.type !== 'success') { setError('暂时无法创建调查，请稍后重试'); return }
            if (prompt) saveDraft(result.sessionId, prompt)
            props.onSuccess(result.sessionId)
        } catch { setError('暂时无法创建调查，请稍后重试') }
    }
    return <div className="mx-auto flex max-w-xl flex-col gap-4 p-4">
        <p className="text-sm text-[var(--app-hint)]">选择场景，进入后填写对象或上传图片、PDF。也可以直接开始。</p>
        {!codex && props.profile.modelPresets?.length ? <AssistantModelPresetPicker presets={props.profile.modelPresets}
            value={presetId} disabled={isPending} onSelect={p => setPresetId(p.id)} /> : null}
        {(props.profile.quickActions ?? []).map(action => <button type="button" key={action.id}
            disabled={isPending} onClick={() => void create(action.prompt)}
            className="min-h-20 rounded-2xl bg-[var(--app-secondary-bg)] p-4 text-left disabled:opacity-50">
            <span className="block font-semibold">{action.title}</span>
            <span className="mt-1 block text-sm text-[var(--app-hint)]">{action.subtitle}</span>
        </button>)}
        <button type="button" disabled={isPending} onClick={() => void create()}
            className="min-h-12 rounded-xl bg-[var(--app-button)] p-3 text-[var(--app-button-text)]">{isPending ? '正在准备调查…' : '直接新建空白调查'}</button>
        {error && <p role="alert" className="text-sm text-red-600">{error}</p>}
        <details className="text-sm text-[var(--app-hint)]"><summary>高级</summary>
            <label className="flex min-h-11 items-center gap-2"><input type="checkbox" checked={codex} onChange={e => setCodex(e.target.checked)} />使用 Codex 交叉核验</label>
        </details>
        <button type="button" onClick={props.onCancel} className="min-h-11">取消</button>
    </div>
}
