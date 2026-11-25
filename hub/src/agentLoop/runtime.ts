import { randomUUID } from 'node:crypto'
import type { Session } from '@hapi/protocol/types'
import { getProviderEnvironment } from '../config/providerCredentials'
import type { Settings } from '../config/settings'
import type { Store } from '../store'
import type { StoredMessage } from '../store/types'
import { runBuiltinAgentTurn } from './loop'
import { HttpMcpClient } from './mcpClient'
import type { BuiltinAgentLoopConfig, BuiltinAgentStreamEvent, BuiltinAttachmentRef, ToolReceipt } from './types'

const BUILTIN_MACHINE_PREFIX = 'builtin:'
const KEEPALIVE_INTERVAL_MS = 25_000
const MAX_VISION_HISTORY_IMAGES = 4
const MAX_VISION_IMAGE_BYTES = 15 * 1024 * 1024

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
    readBuiltinAttachment?(sessionId: string, attachment: BuiltinAttachmentRef): Promise<Buffer | null>
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
    private readonly streamSubscribers = new Map<string, Set<(event: BuiltinAgentStreamEvent) => void>>()
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
        this.streamSubscribers.clear()
    }

    subscribeSessionStream(
        sessionId: string,
        listener: (event: BuiltinAgentStreamEvent) => void
    ): () => void {
        let listeners = this.streamSubscribers.get(sessionId)
        if (!listeners) {
            listeners = new Set()
            this.streamSubscribers.set(sessionId, listeners)
        }
        listeners.add(listener)
        return () => {
            const set = this.streamSubscribers.get(sessionId)
            if (!set) return
            set.delete(listener)
            if (set.size === 0) {
                this.streamSubscribers.delete(sessionId)
            }
        }
    }

    private emitStreamEvent(sessionId: string, event: BuiltinAgentStreamEvent): void {
        const listeners = this.streamSubscribers.get(sessionId)
        if (!listeners || listeners.size === 0) return
        for (const listener of [...listeners]) {
            try {
                listener(event)
            } catch {
                // Keep turn execution isolated from subscriber transport failures
            }
        }
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

    private async resolveRecentVisionImages(
        sessionId: string,
        storedMessages: readonly StoredMessage[]
    ): Promise<Map<string, string>> {
        const resolved = new Map<string, string>()
        if (!this.host.readBuiltinAttachment) {
            return resolved
        }

        const candidates: BuiltinAttachmentRef[] = []
        const recent = storedMessages.slice(-48)
        for (let i = recent.length - 1; i >= 0 && candidates.length < MAX_VISION_HISTORY_IMAGES; i--) {
            const env = recent[i]?.content
            if (!env || typeof env !== 'object' || Array.isArray(env)) continue
            const rec = env as Record<string, unknown>
            if (rec.role !== 'user') continue
            const inner = rec.content
            if (!inner || typeof inner !== 'object' || Array.isArray(inner)) continue
            const attachments = (inner as Record<string, unknown>).attachments
            if (!Array.isArray(attachments)) continue
            for (let j = attachments.length - 1; j >= 0 && candidates.length < MAX_VISION_HISTORY_IMAGES; j--) {
                const raw = attachments[j]
                if (!raw || typeof raw !== 'object' || Array.isArray(raw)) continue
                const att = raw as Record<string, unknown>
                const mimeType = typeof att.mimeType === 'string' ? att.mimeType.trim().toLowerCase() : ''
                if (!mimeType.startsWith('image/')) continue
                const id = typeof att.id === 'string' ? att.id : ''
                const path = typeof att.path === 'string' ? att.path : ''
                if (!id && !path) continue
                candidates.push({
                    id,
                    filename: typeof att.filename === 'string' ? att.filename : 'image',
                    mimeType,
                    size: typeof att.size === 'number' ? att.size : 0,
                    path,
                    previewUrl: typeof att.previewUrl === 'string' ? att.previewUrl : undefined
                })
            }
        }

        await Promise.all(
            candidates.map(async (att) => {
                try {
                    const bytes = await this.host.readBuiltinAttachment?.(sessionId, att)
                    if (!bytes || bytes.length === 0 || bytes.length > MAX_VISION_IMAGE_BYTES) {
                        return
                    }
                    const dataUrl = `data:${att.mimeType};base64,${bytes.toString('base64')}`
                    if (att.id) resolved.set(att.id, dataUrl)
                    if (att.path) resolved.set(att.path, dataUrl)
                } catch (error) {
                    console.warn(
                        `[AgentLoop] Failed to load image attachment ${att.id || att.path} for session ${sessionId}:`,
                        error instanceof Error ? error.message : String(error)
                    )
                }
            })
        )

        return resolved
    }

    private async runTurn(
        sessionId: string,
        state: NamespaceRuntimeState,
        localId: string | null
    ): Promise<void> {
        const controller = new AbortController()
        const turnId = localId || randomUUID()
        let aborted = false
        let turnError: string | undefined
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
            const resolvedImages = await this.resolveRecentVisionImages(sessionId, storedMessages)

            await runBuiltinAgentTurn({
                config: state.config,
                gatewayUrl: url,
                gatewayToken: token,
                model,
                storedMessages,
                resolvedImages,
                mcpClients: state.mcpClients,
                signal: controller.signal,
                callbacks: {
                    onTextDelta: (delta, { round }) => {
                        this.emitStreamEvent(sessionId, {
                            type: 'text_delta',
                            sessionId,
                            turnId,
                            round,
                            delta
                        })
                    },
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
                        this.emitStreamEvent(sessionId, {
                            type: 'tool_use',
                            sessionId,
                            turnId,
                            id,
                            name,
                            input
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
                        this.emitStreamEvent(sessionId, {
                            type: 'tool_result',
                            sessionId,
                            turnId,
                            id,
                            name,
                            content,
                            isError,
                            receipt
                        })
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
                        this.emitStreamEvent(sessionId, {
                            type: 'assistant_message',
                            sessionId,
                            turnId,
                            text
                        })
                    }
                }
            })
        } catch (error) {
            if (controller.signal.aborted) {
                aborted = true
                const abortText = '已停止当前回复。'
                this.host.appendBuiltinAgentMessage(sessionId, {
                    role: 'agent',
                    content: {
                        type: 'output',
                        data: {
                            type: 'assistant',
                            message: {
                                role: 'assistant',
                                content: [{ type: 'text', text: abortText }]
                            }
                        }
                    }
                })
                this.emitStreamEvent(sessionId, {
                    type: 'assistant_message',
                    sessionId,
                    turnId,
                    text: abortText
                })
            } else {
                const msg = error instanceof Error ? error.message : String(error)
                turnError = msg
                const errText = `执行出错：${msg}`
                console.error(`[AgentLoop] Turn failed for session ${sessionId}:`, msg)
                this.host.appendBuiltinAgentMessage(sessionId, {
                    role: 'agent',
                    content: {
                        type: 'output',
                        data: {
                            type: 'assistant',
                            message: {
                                role: 'assistant',
                                content: [{ type: 'text', text: errText }]
                            }
                        }
                    }
                })
                this.emitStreamEvent(sessionId, {
                    type: 'assistant_message',
                    sessionId,
                    turnId,
                    text: errText
                })
            }
        } finally {
            if (this.activeAborts.get(sessionId) === controller) {
                this.activeAborts.delete(sessionId)
            }
            this.emitStreamEvent(sessionId, {
                type: 'turn_done',
                sessionId,
                turnId,
                aborted,
                ...(turnError ? { error: turnError } : {})
            })
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
