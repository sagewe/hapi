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
function setup(machines = [{ id: 'only', active: true }] as Machine[]) {
    const success = vi.fn()
    render(<AssistantNewSession api={{} as ApiClient} machines={machines} profile={profile} onSuccess={success} onCancel={() => {}} />)
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
    it('keeps codex available through the advanced option', async () => {
        setup()
        fireEvent.click(screen.getByLabelText('使用 Codex 交叉核验'))
        fireEvent.click(screen.getByText('直接新建空白调查'))
        await waitFor(() => expect(spawn).toHaveBeenCalledWith(expect.objectContaining({ agent: 'codex', permissionMode: 'default' })))
    })
})
