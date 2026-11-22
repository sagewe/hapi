import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ClientProfile } from '@hapi/protocol/apiTypes'
import type { ApiClient } from '@/api/client'
import type { Machine } from '@/types/api'
import { AssistantNewSession } from './AssistantNewSession'
import { getDraft } from '@/lib/composer-drafts'

const spawn = vi.hoisted(() => vi.fn())
vi.mock('@/hooks/mutations/useSpawnSession', () => ({ useSpawnSession: () => ({ spawnSession: spawn, isPending: false }) }))
const profile: ClientProfile = { mode: 'assistant', defaultAgent: 'agy', defaultPermissionMode: 'auto', defaultDirectory: '/compliance',
    quickActions: [{ id: 'company', title: '企业穿透', prompt: '请核查：' }] }
function setup(machines = [{ id: 'only', active: true }] as Machine[], settings = profile) {
    const success = vi.fn()
    render(<AssistantNewSession api={{} as ApiClient} machines={machines} profile={settings} onSuccess={success} onCancel={() => {}} />)
    return success
}
afterEach(cleanup)
beforeEach(() => { spawn.mockReset(); spawn.mockResolvedValue({ type: 'success', sessionId: 'new-investigation' }) })
describe('Assistant new investigation', () => {
    it('uses hub defaults and saves the selected prompt for review before sending', async () => {
        const success = setup()
        fireEvent.click(screen.getByText('企业穿透'))
        await waitFor(() => expect(success).toHaveBeenCalledWith('new-investigation'))
        expect(spawn).toHaveBeenCalledWith(expect.objectContaining({ machineId: 'only', directory: '/compliance', agent: 'agy', permissionMode: 'auto' }))
        expect(getDraft('new-investigation')).toBe('请核查：')
        expect(screen.queryByText('Machine')).toBeNull()
    })
    it.each([{ machines: [] }, { machines: [{ id: 'one', active: true }, { id: 'two', active: true }] }])('does not guess an unavailable or ambiguous runner', async ({ machines }) => {
        setup(machines as Machine[])
        fireEvent.click(screen.getByText('直接新建空白调查'))
        expect(await screen.findByRole('alert')).toHaveTextContent('后台调查服务暂时离线')
        expect(spawn).not.toHaveBeenCalled()
    })
    it.each(['always-proceed', 'yolo'] as const)('maps %s to codex yolo in the actual spawn payload', async mode => {
        setup(undefined, { ...profile, defaultPermissionMode: mode })
        fireEvent.click(screen.getByLabelText('使用 Codex 交叉核验'))
        fireEvent.click(screen.getByText('直接新建空白调查'))
        await waitFor(() => expect(spawn).toHaveBeenCalledWith(expect.objectContaining({ agent: 'codex', permissionMode: 'yolo' })))
    })
    it('spawns the selected friendly preset with its exact model and effort', async () => {
        setup(undefined, { ...profile, modelPresets: [
            { id: 'quick', label: '快速', model: 'gemini-4-hydrogen-medium', effort: 'medium' },
            { id: 'deep', label: '深度', model: 'gemini-4-neon-high', effort: 'high', isDefault: true }
        ] })
        expect(screen.getByRole('button', { name: '深度' })).toHaveAttribute('aria-pressed', 'true')
        fireEvent.click(screen.getByRole('button', { name: '快速' }))
        fireEvent.click(screen.getByText('企业穿透'))
        await waitFor(() => expect(spawn).toHaveBeenCalledWith(expect.objectContaining({ model: 'gemini-4-hydrogen-medium', effort: 'medium' })))
        expect(screen.queryByText(/gemini-4/)).toBeNull()
    })
    it('keeps codex available through the advanced option', async () => {
        setup()
        fireEvent.click(screen.getByLabelText('使用 Codex 交叉核验'))
        fireEvent.click(screen.getByText('直接新建空白调查'))
        await waitFor(() => expect(spawn).toHaveBeenCalledWith(expect.objectContaining({ agent: 'codex', permissionMode: 'default' })))
    })
})
