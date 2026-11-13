import type { Store } from '../store'
import type { SyncEngine } from '../sync/syncEngine'
import { extractTitleMessage } from '../sync/titleSuggestion'

export type AsrVocabulary = { keywords: string[] }

/** Extract vocabulary only, never forward conversation excerpts, tool output or absolute paths. */
export function extractAsrVocabulary(texts: string[]): AsrVocabulary {
    const keywords: string[] = []
    for (const text of texts) {
        const clean = text.slice(0, 8000).replace(/```[\s\S]*?(?:```|$)/g, '')
        for (const line of clean.split('\n')) {
            if (/(?:password|passwd|secret|token|cookie|authorization|bearer|api.?key|私钥|密码|凭据|密钥)/i.test(line)) continue
            const safe = line.replace(/https?:\/\/\S+|\b\S+@\S+|\b[A-Z_][A-Z0-9_]*\s*=\s*\S+/g, '')
                .replace(/(?:\/[\w.-]+){2,}/g, path => {
                    const file = path.split('/').at(-1) ?? ''
                    return /\.(?:swift|rs|tsx?|jsx?|py|kt|java|go|md|toml|css)$/i.test(file) ? ` ${file} ` : ''
                })
            for (const token of safe.match(/[A-Za-z][A-Za-z0-9_.+-]{1,47}|[\u3400-\u9fff]{2,16}/g) ?? []) {
                if (/^(?:user|assistant|the|and|this|that|with|from|have|will|please)$/i.test(token)) continue
                if (/^(?:sk-|ghp_|github_pat_|AKIA)/i.test(token) || (token.length > 24 && /\d/.test(token))) continue
                if (!keywords.some(w => w.toLowerCase() === token.toLowerCase())) keywords.push(token)
                if (keywords.length >= 40) return { keywords }
            }
        }
    }
    return { keywords }
}

// Bounded, process-local snapshots. A recording's WS and HTTP fallback share one vocabulary.
const snapshots = new Map<string, { at: number; vocabulary: AsrVocabulary }>()
const TTL = 10 * 60 * 1000
export function resolveAsrContext(
    engine: SyncEngine | null, store: Store | undefined, namespace: string,
    sessionId: string | undefined, draft: string = '', recordingId: string = ''
): AsrVocabulary {
    if (!sessionId) return { keywords: [] }
    if (!engine) throw new Error('ASR session context unavailable')
    const access = engine.resolveSessionAccess(sessionId, namespace)
    if (!access.ok) throw new Error('ASR session access denied')
    const now = Date.now()
    for (const [key, value] of snapshots) if (now - value.at > TTL) snapshots.delete(key)
    const key = recordingId ? JSON.stringify([namespace, access.sessionId, recordingId.slice(0, 80)]) : ''
    const cached = key ? snapshots.get(key) : undefined
    if (cached) return cached.vocabulary
    const metadata = access.session.metadata
    const project = metadata?.path?.split(/[\\/]/).filter(Boolean).at(-1) ?? ''
    const messages = store?.messages.getMessages(access.sessionId, 24) ?? []
    const vocabulary = extractAsrVocabulary([
        draft.slice(0, 2000), metadata?.name ?? '', metadata?.summary?.text ?? '', project,
        ...messages.reverse().flatMap(message => {
            const extracted = extractTitleMessage(message)
            return extracted ? [extracted.text.slice(0, 1200)] : []
        }).slice(0, 8)
    ])
    if (key) {
        if (snapshots.size >= 256) snapshots.delete(snapshots.keys().next().value!)
        snapshots.set(key, { at: now, vocabulary })
    }
    return vocabulary
}

export function encodeAsrContext(context: AsrVocabulary): string {
    return Buffer.from(JSON.stringify(context)).toString('base64')
}
