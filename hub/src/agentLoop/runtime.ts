import { randomUUID } from 'node:crypto'
import type { Session } from '@hapi/protocol/types'
import { getProviderEnvironment } from '../config/providerCredentials'
import type { Settings } from '../config/settings'
import type { Store } from '../store'
import { runBuiltinAgentTurn } from './loop'
import { HttpMcpClient } from './mcpClient'
import type { BuiltinAgentLoopConfig, ToolReceipt } from './types'

const BUILTIN_MACHINE_PREFIX = 'builtin:'
const KEEPALIVE_INTERVAL_MS = 25_000

export interface BuiltinRuntimeHost {
    store: Store
    getSession(sessionId: string): Session | undefined
    getSessionsByNamespace(namespace: string): Session[]
    registerBuiltinMachine(params: {
        machineId: string
        namespace: string
        displayName: string
        defaultDirectory: string
    }): void
    heartbeatBuiltinMachine(machineId: string): void
    createBuiltinSession(params: {
        sessionId: string
        namespace: string
        machineId: string
        host: string
        directory: string
        model?: string
    }): Session
    markBuiltinSessionAlive(sessionId: string, thinking: boolean): void
    markBuiltinSessionReady(sessionId: string): void
    markBuiltinMessagesConsumed(sessionId: string, localIds: string[]): void
    appendBuiltinAgentMessage(sessionId: string, content: unknown): void
    setBuiltinSessionModel(sessionId: string, namespace: string, model: string): void
}

interface NamespaceRuntimeState {
    namespace: string
    machineId: string
    displayName: string
    defaultDirectory: string
    config: BuiltinAgentLoopConfig
    mcpClients: HttpMcpClient[]
}

export class BuiltinAgentLoopRuntime {
    private readonly namespaces = new Map<string, NamespaceRuntimeState>()
    private readonly machineToNamespace = new Map<string, string>()
    private readonly activeAborts = new Map<string, AbortController>()
    private readonly turnChains = new Map<string, Promise<void>>()
    private keepaliveTimer: ReturnType<typeof setInterval> | null = null

    constructor(
        private readonly host: BuiltinRuntimeHost,
        settings: Settings
    ) {
        this.loadFromSettings(settings)
    }

    private loadFromSettings(settings: Settings): void {
        const nsEntries = Object.entries(settings.namespaces ?? {})
        for (const [namespace, nsCfg] of nsEntries) {
            const loopCfg = nsCfg?.agentLoop
            if (!loopCfg?.enabled) continue

            const machineId = loopCfg.machineId?.trim() || `${BUILTIN_MACHINE_PREFIX}${namespace}`
            const displayName = loopCfg.machineName?.trim() || `HAPI 内置引擎 (${namespace})`
            const defaultDirectory = loopCfg.defaultDirectory?.trim() || `/${namespace}`
            const mcpClients = (loopCfg.mcpServers ?? [])
                .filter((srv) => srv && typeof srv.url === 'string' && srv.url.trim())
                .map((srv) => new HttpMcpClient({
                    name: srv.name?.trim() || 'mcp',
                    url: srv.url.trim(),
                    token: srv.token?.trim() || undefined
                }))

            this.namespaces.set(namespace, {
                namespace,
                machineId,
                displayName,
                defaultDirectory,
                config: loopCfg,
                mcpClients
            })
            this.machineToNamespace.set(machineId, namespace)
        }
    }

    start(): void {
        if (this.namespaces.size === 0) {
            return
        }
        for (const state of this.namespaces.values()) {
            this.host.registerBuiltinMachine({
                machineId: state.machineId,
                namespace: state.namespace,
                displayName: state.displayName,
                defaultDirectory: state.defaultDirectory
            })
            // Re-activate persisted built-in sessions after a Hub restart so
            // existing conversations stay immediately resumable without respawn.
            for (const session of this.host.getSessionsByNamespace(state.namespace)) {
                if (session.metadata?.machineId === state.machineId && session.metadata?.archivedBy === undefined) {
                    this.host.markBuiltinSessionAlive(session.id, false)
                }
            }
            console.log(
                `[AgentLoop] Built-in runtime active for namespace "${state.namespace}" ` +
                `(machine=${state.machineId}, mcpServers=${state.mcpClients.length})`
            )
        }

        if (!this.keepaliveTimer) {
            this.keepaliveTimer = setInterval(() => {
                for (const state of this.namespaces.values()) {
                    this.host.heartbeatBuiltinMachine(state.machineId)
                }
            }, KEEPALIVE_INTERVAL_MS)
            this.keepaliveTimer.unref?.()
        }
    }

    stop(): void {
        if (this.keepaliveTimer) {
            clearInterval(this.keepaliveTimer)
            this.keepaliveTimer = null
        }
        for (const controller of this.activeAborts.values()) {
            controller.abort()
        }
        this.activeAborts.clear()
    }

    ownsMachine(machineId: string, namespace?: string): boolean {
        const ownerNs = this.machineToNamespace.get(machineId)
        if (!ownerNs) return false
        return namespace === undefined || ownerNs === namespace
    }

    ownsSession(session: Session | undefined): boolean {
        if (!session) return false
        const machineId = session.metadata?.machineId
        if (!machineId) return false
        return this.ownsMachine(machineId, session.namespace)
    }

    spawnSession(params: {
        machineId: string
        namespace: string
        directory?: string
        model?: string
        existingSessionId?: string
    }): { type: 'success'; sessionId: string } | { type: 'error'; message: string } {
        const ownerNs = this.machineToNamespace.get(params.machineId)
        if (!ownerNs || ownerNs !== params.namespace) {
            return { type: 'error', message: `Machine ${params.machineId} not available for namespace ${params.namespace}` }
        }
        const state = this.namespaces.get(ownerNs)
        if (!state) {
            return { type: 'error', message: `Built-in runtime not configured for namespace ${params.namespace}` }
        }

        const sessionId = params.existingSessionId || randomUUID()
        const directory = params.directory?.trim() || state.defaultDirectory
        const model = params.model?.trim() || state.config.defaultModel?.trim() || 'auto'

        this.host.createBuiltinSession({
            sessionId,
            namespace: state.namespace,
            machineId: state.machineId,
            host: state.displayName,
            directory,
            model
        })
        this.host.markBuiltinSessionAlive(sessionId, false)

        return { type: 'success', sessionId }
    }

    setModel(session: Session, model: string): boolean {
        if (!this.ownsSession(session)) return false
        const trimmed = model.trim()
        if (!trimmed) return false
        this.host.setBuiltinSessionModel(session.id, session.namespace, trimmed)
        return true
    }

    abortSession(sessionId: string): boolean {
        const controller = this.activeAborts.get(sessionId)
        if (controller) {
            controller.abort()
            this.activeAborts.delete(sessionId)
            this.host.markBuiltinSessionAlive(sessionId, false)
            return true
        }
        const session = this.host.getSession(sessionId)
        if (this.ownsSession(session)) {
            this.host.markBuiltinSessionAlive(sessionId, false)
            return true
        }
        return false
    }

    enqueueUserMessage(sessionId: string, localId?: string | null): boolean {
        const session = this.host.getSession(sessionId)
        if (!this.ownsSession(session) || !session) {
            return false
        }
        const state = this.namespaces.get(session.namespace)
        if (!state) {
            return false
        }

        const previous = this.turnChains.get(sessionId) ?? Promise.resolve()
        const next = previous
            .catch(() => undefined)
            .then(() => this.runTurn(sessionId, state, localId ?? null))
        this.turnChains.set(sessionId, next)
        void next.finally(() => {
            if (this.turnChains.get(sessionId) === next) {
                this.turnChains.delete(sessionId)
            }
        })
        return true
    }

    private resolveGateway(config: BuiltinAgentLoopConfig): { url: string; token?: string } {
        const env = getProviderEnvironment()
        const url = config.modelGatewayUrl?.trim() || env.HOME_GATEWAY_URL?.trim() || ''
        const token = config.modelGatewayToken?.trim() || env.HOME_GATEWAY_TOKEN?.trim() || undefined
        if (!url) {
            throw new Error('Model Gateway URL is not configured (set agentLoop.modelGatewayUrl or HOME_GATEWAY_URL)')
        }
        return { url, token }
    }

    private async runTurn(
        sessionId: string,
        state: NamespaceRuntimeState,
        localId: string | null
    ): Promise<void> {
        const controller = new AbortController()
        this.activeAborts.set(sessionId, controller)

        if (localId) {
            this.host.markBuiltinMessagesConsumed(sessionId, [localId])
        }
        this.host.markBuiltinSessionAlive(sessionId, true)

        try {
            const { url, token } = this.resolveGateway(state.config)
            const currentSession = this.host.getSession(sessionId)
            const model = currentSession?.model?.trim() || state.config.defaultModel?.trim() || 'auto'
            const storedMessages = this.host.store.messages.getAllMessages(sessionId)

            await runBuiltinAgentTurn({
                config: state.config,
                gatewayUrl: url,
                gatewayToken: token,
                model,
                storedMessages,
                mcpClients: state.mcpClients,
                signal: controller.signal,
                callbacks: {
                    onToolUse: ({ id, name, input }) => {
                        this.host.appendBuiltinAgentMessage(sessionId, {
                            role: 'agent',
                            content: {
                                type: 'output',
                                data: {
                                    type: 'assistant',
                                    message: {
                                        role: 'assistant',
                                        content: [{ type: 'tool_use', id, name, input }]
                                    }
                                }
                            }
                        })
                    },
                    onToolResult: ({ id, name, content, isError, receipt }) => {
                        this.host.appendBuiltinAgentMessage(sessionId, buildToolResultEnvelope({
                            id,
                            name,
                            content,
                            isError,
                            receipt
                        }))
                    },
                    onAssistantText: (text) => {
                        this.host.appendBuiltinAgentMessage(sessionId, {
                            role: 'agent',
                            content: {
                                type: 'output',
                                data: {
                                    type: 'assistant',
                                    message: {
                                        role: 'assistant',
                                        content: [{ type: 'text', text }]
                                    }
                                }
                            }
                        })
                    }
                }
            })
        } catch (error) {
            if (controller.signal.aborted) {
                this.host.appendBuiltinAgentMessage(sessionId, {
                    role: 'agent',
                    content: {
                        type: 'output',
                        data: {
                            type: 'assistant',
                            message: {
                                role: 'assistant',
                                content: [{ type: 'text', text: '已停止当前回复。' }]
                            }
                        }
                    }
                })
            } else {
                const msg = error instanceof Error ? error.message : String(error)
                console.error(`[AgentLoop] Turn failed for session ${sessionId}:`, msg)
                this.host.appendBuiltinAgentMessage(sessionId, {
                    role: 'agent',
                    content: {
                        type: 'output',
                        data: {
                            type: 'assistant',
                            message: {
                                role: 'assistant',
                                content: [{ type: 'text', text: `执行出错：${msg}` }]
                            }
                        }
                    }
                })
            }
        } finally {
            if (this.activeAborts.get(sessionId) === controller) {
                this.activeAborts.delete(sessionId)
            }
            this.host.markBuiltinSessionAlive(sessionId, false)
            this.host.markBuiltinSessionReady(sessionId)
        }
    }
}

function buildToolResultEnvelope(params: {
    id: string
    name: string
    content: string
    isError: boolean
    receipt: ToolReceipt
}): Record<string, unknown> {
    return {
        role: 'agent',
        content: {
            type: 'output',
            data: {
                type: 'user',
                message: {
                    role: 'user',
                    content: [
                        {
                            type: 'tool_result',
                            tool_use_id: params.id,
                            content: params.content,
                            is_error: params.isError,
                            tool_receipt: params.receipt
                        }
                    ]
                }
            }
        },
        meta: {
            toolReceipt: params.receipt,
            toolName: params.name
        }
    }
}
