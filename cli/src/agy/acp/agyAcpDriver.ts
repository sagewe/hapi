import React from 'react';
import { randomUUID } from 'node:crypto';
import { RPC_METHODS } from '@hapi/protocol/rpcMethods';
import { RemoteLauncherBase, type RemoteLauncherDisplayContext } from '@/modules/common/remote/RemoteLauncherBase';
import { RemoteModeDisplay } from '@/ui/ink/RemoteModeDisplay';
import { AcpSdkBackend } from '@/agent/backends/acp';
import { isAcpIndeterminateError } from '@/agent/backends/acp/AcpStdioTransport';
import { PermissionAdapter } from '@/agent/permissionAdapter';
import { registerAcpSessionTitleSync } from '@/agent/acpSessionTitle';
import { convertAgentMessage } from '@/agent/messageConverter';
import { hashObject } from '@/utils/deterministicJson';
import { logger } from '@/ui/logger';
import type { AgentMessage } from '@/agent/types';
import type { AgySession } from '../session';
import type { AgyMode } from '../types';
import { createAgyAcpBackend, configureAgyAcpSession } from './agyAcpBackend';
import { AgyElicitationAdapter } from './agyElicitationAdapter';
import { AgyReactiveContinuationPendingError, AgyReactiveWakeupTracker, type AgyReactiveWakeupOptions } from './agyReactiveWakeup';

/** One handler owns all notifications, including concurrent prompts. A turn is
 * not ready until every steer settles; no automatic retry of ambiguous sends. */
export class AgyAcpDriver extends RemoteLauncherBase {
    private backend: AcpSdkBackend | null = null;
    private permission: PermissionAdapter | null = null;
    private elicitation: AgyElicitationAdapter | null = null;
    private readonly loopAbort = new AbortController();
    private readonly pendingSteers = new Set<Promise<void>>();
    private readonly reactiveWakeup: AgyReactiveWakeupTracker;
    private lastMode: AgyMode = { permissionMode: 'request-review', model: null, effort: null };
    private activeModeHash: string | null = null;
    private backendModeHash: string | null = null;
    private activeTurn: Promise<void> | null = null;
    private aborting: Promise<void> | null = null;
    private generation = 0;
    private stopping = false;
    private backgroundTasksSignature = '[]';

    constructor(
        private readonly session: AgySession,
        private readonly createBackend = createAgyAcpBackend,
        reactiveOptions?: AgyReactiveWakeupOptions
    ) {
        super(process.env.DEBUG ? session.logPath : undefined);
        this.reactiveWakeup = new AgyReactiveWakeupTracker(reactiveOptions);
        session.setKillHandler(() => this.stop());
        session.steerQueuedMessage = (localId) => this.steer({ localId });
    }

    protected createDisplay(context: RemoteLauncherDisplayContext): React.ReactElement {
        return React.createElement(RemoteModeDisplay, context);
    }

    public launch(): Promise<'switch' | 'exit'> {
        return this.start({ onExit: () => this.stop() });
    }

    private steering(active: boolean): void {
        this.session.client.updateAgentState((state) => ({ ...state, steeringActive: active }));
    }

    private publishBackgroundTasks(): void {
        const tasks = this.reactiveWakeup.getBackgroundTasks().map((task) => ({
            task_id: task.id, task_type: task.type, description: task.description
        }));
        const signature = JSON.stringify(tasks);
        if (signature === this.backgroundTasksSignature) return;
        this.backgroundTasksSignature = signature;
        // Reuse the existing output-envelope snapshot contract understood by
        // Hub and all clients; agentState has no background-task projection.
        this.session.client.sendClaudeSessionMessage({ uuid: randomUUID(), type: 'system', subtype: 'background_tasks_changed', tasks });
    }

    private async closeBackend(): Promise<void> {
        const backend = this.backend;
        this.backend = null;
        this.backendModeHash = null;
        this.reactiveWakeup.reset();
        this.publishBackgroundTasks();
        const elicitation = this.elicitation;
        this.elicitation = null;
        const permission = this.permission;
        this.permission = null;
        try {
            await elicitation?.cancelAll('Antigravity session closed');
            await permission?.cancelAll('Antigravity session closed');
        } catch (error) {
            logger.debug('[agy-acp] permission cancellation failed during teardown', error);
        } finally {
            await backend?.disconnect();
        }
    }

    private async ensureBackend(mode: AgyMode): Promise<AcpSdkBackend> {
        const modeHash = hashObject(mode);
        if (this.backend && this.backendModeHash === modeHash) return this.backend;
        await this.closeBackend();
        const backend = this.createBackend(this.session.path, mode);
        this.backend = backend;
        try {
            await backend.initialize();
            if (this.stopping) throw new Error('Antigravity session stopped');
            const elicitation = new AgyElicitationAdapter(this.session.client, backend);
            this.elicitation = elicitation;
            this.permission = new PermissionAdapter(
                this.session.client,
                backend,
                () => mode.permissionMode,
                (response) => elicitation.handlePermissionResponse(response)
            );
            registerAcpSessionTitleSync(backend, this.session.client);
            const config = { cwd: this.session.path, mcpServers: [] };
            const id = this.session.sessionId
                ? await backend.loadSession({ ...config, sessionId: this.session.sessionId })
                : await backend.newSession(config);
            this.session.onSessionFound(id, { agySessionProtocol: 'acp' });
            this.reactiveWakeup.syncBaseline(id);
            await configureAgyAcpSession(backend, id, mode);
            if (this.stopping || this.backend !== backend) throw new Error('Antigravity session stopped');
            this.backendModeHash = modeHash;
            return backend;
        } catch (error) {
            await this.closeBackend();
            throw error;
        }
    }

    /** Public for the RPC and deterministic queue/transport race tests. */
    async steer(payload: unknown): Promise<{ steered: boolean; error?: string }> {
        const localId = typeof (payload as { localId?: unknown } | null)?.localId === 'string'
            ? (payload as { localId: string }).localId : '';
        const backend = this.backend;
        const id = this.session.sessionId;
        const generation = this.generation;
        if (!localId || !backend || !id || this.aborting || !this.activeModeHash || !backend.isPromptRequestInFlight()) {
            return { steered: false, error: 'No active Antigravity ACP turn' };
        }
        const taken = this.session.queue.takeByLocalId(localId);
        if (!taken) return { steered: false, error: 'Message not in queue' };
        if (taken.item.isolate || taken.item.message.trimStart().startsWith('/') || taken.item.modeHash !== this.activeModeHash) {
            this.session.queue.restoreReservation(taken);
            return { steered: false, error: 'Only ordinary messages with the active turn settings can be steered' };
        }
        const hold = () => {
            if (this.session.queue.markReservationIndeterminate(taken)) this.session.client.emitSteerIndeterminate([localId]);
        };
        const restore = async () => {
            if (!taken.originIndeterminate && !await this.session.client.setSteerDeliveryState([localId], 'queued')) {
                hold(); return;
            }
            if (!this.session.queue.restoreReservation(taken)) hold();
        };
        if (!this.session.queue.beginReservationDispatch(taken)) return { steered: false, error: 'Message cancelled' };
        if (!await this.session.client.setSteerDeliveryState([localId], 'dispatching')) {
            hold(); return { steered: false, error: 'Delivery state could not be persisted' };
        }
        if (this.backend !== backend || this.generation !== generation || this.aborting
            || !backend.isPromptRequestInFlight() || taken.state !== 'dispatching') {
            await restore(); return { steered: false, error: 'Active turn changed' };
        }
        let request: ReturnType<AcpSdkBackend['beginSoftSteerPrompt']>;
        try {
            request = backend.beginSoftSteerPrompt(id, [{ type: 'text', text: taken.item.message }]);
        } catch (error) {
            if (isAcpIndeterminateError(error)) hold(); else await restore();
            return { steered: false, error: 'Could not dispatch message' };
        }
        // Register before any await: neither shutdown nor the next foreground
        // prompt may overtake receipt reconciliation.
        const settled = request.completed.then(async (reason) => {
            if (reason === 'cancelled') { hold(); return; }
            this.session.queue.commitReservation(taken);
            this.session.client.emitMessagesConsumed([localId], { steered: true });
        }, async (error) => {
            if (isAcpIndeterminateError(error)) hold(); else await restore();
        });
        this.pendingSteers.add(settled);
        void settled.finally(() => this.pendingSteers.delete(settled)).catch(() => {});
        try {
            await request.dispatched;
            return { steered: true };
        } catch (error) {
            // Completion owns restoration; avoid double restoration/racing a
            // later native acceptance. Ambiguous sends never auto-replay.
            if (isAcpIndeterminateError(error)) hold();
            return { steered: false, error: 'Delivery could not be confirmed' };
        }
    }

    async abort(): Promise<void> {
        if (this.aborting) return this.aborting;
        this.steering(false);
        this.generation++;
        this.aborting = (async () => {
            const backend = this.backend;
            if (backend && this.session.sessionId) {
                await backend.cancelPrompt(this.session.sessionId);
                // Do not report Stop complete while a native command can still
                // mutate the workspace. Disconnect terminates the process tree.
                await this.closeBackend();
            }
            await this.activeTurn;
        })();
        try { await this.aborting; } finally { this.aborting = null; }
    }

    async stop(): Promise<void> {
        this.stopping = true;
        this.exitReason = 'exit';
        this.loopAbort.abort();
        await this.abort();
    }

    private async waitForNextMessageOrIdleWakeup(): Promise<
        | { kind: 'user'; batch: NonNullable<Awaited<ReturnType<AgySession['queue']['waitForMessagesAndGetAsString']>>> }
        | { kind: 'idle-wakeup' }
        | null
    > {
        const { session } = this;
        if (this.stopping) return null;
        if (
            this.backend
            && session.sessionId
            && session.queue.size() === 0
            && this.reactiveWakeup.hasPendingIdleWork(session.sessionId)
        ) {
            return { kind: 'idle-wakeup' };
        }

        const waitAbort = new AbortController();
        let wokeOnReactive = false;
        const onLoopAbort = () => waitAbort.abort();
        if (this.loopAbort.signal.aborted) {
            waitAbort.abort();
        } else {
            this.loopAbort.signal.addEventListener('abort', onLoopAbort, { once: true });
        }

        const timer = setInterval(() => {
            if (
                !this.stopping
                && !this.aborting
                && this.backend
                && session.sessionId
                && session.queue.size() === 0
                && this.reactiveWakeup.hasPendingIdleWork(session.sessionId)
            ) {
                wokeOnReactive = true;
                waitAbort.abort();
            }
        }, this.reactiveWakeup.getPollIntervalMs());
        timer.unref?.();

        try {
            const batch = await session.queue.waitForMessagesAndGetAsString(waitAbort.signal);
            if (batch) return { kind: 'user', batch };
            if (wokeOnReactive && !this.stopping) return { kind: 'idle-wakeup' };
            return null;
        } finally {
            clearInterval(timer);
            this.loopAbort.signal.removeEventListener('abort', onLoopAbort);
        }
    }

    protected async runMainLoop(): Promise<void> {
        const { session } = this;
        this.steering(false);
        this.setupAbortHandlers(session.client.rpcHandlerManager, { onAbort: () => this.abort(), onSwitch: () => {} });
        session.client.rpcHandlerManager.registerHandler(RPC_METHODS.SteerQueuedMessage, (payload) => this.steer(payload));
        try {
            while (!this.stopping) {
                const next = await this.waitForNextMessageOrIdleWakeup();
                if (!next) break;
                if (this.aborting) await this.aborting;
                if (next.kind === 'idle-wakeup') {
                    if (this.stopping || !this.backend || !session.sessionId) continue;
                    const mode = this.lastMode;
                    // Log supplementation never owns the ACP foreground state.
                    this.generation++;
                    this.activeTurn = (async () => {
                        try {
                            const backend = this.backend;
                            if (!backend || !session.sessionId || this.stopping || this.aborting) return;
                            const onUpdate = (message: AgentMessage) => {
                                const converted = convertAgentMessage(message, mode.model);
                                if (converted) session.client.sendAgentMessage(converted);
                            };
                            await this.reactiveWakeup.afterIdleWakeup({
                                sessionId: session.sessionId,
                                cwd: session.path,
                                mode,
                                backend,
                                onUpdate,
                                shouldYield: () => this.stopping || Boolean(this.aborting) || session.queue.size() > 0,
                                isAborted: () => this.stopping || Boolean(this.aborting)
                            });
                        } catch (error) {
                            logger.debug('[agy-acp] idle reactive wakeup failed', error);
                        } finally {
                            this.publishBackgroundTasks();
                            if (!this.stopping && !this.aborting && session.sessionId
                                && this.reactiveWakeup.hasCompletedReactiveReply(session.sessionId)) session.sendSessionEvent({ type: 'ready' });
                        }
                    })();
                    await this.activeTurn;
                    this.activeTurn = null;
                    continue;
                }
                const msg = next.batch;
                if (this.stopping) {
                    session.client.emitMessagesConsumed((msg.items ?? []).flatMap((item) => item.localId ? [item.localId] : []));
                    session.sendSessionEvent({ type: 'abort-restore', text: msg.message });
                    break;
                }
                this.lastMode = msg.mode;
                const ids = (msg.items ?? []).flatMap((item) => item.localId ? [item.localId] : []);
                let accepted = false;
                const acknowledge = () => {
                    if (!accepted) { accepted = true; session.client.emitMessagesConsumed(ids); }
                };
                session.onThinkingChange(true);
                this.generation++;
                this.activeTurn = (async () => {
                    try {
                        const backend = await this.ensureBackend(msg.mode);
                        if (this.stopping || this.aborting) throw new Error('Antigravity session stopped');
                        await this.reactiveWakeup.requireResumeSyncBeforePrompt(backend, session.sessionId, session.path, msg.mode);
                        this.activeModeHash = msg.hash;
                        this.steering(true);
                        this.reactiveWakeup.beforePrompt(session.sessionId);
                        const onUpdate = (message: AgentMessage) => {
                            if (['text', 'reasoning', 'tool_call', 'tool_result'].includes(message.type)) acknowledge();
                            this.reactiveWakeup.observePromptUpdate(message);
                            const converted = convertAgentMessage(message, msg.mode.model);
                            if (converted) session.client.sendAgentMessage(converted);
                        };
                        await backend.prompt(session.sessionId!, [{ type: 'text', text: msg.message }], onUpdate);
                        acknowledge();
                        await backend.waitForResponseComplete();
                        if (this.stopping || this.aborting || this.backend !== backend) return;
                        this.steering(false);
                        session.onThinkingChange(false);
                        await this.reactiveWakeup.afterPrompt({
                            sessionId: session.sessionId!,
                            cwd: session.path,
                            mode: msg.mode,
                            backend,
                            onUpdate: (message) => {
                                const converted = convertAgentMessage(message, msg.mode.model);
                                if (converted) session.client.sendAgentMessage(converted);
                            },
                            shouldYield: () => this.stopping || Boolean(this.aborting) || session.queue.size() > 0,
                            isAborted: () => this.stopping || Boolean(this.aborting)
                        });
                        void backend.refreshSessionInfo(session.sessionId!, session.path);
                    } catch (error) {
                        if (!this.aborting && !this.stopping) {
                            session.sendSessionEvent({ type: 'error', message: error instanceof Error ? error.message : String(error) });
                        }
                        // Accepted instructions are never automatically replayed.
                        // A rejected/unconfirmed initial send is restored visibly.
                        if (!accepted) {
                            acknowledge();
                            session.sendSessionEvent({ type: 'abort-restore', text: msg.message });
                        }
                        if (!(error instanceof AgyReactiveContinuationPendingError)) await this.closeBackend();
                    } finally {
                        this.activeModeHash = null;
                        this.steering(false);
                        await Promise.allSettled([...this.pendingSteers]);
                        session.onThinkingChange(false);
                        this.publishBackgroundTasks();
                        if (!this.stopping && !this.aborting) session.sendSessionEvent({ type: 'ready' });
                    }
                })();
                await this.activeTurn;
                this.activeTurn = null;
            }
        } finally {
            await this.cleanup();
        }
    }

    protected async cleanup(): Promise<void> {
        this.session.steerQueuedMessage = null;
        this.steering(false);
        this.clearAbortHandlers(this.session.client.rpcHandlerManager);
        this.session.client.rpcHandlerManager.registerHandler(RPC_METHODS.SteerQueuedMessage,
            () => ({ steered: false, error: 'Antigravity ACP is not running' }));
        await this.closeBackend();
        logger.debug('[agy-acp] stopped');
    }
}

export async function agyAcpDriver(session: AgySession): Promise<'switch' | 'exit'> {
    return new AgyAcpDriver(session).launch();
}
