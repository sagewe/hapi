type TitleWriteOptions = { allowTitleUpdate?: boolean; titleLocked?: boolean; tags?: string[] }

const record = (value: unknown): Record<string, unknown> | null =>
    value !== null && typeof value === 'object' && !Array.isArray(value)
        ? value as Record<string, unknown> : null

function normalizeSessionTags(raw: unknown): string[] | undefined {
    if (!Array.isArray(raw)) return undefined
    const seen = new Set<string>()
    const out: string[] = []
    for (const item of raw) {
        if (typeof item !== 'string') continue
        const trimmed = item.trim()
        if (!trimmed) continue
        const key = trimmed.toLowerCase()
        if (seen.has(key)) continue
        seen.add(key)
        out.push(trimmed)
    }
    return out.length > 0 ? out : undefined
}

/** Only a user title/tag save may change the lock or tags; enforce against the raw persisted row. */
export function preserveSessionTitle(prior: unknown, incoming: unknown, options?: TitleWriteOptions): unknown {
    const previous = record(prior)
    const locked = options?.titleLocked ?? (previous?.titleLocked === true)
    const protectTitle = previous?.titleLocked === true && !options?.allowTitleUpdate
    const tags = options?.tags !== undefined
        ? normalizeSessionTags(options.tags)
        : normalizeSessionTags(previous?.tags)
    const next = record(incoming)
    if (!next && !locked && !protectTitle && !tags) return incoming
    const result = { ...(next ?? previous ?? {}) }
    delete result.titleLocked
    delete result.tags
    if (protectTitle) {
        for (const key of ['name', 'summary'] as const) {
            if (Object.prototype.hasOwnProperty.call(previous, key)) result[key] = previous![key]
            else delete result[key]
        }
    }
    if (locked) result.titleLocked = true
    if (tags && tags.length > 0) result.tags = tags
    return result
}
