import { readSettingsCached, type NamespaceSettings } from '../config/settings'
import { constantTimeEquals } from './crypto'

export const DEFAULT_NAMESPACE = 'default'
const VALID_NAMESPACE_RE = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/

export type ParsedAccessToken = {
    baseToken: string
    namespace: string
}

export type AuthenticatedAccessToken = {
    namespace: string
    isOwnerToken: boolean
}

export function parseAccessToken(raw: string): ParsedAccessToken | null {
    if (!raw) {
        return null
    }

    const trimmed = raw.trim()
    if (!trimmed) {
        return null
    }

    const separatorIndex = trimmed.lastIndexOf(':')
    if (separatorIndex === -1) {
        return { baseToken: trimmed, namespace: DEFAULT_NAMESPACE }
    }

    const baseToken = trimmed.slice(0, separatorIndex)
    const namespace = trimmed.slice(separatorIndex + 1)
    if (!baseToken || !namespace) {
        return null
    }

    if (baseToken.trim() !== baseToken || namespace.trim() !== namespace) {
        return null
    }

    return { baseToken, namespace }
}

/**
 * Authenticate a raw access token against:
 * 1. Dedicated per-namespace tokens (`settings.namespaces[ns].token`), which are
 *    strictly scoped to their single namespace and cannot escalate via `:suffix`.
 * 2. The hub owner's `cliApiToken` (optional `:namespace` suffix, default `'default'`).
 */
export function authenticateAccessToken(
    raw: string,
    options: {
        cliApiToken: string
        namespaces?: Record<string, Pick<NamespaceSettings, 'token'>>
    }
): AuthenticatedAccessToken | null {
    if (!raw) {
        return null
    }

    const trimmed = raw.trim()
    if (!trimmed) {
        return null
    }

    let matchedNamespace: string | null = null
    if (options.namespaces) {
        for (const [namespace, entry] of Object.entries(options.namespaces)) {
            if (namespace === DEFAULT_NAMESPACE || !VALID_NAMESPACE_RE.test(namespace)) {
                continue
            }
            const candidate = entry?.token
            if (
                typeof candidate !== 'string'
                || !candidate
                || candidate.trim() !== candidate
                || candidate.includes(':')
                || constantTimeEquals(candidate, options.cliApiToken)
            ) {
                continue
            }
            if (constantTimeEquals(trimmed, candidate) && matchedNamespace === null) {
                matchedNamespace = namespace
            }
        }
    }

    if (matchedNamespace !== null) {
        return { namespace: matchedNamespace, isOwnerToken: false }
    }

    const parsed = parseAccessToken(trimmed)
    if (parsed && constantTimeEquals(parsed.baseToken, options.cliApiToken)) {
        return { namespace: parsed.namespace, isOwnerToken: true }
    }

    return null
}

export async function authenticateAccessTokenFromSettings(
    raw: string,
    config: { cliApiToken: string; settingsFile: string }
): Promise<AuthenticatedAccessToken | null> {
    const settings = await readSettingsCached(config.settingsFile).catch(() => null)
    return authenticateAccessToken(raw, {
        cliApiToken: config.cliApiToken,
        namespaces: settings?.namespaces
    })
}
