import { cleanup, render, fireEvent, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { ApiClient } from '@/api/client'
import type { Machine } from '@/types/api'
import { ClientProfileContext } from '@/lib/client-profile'
import { AssistantWorkspace } from './AssistantWorkspace'
const navigate = vi.hoisted(() => vi.fn())
vi.mock('@tanstack/react-router', () => ({ useNavigate: () => navigate, useLocation: () => '/sessions' }))
afterEach(cleanup)
it('selecting a scene shows a removable chip without allocating a session', async () => {
    const spawnSession = vi.fn().mockResolvedValue({ type: 'success', sessionId: 'case' })
    const sendMessage = vi.fn().mockResolvedValue(undefined)
    const api = { spawnSession, sendMessage } as unknown as ApiClient
    render(<ClientProfileContext.Provider value={{ mode: 'assistant', defaultDirectory: '/cases', defaultPermissionMode: 'always-proceed', quickActions: [
        { id: 'company', title: '企业穿透', prompt: 'Long hidden instructions' }, { id: 'document', title: '单据审核', prompt: 'Review documents' }
    ] }}><AssistantWorkspace api={api} machines={[{ id: 'runner', active: true }] as Machine[]} sessions={[]} refresh={() => {}}><p>developer outlet</p></AssistantWorkspace></ClientProfileContext.Provider>)
    expect(screen.queryByText('developer outlet')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: '企业股权穿透' }))
    expect(screen.getByRole('textbox', { name: '调查线索' })).toHaveValue('')
    expect(screen.getByPlaceholderText('输入公司名称、税号或注册号…')).toBeInTheDocument()
    expect(spawnSession).not.toHaveBeenCalled()
    fireEvent.change(screen.getByRole('textbox', { name: '调查线索' }), { target: { value: '示例公司' } })
    expect(spawnSession).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: '发送调查' }))
    await waitFor(() => expect(sendMessage).toHaveBeenCalledWith('case', expect.stringContaining('示例公司'), expect.any(String), []))
    expect(spawnSession).toHaveBeenCalledTimes(1)
    await waitFor(() => expect(screen.getByRole('textbox', { name: '调查线索' })).toHaveValue(''))
    fireEvent.change(screen.getByRole('textbox', { name: '调查线索' }), { target: { value: '另一家示例公司' } })
    fireEvent.click(screen.getByRole('button', { name: '发送调查' }))
    await waitFor(() => expect(spawnSession).toHaveBeenCalledTimes(2))
})
