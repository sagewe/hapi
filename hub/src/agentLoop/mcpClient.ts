import type { McpServerConfig, McpToolDefinition, ToolReceipt, ToolReceiptKind } from './types'

const MCP_PROTOCOL_VERSION = '2025-11-25'
const TOOL_CACHE_TTL_MS = 5 * 60_000
const MCP_REQUEST_TIMEOUT_MS = 30_000

interface CachedTools {
    tools: McpToolDefinition[]
    fetchedAt: number
}

interface JsonRpcResponse {
    jsonrpc?: string
    id?: string | number | null
    result?: unknown
    error?: { code?: number; message?: string; data?: unknown }
}

export interface McpToolCallResult {
    ok: boolean
    text: string
    parsedData?: unknown
    durationMs: number
}

function classifyToolKind(toolName: string): ToolReceiptKind {
    if (toolName === 'control_entity') return 'device_control'
    if (toolName === 'get_home_overview' || toolName === 'get_home_history' || toolName === 'get_automations') {
        return 'home_overview'
    }
    if (toolName === 'list_entities' || toolName === 'get_entity_state') return 'entity_list'
    if (toolName.includes('todo')) return 'todo'
    if (toolName.includes('schedule')) return 'schedule'
    if (toolName.includes('memor')) return 'memory'
    if (toolName.includes('camera')) return 'camera'
    if (toolName === 'web_search') return 'search'
    if (toolName === 'get_current_time') return 'time'
    return 'generic'
}

function summarizeToolResult(toolName: string, ok: boolean, parsedData: unknown, text: string): string {
    if (!ok) {
        return text.trim().slice(0, 160) || `${toolName} 执行失败`
    }
    if (parsedData && typeof parsedData === 'object' && !Array.isArray(parsedData)) {
        const rec = parsedData as Record<string, unknown>
        if (typeof rec.summary === 'string' && rec.summary.trim()) {
            return rec.summary.trim().slice(0, 160)
        }
        if (typeof rec.message === 'string' && rec.message.trim()) {
            return rec.message.trim().slice(0, 160)
        }
        if (toolName === 'get_home_overview') {
            const count = Array.isArray(rec.entities)
                ? rec.entities.length
                : typeof rec.entity_count === 'number'
                    ? rec.entity_count
                    : null
            return count !== null ? `已读取全屋概况（${count} 个设备）` : '已读取全屋概况'
        }
        if (toolName === 'control_entity') {
            const name = typeof rec.name === 'string' ? rec.name : typeof rec.entity_id === 'string' ? rec.entity_id : '设备'
            const action = typeof rec.property === 'string' ? `${rec.property}=${String(rec.value ?? '')}` : '已控制'
            return `${name}：${action}`
        }
        if (toolName === 'web_search' && Array.isArray(rec.results)) {
            return `搜索返回 ${rec.results.length} 条结果`
        }
        if (toolName === 'list_todos') {
            const items = Array.isArray(rec.items) ? rec.items : Array.isArray(rec.todos) ? rec.todos : null
            if (items) return `共 ${items.length} 条待办`
            if (typeof rec.open_count === 'number') return `共 ${rec.open_count} 条未完成待办`
            return '已读取待办列表'
        }
        if (toolName === 'list_schedules') {
            const items = Array.isArray(rec.schedules) ? rec.schedules : Array.isArray(rec.items) ? rec.items : null
            return items ? `共 ${items.length} 条定时任务` : '已读取定时任务'
        }
        if (Array.isArray(rec.entities)) {
            return `已读取 ${rec.entities.length} 个设备`
        }
        if (Array.isArray(rec.todos)) {
            return `共 ${rec.todos.length} 条待办`
        }
        if (Array.isArray(rec.schedules)) {
            return `共 ${rec.schedules.length} 条定时任务`
        }
        if (Array.isArray(rec.memories)) {
            return `共 ${rec.memories.length} 条记忆`
        }
        if (Array.isArray(rec.items)) {
            return `共 ${rec.items.length} 条记录`
        }
        return `${toolName} 执行完成`
    }
    if (Array.isArray(parsedData)) {
        return `共 ${parsedData.length} 条记录`
    }
    const firstLine = text.trim().split('\n')[0] ?? ''
    if (firstLine && firstLine !== '{' && firstLine !== '[') {
        return firstLine.slice(0, 160)
    }
    return `${toolName} 执行完成`
}

export function buildToolReceipt(params: {
    tool: string
    server: string
    ok: boolean
    text: string
    parsedData?: unknown
    durationMs: number
}): ToolReceipt {
    let parsedData = params.parsedData
    if (parsedData === undefined && params.text.trim()) {
        const trimmed = params.text.trim()
        if ((trimmed.startsWith('{') && trimmed.endsWith('}')) || (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
            try {
                parsedData = JSON.parse(trimmed)
            } catch {
                // Plain text output; keep parsedData undefined
            }
        }
    }
    return {
        schemaVersion: 1,
        tool: params.tool,
        server: params.server,
        kind: classifyToolKind(params.tool),
        ok: params.ok,
        summary: summarizeToolResult(params.tool, params.ok, parsedData, params.text),
        ...(parsedData !== undefined ? { data: parsedData } : {}),
        durationMs: params.durationMs
    }
}

export class HttpMcpClient {
    private sessionId: string | null = null
    private cachedTools: CachedTools | null = null
    private nextRpcId = 1

    constructor(private readonly config: McpServerConfig) {}

    get serverName(): string {
        return this.config.name
    }

    private async rpc(method: string, params: Record<string, unknown>, signal?: AbortSignal): Promise<unknown> {
        const headers: Record<string, string> = {
            'Content-Type': 'application/json',
            Accept: 'application/json'
        }
        if (this.config.token) {
            headers.Authorization = `Bearer ${this.config.token}`
        }
        if (this.sessionId) {
            headers['mcp-session-id'] = this.sessionId
        }

        const timeoutSignal = AbortSignal.timeout(MCP_REQUEST_TIMEOUT_MS)
        const combinedSignal = signal ? AbortSignal.any([signal, timeoutSignal]) : timeoutSignal

        const response = await fetch(this.config.url, {
            method: 'POST',
            headers,
            body: JSON.stringify({
                jsonrpc: '2.0',
                id: this.nextRpcId++,
                method,
                params
            }),
            signal: combinedSignal
        })

        const returnedSid = response.headers.get('mcp-session-id')
        if (returnedSid) {
            this.sessionId = returnedSid
        }

        if (!response.ok) {
            const errText = await response.text().catch(() => '')
            throw new Error(`MCP ${this.config.name} HTTP ${response.status}: ${errText.slice(0, 240)}`)
        }

        const payload = (await response.json()) as JsonRpcResponse
        if (payload.error) {
            throw new Error(`MCP ${this.config.name} error (${payload.error.code ?? -1}): ${payload.error.message ?? 'unknown'}`)
        }
        return payload.result
    }

    private async ensureInitialized(signal?: AbortSignal): Promise<void> {
        if (this.sessionId) {
            return
        }
        await this.rpc(
            'initialize',
            {
                protocolVersion: MCP_PROTOCOL_VERSION,
                capabilities: {},
                clientInfo: { name: 'hapi-builtin-agent-loop', version: '0.34.3' }
            },
            signal
        )
    }

    async listTools(signal?: AbortSignal, forceRefresh = false): Promise<McpToolDefinition[]> {
        if (!forceRefresh && this.cachedTools && Date.now() - this.cachedTools.fetchedAt < TOOL_CACHE_TTL_MS) {
            return this.cachedTools.tools
        }
        await this.ensureInitialized(signal)
        const result = (await this.rpc('tools/list', {}, signal)) as {
            tools?: Array<{ name?: string; description?: string; inputSchema?: Record<string, unknown> }>
        } | null
        const rawTools = Array.isArray(result?.tools) ? result.tools : []
        const tools: McpToolDefinition[] = []
        for (const item of rawTools) {
            if (typeof item?.name !== 'string' || !item.name.trim()) continue
            tools.push({
                serverName: this.config.name,
                name: item.name.trim(),
                description: typeof item.description === 'string' ? item.description : '',
                inputSchema: item.inputSchema && typeof item.inputSchema === 'object'
                    ? item.inputSchema
                    : { type: 'object', properties: {} }
            })
        }
        this.cachedTools = { tools, fetchedAt: Date.now() }
        return tools
    }

    async callTool(name: string, args: Record<string, unknown>, signal?: AbortSignal): Promise<McpToolCallResult> {
        const started = Date.now()
        try {
            await this.ensureInitialized(signal)
            const result = (await this.rpc('tools/call', { name, arguments: args }, signal)) as {
                isError?: boolean
                content?: Array<{ type?: string; text?: string; mimeType?: string; data?: string }>
                structuredContent?: unknown
            } | null

            const parts: string[] = []
            if (Array.isArray(result?.content)) {
                for (const block of result.content) {
                    if (block?.type === 'text' && typeof block.text === 'string') {
                        parts.push(block.text)
                    } else if (block?.type === 'image' && typeof block.mimeType === 'string') {
                        parts.push(`[image:${block.mimeType}]`)
                    }
                }
            }
            const text = parts.join('\n') || (result?.structuredContent ? JSON.stringify(result.structuredContent) : '')
            const ok = result?.isError !== true
            return {
                ok,
                text,
                ...(result?.structuredContent !== undefined ? { parsedData: result.structuredContent } : {}),
                durationMs: Date.now() - started
            }
        } catch (error) {
            this.sessionId = null
            return {
                ok: false,
                text: error instanceof Error ? error.message : String(error),
                durationMs: Date.now() - started
            }
        }
    }
}
