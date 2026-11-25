import { randomUUID } from 'node:crypto'
import type { StoredMessage } from '../store/types'
import { buildToolReceipt, type HttpMcpClient } from './mcpClient'
import type { BuiltinAgentLoopConfig, McpToolDefinition, ToolReceipt } from './types'

const DEFAULT_MAX_TOOL_ROUNDS = 10
const MAX_HISTORY_MESSAGES = 48
const LLM_REQUEST_TIMEOUT_MS = 95_000
const SEARCH_REQUEST_TIMEOUT_MS = 25_000

const DEFAULT_SYSTEM_PROMPT = [
    '你是运行在家庭 24/7 HAPI 控制面上的智能助手。',
    '回答简洁、准确、自然；涉及家庭设备状态、控制、待办、日程、记忆或实时联网信息时，优先调用工具核实，不要猜测。',
    '所有时间默认使用北京时间（Asia/Shanghai）。'
].join('\n')

type OpenAiUserContentPart =
    | { type: 'text'; text: string }
    | { type: 'image_url'; image_url: { url: string } }

type OpenAiChatMessage =
    | { role: 'system'; content: string }
    | { role: 'user'; content: string | OpenAiUserContentPart[] }
    | {
        role: 'assistant'
        content: string | null
        tool_calls?: Array<{
            id: string
            type: 'function'
            function: { name: string; arguments: string }
        }>
    }
    | { role: 'tool'; tool_call_id: string; content: string }

interface OpenAiToolSchema {
    type: 'function'
    function: {
        name: string
        description: string
        parameters: Record<string, unknown>
    }
}

interface OpenAiToolCallPayload {
    index?: number
    id?: string
    type?: string
    function?: { name?: string; arguments?: string }
}

interface OpenAiCompletionResponse {
    choices?: Array<{
        finish_reason?: string | null
        message?: {
            role?: string
            content?: string | Array<{ type?: string; text?: string }> | null
            tool_calls?: OpenAiToolCallPayload[]
        }
        delta?: {
            role?: string
            content?: string | Array<{ type?: string; text?: string }> | null
            tool_calls?: OpenAiToolCallPayload[]
        }
    }>
    error?: { message?: string } | string
}

export interface AgentLoopCallbacks {
    onTextDelta?: (delta: string, meta: { round: number }) => void
    onToolUse: (event: { id: string; name: string; input: Record<string, unknown> }) => void
    onToolResult: (event: { id: string; name: string; content: string; isError: boolean; receipt: ToolReceipt }) => void
    onAssistantText: (text: string) => void
}

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function extractMessageText(content: unknown): string {
    if (typeof content === 'string') return content
    if (Array.isArray(content)) {
        return content
            .map((part) => (isObject(part) && part.type === 'text' && typeof part.text === 'string' ? part.text : ''))
            .filter(Boolean)
            .join('')
    }
    return ''
}

interface ConsumedCompletion {
    text: string
    toolCalls: Array<{
        id?: string
        function?: { name?: string; arguments?: string }
    }>
    streamedAnyText: boolean
}

function applyChunkPayload(
    data: OpenAiCompletionResponse,
    state: {
        text: string
        streamedAnyText: boolean
        toolCallsByIndex: Map<number, { id: string; name: string; arguments: string }>
        nextToolIndex: number
    },
    onTextDelta?: (delta: string) => void
): void {
    if (data.error) {
        const msg = typeof data.error === 'string' ? data.error : data.error.message || 'Model Gateway error'
        throw new Error(msg)
    }
    const choice = data.choices?.[0]
    if (!choice) return

    const delta = choice.delta
    if (delta) {
        const deltaText = extractMessageText(delta.content)
        if (deltaText) {
            state.text += deltaText
            state.streamedAnyText = true
            onTextDelta?.(deltaText)
        }
        if (Array.isArray(delta.tool_calls)) {
            for (const tc of delta.tool_calls) {
                const idx = typeof tc.index === 'number' && Number.isInteger(tc.index) && tc.index >= 0
                    ? tc.index
                    : state.nextToolIndex++
                let entry = state.toolCallsByIndex.get(idx)
                if (!entry) {
                    entry = { id: '', name: '', arguments: '' }
                    state.toolCallsByIndex.set(idx, entry)
                }
                if (typeof tc.id === 'string' && tc.id.trim()) {
                    entry.id = tc.id.trim()
                }
                if (typeof tc.function?.name === 'string' && tc.function.name) {
                    entry.name += tc.function.name
                }
                if (typeof tc.function?.arguments === 'string' && tc.function.arguments) {
                    entry.arguments += tc.function.arguments
                }
            }
        }
        return
    }

    // Defensive fallback if an SSE chunk carries a full message object
    const message = choice.message
    if (message) {
        const msgText = extractMessageText(message.content)
        if (msgText && !state.text) {
            state.text = msgText
            state.streamedAnyText = true
            onTextDelta?.(msgText)
        }
        if (Array.isArray(message.tool_calls) && state.toolCallsByIndex.size === 0) {
            message.tool_calls.forEach((tc, i) => {
                state.toolCallsByIndex.set(i, {
                    id: typeof tc.id === 'string' ? tc.id.trim() : '',
                    name: typeof tc.function?.name === 'string' ? tc.function.name : '',
                    arguments: typeof tc.function?.arguments === 'string' ? tc.function.arguments : ''
                })
            })
        }
    }
}

async function consumeChatCompletionResponse(
    response: Response,
    onTextDelta?: (delta: string) => void
): Promise<ConsumedCompletion> {
    const contentType = (response.headers.get('content-type') || '').toLowerCase()
    if (!contentType.includes('text/event-stream') || !response.body) {
        const data = (await response.json()) as OpenAiCompletionResponse
        if (data.error) {
            const msg = typeof data.error === 'string' ? data.error : data.error.message || 'Model Gateway error'
            throw new Error(msg)
        }
        const choice = data.choices?.[0]
        const assistantMsg = choice?.message
        const text = extractMessageText(assistantMsg?.content)
        const rawToolCalls = Array.isArray(assistantMsg?.tool_calls) ? assistantMsg.tool_calls : []
        let streamedAnyText = false
        if (text && rawToolCalls.length === 0) {
            onTextDelta?.(text)
            streamedAnyText = true
        }
        return { text, toolCalls: rawToolCalls, streamedAnyText }
    }

    const state = {
        text: '',
        streamedAnyText: false,
        toolCallsByIndex: new Map<number, { id: string; name: string; arguments: string }>(),
        nextToolIndex: 0
    }

    const reader = response.body.getReader()
    const decoder = new TextDecoder('utf-8')
    let buffer = ''
    let done = false

    const processLine = (rawLine: string): boolean => {
        const line = rawLine.endsWith('\r') ? rawLine.slice(0, -1) : rawLine
        if (!line || line.startsWith(':')) return false
        if (!line.startsWith('data:')) return false
        const payload = line.slice(5).trim()
        if (!payload) return false
        if (payload === '[DONE]') return true
        let parsed: OpenAiCompletionResponse
        try {
            parsed = JSON.parse(payload) as OpenAiCompletionResponse
        } catch {
            return false
        }
        applyChunkPayload(parsed, state, onTextDelta)
        return false
    }

    try {
        while (!done) {
            const { value, done: streamDone } = await reader.read()
            if (streamDone) {
                buffer += decoder.decode()
                break
            }
            buffer += decoder.decode(value, { stream: true })
            let newlineIdx = buffer.indexOf('\n')
            while (newlineIdx !== -1) {
                const line = buffer.slice(0, newlineIdx)
                buffer = buffer.slice(newlineIdx + 1)
                if (processLine(line)) {
                    done = true
                    break
                }
                newlineIdx = buffer.indexOf('\n')
            }
        }
        if (!done && buffer.trim()) {
            processLine(buffer)
        }
    } finally {
        reader.releaseLock()
    }

    const toolCalls = [...state.toolCallsByIndex.entries()]
        .sort((a, b) => a[0] - b[0])
        .map(([, tc]) => ({
            id: tc.id || undefined,
            function: {
                name: tc.name,
                arguments: tc.arguments || '{}'
            }
        }))
        .filter((tc) => Boolean(tc.function.name.trim()))

    return {
        text: state.text,
        toolCalls,
        streamedAnyText: state.streamedAnyText
    }
}

/**
 * Reconstruct clean OpenAI-compatible chat history from HAPI's canonical stored rows.
 * Only user prompts (plus resolved image attachments) and assistant text / tool exchanges
 * are projected; internal system events are ignored so history stays compact and provider-portable.
 */
export function buildChatHistoryFromStoredMessages(
    stored: readonly StoredMessage[],
    systemPrompt: string,
    resolvedImages?: ReadonlyMap<string, string>
): OpenAiChatMessage[] {
    const messages: OpenAiChatMessage[] = [{ role: 'system', content: systemPrompt }]
    const slice = stored.slice(-MAX_HISTORY_MESSAGES)

    for (const row of slice) {
        const env = row.content
        if (!isObject(env)) continue

        if (env.role === 'user' && isObject(env.content) && env.content.type === 'text') {
            const text = typeof env.content.text === 'string' ? env.content.text.trim() : ''
            const rawAttachments = Array.isArray(env.content.attachments) ? env.content.attachments : []
            const imageParts: OpenAiUserContentPart[] = []
            const fallbackNotes: string[] = []

            for (const att of rawAttachments) {
                if (!isObject(att)) continue
                const mimeType = typeof att.mimeType === 'string' ? att.mimeType.toLowerCase() : ''
                if (!mimeType.startsWith('image/')) continue
                const attId = typeof att.id === 'string' ? att.id : ''
                const attPath = typeof att.path === 'string' ? att.path : ''
                const filename = typeof att.filename === 'string' && att.filename.trim() ? att.filename.trim() : 'image'
                const dataUrl = (attId ? resolvedImages?.get(attId) : undefined)
                    ?? (attPath ? resolvedImages?.get(attPath) : undefined)
                if (dataUrl) {
                    imageParts.push({ type: 'image_url', image_url: { url: dataUrl } })
                } else {
                    fallbackNotes.push(`[历史图片附件: ${filename}]`)
                }
            }

            const combinedText = [text, ...fallbackNotes].filter(Boolean).join('\n').trim()
            if (imageParts.length > 0) {
                messages.push({
                    role: 'user',
                    content: [
                        { type: 'text', text: combinedText || '请帮我看看这张图' },
                        ...imageParts
                    ]
                })
            } else if (combinedText) {
                messages.push({ role: 'user', content: combinedText })
            }
            continue
        }

        if (env.role !== 'agent' || !isObject(env.content) || env.content.type !== 'output') {
            continue
        }
        const data = env.content.data
        if (!isObject(data)) continue
        const innerMsg = isObject(data.message) ? data.message : null
        const blocks = Array.isArray(innerMsg?.content) ? innerMsg.content : []

        if (data.type === 'assistant') {
            const textParts: string[] = []
            const toolCalls: Array<{ id: string; type: 'function'; function: { name: string; arguments: string } }> = []
            for (const block of blocks) {
                if (!isObject(block)) continue
                if (block.type === 'text' && typeof block.text === 'string' && block.text.trim()) {
                    textParts.push(block.text)
                } else if (block.type === 'tool_use' && typeof block.name === 'string') {
                    toolCalls.push({
                        id: typeof block.id === 'string' && block.id ? block.id : randomUUID(),
                        type: 'function',
                        function: {
                            name: block.name,
                            arguments: JSON.stringify(isObject(block.input) ? block.input : {})
                        }
                    })
                }
            }
            if (toolCalls.length > 0) {
                messages.push({
                    role: 'assistant',
                    content: textParts.length > 0 ? textParts.join('\n') : null,
                    tool_calls: toolCalls
                })
            } else if (textParts.length > 0) {
                messages.push({ role: 'assistant', content: textParts.join('\n') })
            }
            continue
        }

        if (data.type === 'user') {
            for (const block of blocks) {
                if (!isObject(block) || block.type !== 'tool_result') continue
                const callId = typeof block.tool_use_id === 'string' ? block.tool_use_id : ''
                if (!callId) continue
                const text = typeof block.content === 'string'
                    ? block.content
                    : JSON.stringify(block.content ?? '')
                messages.push({
                    role: 'tool',
                    tool_call_id: callId,
                    content: text.slice(0, 12_000)
                })
            }
        }
    }

    // Ensure history never starts an orphaned tool message without a preceding assistant tool_call
    const sanitized: OpenAiChatMessage[] = [messages[0]]
    const seenToolCallIds = new Set<string>()
    for (let i = 1; i < messages.length; i++) {
        const msg = messages[i]
        if (msg.role === 'assistant' && msg.tool_calls) {
            for (const tc of msg.tool_calls) {
                seenToolCallIds.add(tc.id)
            }
            sanitized.push(msg)
        } else if (msg.role === 'tool') {
            if (seenToolCallIds.has(msg.tool_call_id)) {
                sanitized.push(msg)
            }
        } else {
            sanitized.push(msg)
        }
    }
    return sanitized
}

function buildBuiltinToolSchemas(enableWebSearch: boolean): OpenAiToolSchema[] {
    const tools: OpenAiToolSchema[] = [
        {
            type: 'function',
            function: {
                name: 'get_current_time',
                description: '获取当前准确日期、星期与北京时间（Asia/Shanghai）。',
                parameters: { type: 'object', properties: {}, additionalProperties: false }
            }
        }
    ]
    if (enableWebSearch) {
        tools.push({
            type: 'function',
            function: {
                name: 'web_search',
                description: '联网检索实时资讯、天气、百科或外部网页摘要。',
                parameters: {
                    type: 'object',
                    properties: {
                        query: { type: 'string', description: '检索关键词' },
                        limit: { type: 'integer', description: '返回条数（1-10，默认 5）' }
                    },
                    required: ['query']
                }
            }
        })
    }
    return tools
}

function formatChinaTime(): { iso: string; local: string; timezone: string; weekday: string } {
    const now = new Date()
    const fmt = new Intl.DateTimeFormat('zh-CN', {
        timeZone: 'Asia/Shanghai',
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit',
        hour12: false
    })
    const weekday = new Intl.DateTimeFormat('zh-CN', {
        timeZone: 'Asia/Shanghai',
        weekday: 'long'
    }).format(now)
    return {
        iso: now.toISOString(),
        local: fmt.format(now),
        timezone: 'Asia/Shanghai',
        weekday
    }
}

async function executeWebSearch(
    gatewayUrl: string,
    gatewayToken: string | undefined,
    args: Record<string, unknown>,
    signal?: AbortSignal
): Promise<{ ok: boolean; text: string; parsedData?: unknown; durationMs: number }> {
    const started = Date.now()
    const query = typeof args.query === 'string' ? args.query.trim() : ''
    if (!query) {
        return { ok: false, text: 'Missing query parameter', durationMs: Date.now() - started }
    }
    const rawLimit = typeof args.limit === 'number' ? Math.floor(args.limit) : 5
    const limit = Math.max(1, Math.min(10, Number.isFinite(rawLimit) ? rawLimit : 5))
    try {
        const headers: Record<string, string> = { 'Content-Type': 'application/json' }
        if (gatewayToken) {
            headers.Authorization = `Bearer ${gatewayToken}`
        }
        const timeoutSignal = AbortSignal.timeout(SEARCH_REQUEST_TIMEOUT_MS)
        const combinedSignal = signal ? AbortSignal.any([signal, timeoutSignal]) : timeoutSignal
        const resp = await fetch(`${gatewayUrl.replace(/\/+$/, '')}/v1/ai/search`, {
            method: 'POST',
            headers,
            body: JSON.stringify({ query, limit }),
            signal: combinedSignal
        })
        if (!resp.ok) {
            const errText = await resp.text().catch(() => '')
            return {
                ok: false,
                text: `web_search HTTP ${resp.status}: ${errText.slice(0, 240)}`,
                durationMs: Date.now() - started
            }
        }
        const data = (await resp.json()) as Record<string, unknown>
        return {
            ok: true,
            text: JSON.stringify(data),
            parsedData: data,
            durationMs: Date.now() - started
        }
    } catch (error) {
        return {
            ok: false,
            text: error instanceof Error ? error.message : String(error),
            durationMs: Date.now() - started
        }
    }
}

function safeParseToolArguments(raw: string | undefined): Record<string, unknown> {
    if (!raw || !raw.trim()) return {}
    try {
        const parsed = JSON.parse(raw)
        return isObject(parsed) ? parsed : { value: parsed }
    } catch {
        return { raw }
    }
}

export async function runBuiltinAgentTurn(options: {
    config: BuiltinAgentLoopConfig
    gatewayUrl: string
    gatewayToken?: string
    model: string
    storedMessages: readonly StoredMessage[]
    resolvedImages?: ReadonlyMap<string, string>
    mcpClients: readonly HttpMcpClient[]
    callbacks: AgentLoopCallbacks
    signal?: AbortSignal
}): Promise<{ finalText: string; toolCallsExecuted: number }> {
    const { config, gatewayUrl, gatewayToken, model, storedMessages, resolvedImages, mcpClients, callbacks, signal } = options
    const systemPrompt = config.systemPrompt?.trim() || DEFAULT_SYSTEM_PROMPT
    const maxRounds = Math.max(1, Math.min(20, config.maxToolRounds ?? DEFAULT_MAX_TOOL_ROUNDS))
    const enableWebSearch = config.enableWebSearch !== false

    // Discover MCP tools across configured servers (best-effort per server so one offline server does not block chat)
    const mcpToolMap = new Map<string, { client: HttpMcpClient; def: McpToolDefinition }>()
    const allToolSchemas: OpenAiToolSchema[] = [...buildBuiltinToolSchemas(enableWebSearch)]

    await Promise.all(
        mcpClients.map(async (client) => {
            try {
                const defs = await client.listTools(signal)
                for (const def of defs) {
                    if (mcpToolMap.has(def.name)) continue
                    mcpToolMap.set(def.name, { client, def })
                    allToolSchemas.push({
                        type: 'function',
                        function: {
                            name: def.name,
                            description: def.description,
                            parameters: def.inputSchema
                        }
                    })
                }
            } catch (error) {
                console.warn(`[AgentLoop] MCP server "${client.serverName}" tool discovery failed:`, error instanceof Error ? error.message : String(error))
            }
        })
    )

    const chatMessages = buildChatHistoryFromStoredMessages(storedMessages, systemPrompt, resolvedImages)
    const completionsUrl = `${gatewayUrl.replace(/\/+$/, '')}/v1/ai/chat/completions`
    let toolCallsExecuted = 0

    for (let round = 0; round < maxRounds; round++) {
        if (signal?.aborted) {
            throw new DOMException('Turn aborted', 'AbortError')
        }

        const headers: Record<string, string> = {
            'Content-Type': 'application/json',
            Accept: 'text/event-stream, application/json'
        }
        if (gatewayToken) {
            headers.Authorization = `Bearer ${gatewayToken}`
        }

        const reqBody: Record<string, unknown> = {
            model,
            messages: chatMessages,
            stream: true
        }
        if (allToolSchemas.length > 0) {
            reqBody.tools = allToolSchemas
            reqBody.tool_choice = 'auto'
        }

        const timeoutSignal = AbortSignal.timeout(LLM_REQUEST_TIMEOUT_MS)
        const combinedSignal = signal ? AbortSignal.any([signal, timeoutSignal]) : timeoutSignal

        const response = await fetch(completionsUrl, {
            method: 'POST',
            headers,
            body: JSON.stringify(reqBody),
            signal: combinedSignal
        })

        if (!response.ok) {
            const errText = await response.text().catch(() => '')
            throw new Error(`Model Gateway HTTP ${response.status}: ${errText.slice(0, 300)}`)
        }

        const consumed = await consumeChatCompletionResponse(response, (delta) => {
            callbacks.onTextDelta?.(delta, { round })
        })
        const text = consumed.text.trim()
        const rawToolCalls = consumed.toolCalls

        if (rawToolCalls.length === 0) {
            const finalText = text || '已完成处理。'
            if (!consumed.streamedAnyText) {
                callbacks.onTextDelta?.(finalText, { round })
            }
            callbacks.onAssistantText(finalText)
            return { finalText, toolCallsExecuted }
        }

        // Normalize tool calls and append assistant turn to in-memory chatMessages
        const normalizedCalls = rawToolCalls.map((tc) => ({
            id: typeof tc.id === 'string' && tc.id.trim() ? tc.id.trim() : `call_${randomUUID().slice(0, 12)}`,
            type: 'function' as const,
            function: {
                name: tc.function?.name?.trim() || 'unknown_tool',
                arguments: typeof tc.function?.arguments === 'string' ? tc.function.arguments : '{}'
            }
        }))

        chatMessages.push({
            role: 'assistant',
            content: text || null,
            tool_calls: normalizedCalls
        })

        // Execute each requested tool call sequentially to preserve deterministic ordering
        for (const call of normalizedCalls) {
            if (signal?.aborted) {
                throw new DOMException('Turn aborted', 'AbortError')
            }
            const toolName = call.function.name
            const input = safeParseToolArguments(call.function.arguments)
            callbacks.onToolUse({ id: call.id, name: toolName, input })

            let result: { ok: boolean; text: string; parsedData?: unknown; durationMs: number }
            let serverName = 'builtin'

            if (toolName === 'get_current_time') {
                const started = Date.now()
                const nowInfo = formatChinaTime()
                result = {
                    ok: true,
                    text: JSON.stringify(nowInfo),
                    parsedData: nowInfo,
                    durationMs: Date.now() - started
                }
            } else if (toolName === 'web_search' && enableWebSearch) {
                result = await executeWebSearch(gatewayUrl, gatewayToken, input, signal)
            } else {
                const mcpEntry = mcpToolMap.get(toolName)
                if (!mcpEntry) {
                    result = { ok: false, text: `Unknown tool: ${toolName}`, durationMs: 0 }
                } else {
                    serverName = mcpEntry.def.serverName
                    result = await mcpEntry.client.callTool(toolName, input, signal)
                }
            }

            toolCallsExecuted += 1
            const receipt = buildToolReceipt({
                tool: toolName,
                server: serverName,
                ok: result.ok,
                text: result.text,
                parsedData: result.parsedData,
                durationMs: result.durationMs
            })

            callbacks.onToolResult({
                id: call.id,
                name: toolName,
                content: result.text,
                isError: !result.ok,
                receipt
            })

            chatMessages.push({
                role: 'tool',
                tool_call_id: call.id,
                content: result.text.slice(0, 12_000)
            })
        }
    }

    const fallback = '本次工具调用已达单轮步数上限，请告诉我是否继续。'
    callbacks.onAssistantText(fallback)
    return { finalText: fallback, toolCallsExecuted }
}
