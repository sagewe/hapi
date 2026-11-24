import { afterEach, describe, expect, it } from 'bun:test'
import { Server as SocketIOServer } from 'socket.io'
import { Store } from '../store'
import { RpcRegistry } from '../socket/rpcRegistry'
import { SSEManager } from '../sse/sseManager'
import { VisibilityTracker } from '../visibility/visibilityTracker'
import { SyncEngine, type SyncEvent } from '../sync/syncEngine'
import { BuiltinAgentLoopRuntime } from './runtime'
import type { Settings } from '../config/settings'

const servers: Array<ReturnType<typeof Bun.serve>> = []
const runtimes: BuiltinAgentLoopRuntime[] = []
const engines: SyncEngine[] = []

afterEach(() => {
    for (const rt of runtimes.splice(0)) rt.stop()
    for (const eng of engines.splice(0)) eng.stop()
    for (const srv of servers.splice(0)) srv.stop(true)
})

async function waitFor(predicate: () => boolean, timeoutMs = 4000): Promise<void> {
    const deadline = Date.now() + timeoutMs
    while (Date.now() < deadline) {
        if (predicate()) return
        await new Promise((r) => setTimeout(r, 20))
    }
    throw new Error('Timed out waiting for condition')
}

describe('BuiltinAgentLoopRuntime end-to-end with Model Gateway + Streamable HTTP MCP', () => {
    it('registers virtual machine, runs multi-step MCP + search tools, emits tool_receipt, and isolates namespaces', async () => {
        let mcpInitCount = 0
        let mcpControlCalls: Array<Record<string, unknown>> = []
        let llmCallCount = 0
        let searchQueries: string[] = []

        // 1. Mock Streamable HTTP MCP Server (mirrors myhome-hub /mcp protocol)
        const mcpServer = Bun.serve({
            port: 0,
            async fetch(req) {
                expect(req.headers.get('authorization')).toBe('Bearer mcp-secret-123')
                const body = (await req.json()) as { id: number; method: string; params?: Record<string, unknown> }
                if (body.method === 'initialize') {
                    mcpInitCount += 1
                    return Response.json(
                        {
                            jsonrpc: '2.0',
                            id: body.id,
                            result: {
                                protocolVersion: '2025-11-25',
                                capabilities: { tools: { listChanged: false } },
                                serverInfo: { name: 'myhome', version: '1.0.0' }
                            }
                        },
                        { headers: { 'mcp-session-id': 'mcp-sid-1' } }
                    )
                }
                if (body.method === 'tools/list') {
                    return Response.json({
                        jsonrpc: '2.0',
                        id: body.id,
                        result: {
                            tools: [
                                {
                                    name: 'control_entity',
                                    description: '控制家庭设备',
                                    inputSchema: {
                                        type: 'object',
                                        properties: {
                                            entity_id: { type: 'string' },
                                            property: { type: 'string' },
                                            value: { type: 'boolean' }
                                        },
                                        required: ['entity_id', 'property', 'value']
                                    }
                                }
                            ]
                        }
                    })
                }
                if (body.method === 'tools/call') {
                    const params = body.params as { name: string; arguments: Record<string, unknown> }
                    mcpControlCalls.push(params.arguments)
                    return Response.json({
                        jsonrpc: '2.0',
                        id: body.id,
                        result: {
                            isError: false,
                            content: [
                                {
                                    type: 'text',
                                    text: JSON.stringify({
                                        ok: true,
                                        entity_id: params.arguments.entity_id,
                                        name: '客厅主灯',
                                        property: params.arguments.property,
                                        value: params.arguments.value
                                    })
                                }
                            ]
                        }
                    })
                }
                return Response.json({ jsonrpc: '2.0', id: body.id, error: { code: -32601, message: 'Method not found' } })
            }
        })
        servers.push(mcpServer)

        // 2. Mock standalone Model Gateway (/v1/ai/chat/completions + /v1/ai/search)
        const gatewayServer = Bun.serve({
            port: 0,
            async fetch(req) {
                expect(req.headers.get('authorization')).toBe('Bearer gw-secret-456')
                const url = new URL(req.url)
                if (url.pathname === '/v1/ai/search') {
                    const body = (await req.json()) as { query: string }
                    searchQueries.push(body.query)
                    return Response.json({
                        provider: 'deepseek',
                        results: [{ title: '上海天气', url: 'https://example.com', snippet: '晴 22°C' }]
                    })
                }
                if (url.pathname === '/v1/ai/chat/completions') {
                    llmCallCount += 1
                    const body = (await req.json()) as { model: string; messages: Array<{ role: string }>; tools?: Array<{ function: { name: string } }> }
                    expect(body.model).toBe('gemini-4-hydrogen')
                    if (llmCallCount === 1) {
                        const toolNames = (body.tools ?? []).map((t) => t.function.name)
                        expect(toolNames).toContain('control_entity')
                        expect(toolNames).toContain('web_search')
                        expect(toolNames).toContain('get_current_time')
                        return Response.json({
                            choices: [{
                                finish_reason: 'tool_calls',
                                message: {
                                    role: 'assistant',
                                    content: null,
                                    tool_calls: [
                                        {
                                            id: 'call_light_1',
                                            type: 'function',
                                            function: {
                                                name: 'control_entity',
                                                arguments: JSON.stringify({ entity_id: 'living_room.light', property: 'on', value: true })
                                            }
                                        },
                                        {
                                            id: 'call_search_1',
                                            type: 'function',
                                            function: {
                                                name: 'web_search',
                                                arguments: JSON.stringify({ query: '上海天气', limit: 3 })
                                            }
                                        }
                                    ]
                                }
                            }]
                        })
                    }
                    // Second round sees tool outputs and emits final Chinese answer
                    expect(body.messages.some((m) => m.role === 'tool')).toBe(true)
                    return Response.json({
                        choices: [{
                            finish_reason: 'stop',
                            message: {
                                role: 'assistant',
                                content: '已为你打开客厅主灯，今天上海晴 22°C。'
                            }
                        }]
                    })
                }
                return new Response('not found', { status: 404 })
            }
        })
        servers.push(gatewayServer)

        // 3. Real Store + SyncEngine + BuiltinAgentLoopRuntime
        const store = new Store(':memory:')
        const io = new SocketIOServer()
        const rpcRegistry = new RpcRegistry()
        const sseManager = new SSEManager(0, new VisibilityTracker())
        const engine = new SyncEngine(store, io as never, rpcRegistry, sseManager)
        engines.push(engine)

        const events: SyncEvent[] = []
        engine.subscribe((ev) => events.push(ev))

        const settings: Settings = {
            namespaces: {
                household: {
                    token: 'household-secret',
                    agentLoop: {
                        enabled: true,
                        machineName: '家庭中枢内置引擎',
                        modelGatewayUrl: gatewayServer.url.origin,
                        modelGatewayToken: 'gw-secret-456',
                        defaultModel: 'gemini-4-hydrogen',
                        mcpServers: [{ name: 'myhome', url: `${mcpServer.url.origin}/mcp`, token: 'mcp-secret-123' }]
                    }
                }
            }
        }

        const runtime = new BuiltinAgentLoopRuntime(engine.createBuiltinRuntimeHost(), settings)
        runtimes.push(runtime)
        engine.attachBuiltinAgentLoop(runtime)
        runtime.start()

        // Virtual machine visible ONLY in household namespace
        const householdMachines = engine.getOnlineMachinesByNamespace('household')
        expect(householdMachines).toHaveLength(1)
        expect(householdMachines[0].id).toBe('builtin:household')
        expect(householdMachines[0].active).toBe(true)
        expect(engine.getOnlineMachinesByNamespace('default')).toHaveLength(0)

        // Spawn built-in session without any Socket.IO Runner
        const spawned = await engine.spawnSession(
            'builtin:household',
            '/household',
            'pi',
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            undefined,
            'household'
        )
        expect(spawned.type).toBe('success')
        if (spawned.type !== 'success') throw new Error('spawn failed')
        const sessionId = spawned.sessionId
        expect(engine.getSessionByNamespace(sessionId, 'household')?.active).toBe(true)
        expect(engine.getSessionByNamespace(sessionId, 'default')).toBeUndefined()

        // Send user message and wait for final assistant message & thinking=false
        await engine.sendMessage(sessionId, { text: '打开客厅主灯，顺便查下上海天气', localId: 'loc-1' })
        await waitFor(() => store.messages.getAllMessages(sessionId).length >= 6 && engine.getSession(sessionId)?.thinking === false)

        expect(mcpInitCount).toBe(1)
        expect(mcpControlCalls).toEqual([{ entity_id: 'living_room.light', property: 'on', value: true }])
        expect(searchQueries).toEqual(['上海天气'])
        expect(llmCallCount).toBe(2)

        const stored = store.messages.getAllMessages(sessionId)
        // Expect: 1 user + 2 tool_use + 2 tool_result (with tool_receipt) + 1 final assistant = 6 rows
        expect(stored).toHaveLength(6)
        expect(stored[0].invokedAt).not.toBeNull()

        const deviceResult = stored[2].content as {
            content: { data: { message: { content: Array<{ tool_receipt?: Record<string, unknown> }> } } }
            meta?: { toolReceipt?: Record<string, unknown> }
        }
        expect(deviceResult.meta?.toolReceipt).toMatchObject({
            schemaVersion: 1,
            tool: 'control_entity',
            server: 'myhome',
            kind: 'device_control',
            ok: true,
            summary: '客厅主灯：on=true'
        })
        expect(deviceResult.content.data.message.content[0].tool_receipt).toMatchObject({
            kind: 'device_control',
            ok: true
        })

        const searchResult = stored[4].content as { meta?: { toolReceipt?: Record<string, unknown> } }
        expect(searchResult.meta?.toolReceipt).toMatchObject({
            schemaVersion: 1,
            tool: 'web_search',
            server: 'builtin',
            kind: 'search',
            ok: true,
            summary: '搜索返回 1 条结果'
        })

        const finalMsg = stored[5].content as {
            content: { data: { message: { content: Array<{ type: string; text: string }> } } }
        }
        expect(finalMsg.content.data.message.content[0].text).toBe('已为你打开客厅主灯，今天上海晴 22°C。')

        // Model switch works cleanly without RPC
        await engine.applySessionConfig(sessionId, { model: 'deepseek-chat' })
        expect(engine.getSession(sessionId)?.model).toBe('deepseek-chat')
    })

    it('supports abortSession during an in-flight LLM request', async () => {
        const slowGateway = Bun.serve({
            port: 0,
            async fetch(req) {
                await new Promise((resolve) => {
                    const timer = setTimeout(resolve, 10_000)
                    req.signal.addEventListener('abort', () => {
                        clearTimeout(timer)
                        resolve(undefined)
                    })
                })
                return new Response('aborted', { status: 499 })
            }
        })
        servers.push(slowGateway)

        const store = new Store(':memory:')
        const io = new SocketIOServer()
        const rpcRegistry = new RpcRegistry()
        const sseManager = new SSEManager(0, new VisibilityTracker())
        const engine = new SyncEngine(store, io as never, rpcRegistry, sseManager)
        engines.push(engine)

        const events: SyncEvent[] = []
        engine.subscribe((ev) => events.push(ev))

        const runtime = new BuiltinAgentLoopRuntime(engine.createBuiltinRuntimeHost(), {
            namespaces: {
                household: {
                    agentLoop: {
                        enabled: true,
                        modelGatewayUrl: slowGateway.url.origin,
                        defaultModel: 'auto',
                        enableWebSearch: false
                    }
                }
            }
        })
        runtimes.push(runtime)
        engine.attachBuiltinAgentLoop(runtime)
        runtime.start()

        const spawned = await engine.spawnSession(
            'builtin:household', '/household', 'pi',
            undefined, undefined, undefined, undefined, undefined, undefined,
            undefined, undefined, undefined, undefined, undefined, undefined, undefined,
            'household'
        )
        if (spawned.type !== 'success') throw new Error('spawn failed')

        await engine.sendMessage(spawned.sessionId, { text: '长任务测试', localId: 'loc-abort' })
        await waitFor(() => engine.getSession(spawned.sessionId)?.thinking === true)
        await engine.abortSession(spawned.sessionId)
        await waitFor(() => store.messages.getAllMessages(spawned.sessionId).length >= 2 && engine.getSession(spawned.sessionId)?.thinking === false)

        expect(engine.getSession(spawned.sessionId)?.thinking).toBe(false)
        const messages = store.messages.getAllMessages(spawned.sessionId)
        const last = messages[messages.length - 1].content as {
            content: { data: { message: { content: Array<{ text: string }> } } }
        }
        expect(last.content.data.message.content[0].text).toContain('已停止')
    })
})
