import { describe, expect, it, vi } from 'vitest'
import type { ApiClient } from '@/api/client'
import { AssistantDraftTransaction, investigationPhase, sceneMessage, visibleSceneMessage } from './transaction'
const profile = { mode: 'assistant' as const, defaultDirectory: '/investigations', defaultPermissionMode: 'always-proceed' as const }
describe('assistant first-send transaction', () => {
    it('waits for send, coalesces concurrent sends and retries the same session', async () => {
        const spawnSession = vi.fn().mockResolvedValue({ type: 'success', sessionId: 'case' })
        const sendMessage = vi.fn().mockRejectedValueOnce(Error('network')).mockResolvedValue(undefined)
        const tx = new AssistantDraftTransaction({ spawnSession, sendMessage } as unknown as ApiClient)
        expect(spawnSession).not.toHaveBeenCalled()
        const input = { text: '示例公司', files: [], profile, machineId: 'runner' }
        const first = tx.send(input); expect(tx.send(input)).toBe(first)
        await expect(first).rejects.toThrow('network')
        expect(await tx.send(input)).toBe('case')
        expect(spawnSession).toHaveBeenCalledTimes(1)
        expect(sendMessage.mock.calls[0]?.[2]).toBe(sendMessage.mock.calls[1]?.[2])
    })
    it('rejects empty drafts without allocation', async () => {
        const spawnSession = vi.fn(); const tx = new AssistantDraftTransaction({ spawnSession } as unknown as ApiClient)
        await expect(tx.send({ text: ' ', files: [], profile, machineId: 'runner' })).rejects.toThrow()
        expect(spawnSession).not.toHaveBeenCalled()
    })
    it('hides scene instructions from the user transcript', () => {
        const scene = { id: 'company', title: '企业穿透', prompt: '查询官方登记和最终受益人' }
        const full = sceneMessage('示例公司', scene)
        expect(full).toContain(scene.prompt)
        expect(visibleSceneMessage(full)).toBe('【调查场景：企业股权穿透】\n\n示例公司')
    })
    it('selects Chinese stages from actual tool type', () => {
        expect(investigationPhase('Bash', 'python scripts/render_pdf.py')).toBe('正在排版生成中文 PDF 报告…')
        expect(investigationPhase('browser_navigate')).toBe('正在访问官网核验原始页面…')
        expect(investigationPhase('read_image')).toBe('正在解析上传单据内容…')
        expect(investigationPhase('search')).toBe('正在检索公开登记与制裁线索…')
    })
})
