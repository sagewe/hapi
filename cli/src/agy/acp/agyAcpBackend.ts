import { AcpSdkBackend } from '@/agent/backends/acp';
import { getAgentLaunchCommand } from '@/agent/agentLaunchCommand';
import { splitAgyModelSelection } from '@hapi/protocol';
import type { AgyMode } from '../types';

export function createAgyAcpBackend(cwd: string, mode: AgyMode): AcpSdkBackend {
    const env: Record<string, string> = {};
    for (const [key, value] of Object.entries(process.env)) {
        if (value !== undefined && !['SSH_CLIENT', 'SSH_CONNECTION', 'SSH_TTY'].includes(key)) env[key] = value;
    }
    env.GEMINI_FORCE_FILE_STORAGE = 'true';
    const args = ['acp'];
    if (mode.permissionMode === 'always-proceed') args.push('--dangerously-skip-permissions');
    return new AcpSdkBackend({
        command: getAgentLaunchCommand('agy'), args, env, spawnCwd: cwd,
        flavor: 'agy', acpModelSwitchViaConfigOption: true, textChunkMode: 'dedupe'
    });
}

/** Apply only advertised ACP values. Never silently run a different model/effort. */
export async function configureAgyAcpSession(backend: AcpSdkBackend, id: string, mode: AgyMode): Promise<void> {
    const selection = splitAgyModelSelection(mode.model);
    if (selection.model) await backend.setModel(id, selection.model, { flavor: 'agy' });
    const effort = mode.effort ?? selection.effort;
    if (effort) {
        const option = backend.getThoughtLevelConfigOption(id);
        if (!option?.options.some((choice) => choice.value === effort)) {
            throw new Error(`Antigravity ACP does not advertise thinking level ${effort}`);
        }
        await backend.setConfigOption(id, option.id, effort);
    }
}
