export interface McpServerConfig {
    name: string
    url: string
    token?: string
}

export interface BuiltinAgentLoopConfig {
    enabled: boolean
    /** Display name of the virtual built-in machine shown in GET /api/machines. */
    machineName?: string
    /** Optional stable machine ID (defaults to `builtin:<namespace>`). */
    machineId?: string
    /** Default working directory tag for spawned sessions (defaults to `/<namespace>`). */
    defaultDirectory?: string
    /** OpenAI-compatible Model Gateway origin (e.g. http://192.168.5.157:18084). Falls back to HOME_GATEWAY_URL. */
    modelGatewayUrl?: string
    /** Bearer token for Model Gateway. Falls back to HOME_GATEWAY_TOKEN. */
    modelGatewayToken?: string
    /** Default LLM model ID (defaults to `auto`). */
    defaultModel?: string
    /** Optional system prompt prepended to conversations. */
    systemPrompt?: string
    /** Max tool-call rounds per user turn (default: 10). */
    maxToolRounds?: number
    /** Enable built-in `web_search` tool via Model Gateway POST /v1/ai/search (default: true). */
    enableWebSearch?: boolean
    /** Optional Streamable HTTP MCP servers (e.g. MyHome Hub `/mcp`). */
    mcpServers?: McpServerConfig[]
}

export type ToolReceiptKind =
    | 'device_control'
    | 'home_overview'
    | 'entity_list'
    | 'todo'
    | 'schedule'
    | 'memory'
    | 'camera'
    | 'search'
    | 'time'
    | 'generic'

export interface ToolReceipt {
    schemaVersion: 1
    tool: string
    server: string
    kind: ToolReceiptKind
    ok: boolean
    summary: string
    data?: unknown
    durationMs: number
}

export interface McpToolDefinition {
    serverName: string
    name: string
    description: string
    inputSchema: Record<string, unknown>
}
