import { AcpSdkBackend } from '@/agent/backends/acp';
import { getAgentLaunchCommand } from '@/agent/agentLaunchCommand';
import { splitAgyModelSelection } from '@hapi/protocol';
import type { AgyMode, PermissionMode } from '../types';

export type AgyAcpNativeMode = 'default' | 'accept-edits' | 'auto' | 'plan';

export function mapAgyPermissionModeToAcpMode(permissionMode: PermissionMode): AgyAcpNativeMode {
    switch (permissionMode) {
        case 'acceptEdits':
            return 'accept-edits';
        case 'auto':
            return 'auto';
        case 'plan':
            return 'plan';
        case 'request-review':
        case 'always-proceed':
        default:
            return 'default';
    }
}

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
        // ACP message chunks are deltas. Overlap deduplication eats valid repeated
        // characters at boundaries (for example, '73-8' + '800'). The shared
        // backend separately suppresses whole-reply duplicates during Steer.
        flavor: 'agy', acpModelSwitchViaConfigOption: true, textChunkMode: 'delta'
    });
}

/** Apply only advertised ACP values. Never silently run a different model/effort/mode. */
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
    const acpMode = mapAgyPermissionModeToAcpMode(mode.permissionMode);
    const modeOption = typeof backend.getConfigOptionByCategory === 'function'
        ? backend.getConfigOptionByCategory(id, 'mode')
        : undefined;
    if (modeOption) {
        if (!modeOption.options.some((choice) => choice.value === acpMode)) {
            if (acpMode !== 'default') {
                throw new Error(`Antigravity ACP does not advertise mode ${acpMode}`);
            }
        } else if (modeOption.currentValue !== acpMode) {
            await backend.setConfigOption(id, modeOption.id, acpMode);
        }
    } else if (acpMode !== 'default') {
        throw new Error(`Antigravity ACP does not advertise mode ${acpMode}`);
    }
}
