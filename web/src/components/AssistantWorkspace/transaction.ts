import type { ApiClient } from '@/api/client'
import type { AttachmentMetadata } from '@/types/api'
import type { ClientProfile, ClientQuickAction, ClientModelPreset } from '@hapi/protocol/apiTypes'
import { assistantPermissionMode } from '@/lib/client-profile'

export function sceneTitle(action: ClientQuickAction): string {
    const key = action.id + action.title
    if (/document|单据/.test(key)) return '单据审核'
    if (/individual|自然人/.test(key)) return '自然人核查'
    if (/sanction|制裁/.test(key)) return '制裁与风险'
    return '企业股权穿透'
}
export function scenePlaceholder(action?: ClientQuickAction): string {
    if (!action) return '输入线索，或添加单据…'
    const title = sceneTitle(action)
    return title === '单据审核' ? '添加单据，或补充需要核对的内容…' : title === '自然人核查'
        ? '输入姓名、国籍或关联企业…' : title === '制裁与风险' ? '输入主体、国家或交易线索…' : '输入公司名称、税号或注册号…'
}
export function sceneMessage(text: string, action?: ClientQuickAction): string {
    return action ? `【调查场景：${sceneTitle(action)}】\n\n${text}\n\n<investigation-instructions>\n${action.prompt}\n</investigation-instructions>` : text
}
export function visibleSceneMessage(text: string): string {
    return text.startsWith('【调查场景：') ? text.replace(/\n\n<investigation-instructions>[\s\S]*<\/investigation-instructions>\s*$/, '') : text
}
export function investigationPhase(name: string, input = ''): string {
    const value = `${name} ${input}`.toLowerCase()
    if (/render_pdf|print-to-pdf|report-packaging|zip |zipfile|make_archive/.test(value)) return '正在排版生成中文 PDF 报告…'
    if (/browser|navigate|web|fetch|curl/.test(value)) return '正在访问官网核验原始页面…'
    if (/image|read|document|pdf|ocr/.test(value)) return '正在解析上传单据内容…'
    return '正在检索公开登记与制裁线索…'
}
export class AssistantDraftTransaction {
    sessionId?: string
    private readonly uploads = new Map<File, AttachmentMetadata>()
    private readonly localId = crypto.randomUUID()
    private inFlight: Promise<string> | null = null
    constructor(private readonly api: ApiClient) {}
    send(input: { text: string; scene?: ClientQuickAction; files: File[]; profile: ClientProfile; preset?: ClientModelPreset; machineId: string; codex?: boolean }): Promise<string> {
        if (this.inFlight) return this.inFlight
        if (!input.text.trim() && !input.files.length) return Promise.reject(new Error('请先输入线索或添加资料'))
        this.inFlight = this.perform(input).finally(() => { this.inFlight = null })
        return this.inFlight
    }
    private async perform(input: Parameters<AssistantDraftTransaction['send']>[0]): Promise<string> {
        if (!this.sessionId) {
            const result = await this.api.spawnSession(input.machineId, input.profile.defaultDirectory!, input.codex ? 'codex' : input.profile.defaultAgent ?? 'agy',
                input.codex ? undefined : input.preset?.model ?? input.profile.defaultModel, undefined, undefined, undefined, undefined,
                input.codex ? undefined : input.preset?.effort, assistantPermissionMode(input.profile, input.codex ? 'codex' : 'agy'))
            if (result.type !== 'success') throw new Error('后台调查服务暂时离线，请稍后重试')
            this.sessionId = result.sessionId
        }
        for (const file of input.files) {
            if (this.uploads.has(file)) continue
            const content = await new Promise<string>((resolve, reject) => {
                const reader = new FileReader(); reader.onload = () => resolve((reader.result as string).split(',')[1]!); reader.onerror = reject; reader.readAsDataURL(file)
            })
            const result = await this.api.uploadFile(this.sessionId, file.name, content, file.type || 'application/octet-stream')
            if (!result.success || !result.path) throw new Error('资料暂未上传成功，请重试')
            this.uploads.set(file, { id: crypto.randomUUID(), filename: file.name, mimeType: file.type, size: file.size, path: result.path })
        }
        await this.api.sendMessage(this.sessionId, sceneMessage(input.text.trim() || '请核查所附资料。', input.scene), this.localId, input.files.map(f => this.uploads.get(f)!))
        return this.sessionId
    }
}
