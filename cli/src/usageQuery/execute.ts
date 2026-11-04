import { spawn } from 'node:child_process'
import { readdir, readFile, stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import type {
    UsageQueryAgent,
    UsageQueryAdapter,
    UsageQueryGroup,
    UsageQueryResult,
    UsageQueryTemplate,
    UsageQueryWindow,
    UsageQueryWindowSpec
} from '@hapi/protocol/usageQuery'
import {
    USAGE_QUERY_MAX_RESPONSE_BYTES,
    USAGE_QUERY_TIMEOUT_MS
} from '@hapi/protocol/usageQuery'
import { getAgentLaunchCommand } from '@/agent/agentLaunchCommand'
import { CodexAppServerClient } from '@/codex/codexAppServerClient'
import { resolveCodexHome } from '@/codex/utils/codexHome'
import type { ResolvedUsageCredentials } from './credentials'

type FetchResponseLike = {
    ok: boolean
    status: number
    headers?: { get(name: string): string | null }
    body?: { getReader(): ReadableStreamDefaultReader<Uint8Array> }
    text(): Promise<string>
}

export type UsageQueryFetch = (
    input: string,
    init: {
        method: string
        headers: Record<string, string>
        signal: AbortSignal
        redirect: 'error'
    }
) => Promise<FetchResponseLike>

export class UsageQueryExecutionError extends Error {
    constructor(message: string) {
        super(message)
        this.name = 'UsageQueryExecutionError'
    }
}

function parseNumber(value: unknown): number | null {
    if (typeof value === 'number') return Number.isFinite(value) ? value : null
    if (typeof value !== 'string') return null
    const trimmed = value.trim()
    if (!trimmed) return null
    const number = Number(trimmed)
    return Number.isFinite(number) ? number : null
}

function isLoopbackHostname(hostname: string): boolean {
    const normalized = hostname.toLowerCase()
    return normalized === 'localhost'
        || normalized === '127.0.0.1'
        || normalized === '[::1]'
        || normalized === '::1'
}

function normalizeBaseUrl(value: string): URL {
    let parsed: URL
    try {
        parsed = new URL(value)
    } catch {
        throw new UsageQueryExecutionError('Base URL is invalid')
    }
    if (parsed.protocol !== 'https:' && !(parsed.protocol === 'http:' && isLoopbackHostname(parsed.hostname))) {
        throw new UsageQueryExecutionError('Base URL must use HTTPS (loopback HTTP is allowed)')
    }
    if (parsed.username || parsed.password) {
        throw new UsageQueryExecutionError('Base URL must not contain embedded credentials')
    }
    parsed.hash = ''
    parsed.search = ''
    parsed.pathname = parsed.pathname.replace(/\/+$/, '') || '/'
    return parsed
}

function substitute(value: string, credentials: ResolvedUsageCredentials, baseOrigin: string): string {
    return value
        .replaceAll('{{baseUrl}}', credentials.baseUrl.replace(/\/+$/, ''))
        .replaceAll('{{baseOrigin}}', baseOrigin)
        .replaceAll('{{apiKey}}', credentials.apiKey)
}

function resolveRequestUrl(rawUrl: string, credentials: ResolvedUsageCredentials, baseOrigin: string): URL {
    if (rawUrl.includes('{{apiKey}}') || (credentials.apiKey && rawUrl.includes(credentials.apiKey))) {
        throw new UsageQueryExecutionError('API key cannot appear in the request URL')
    }
    const baseUrl = normalizeBaseUrl(credentials.baseUrl)
    const substituted = substitute(rawUrl, credentials, baseOrigin)
    let requestUrl: URL
    try {
        requestUrl = new URL(substituted, baseUrl)
    } catch {
        throw new UsageQueryExecutionError('Request URL is invalid')
    }
    if (requestUrl.origin !== baseUrl.origin) {
        throw new UsageQueryExecutionError('Request URL must use the configured base URL origin')
    }
    if (requestUrl.username || requestUrl.password) {
        throw new UsageQueryExecutionError('Request URL must not contain embedded credentials')
    }
    if (requestUrl.protocol !== 'https:' && !(requestUrl.protocol === 'http:' && isLoopbackHostname(requestUrl.hostname))) {
        throw new UsageQueryExecutionError('Request URL must use HTTPS (loopback HTTP is allowed)')
    }
    return requestUrl
}

function tokenizePath(path: string): string[] | null {
    const tokens: string[] = []
    let cursor = 0
    while (cursor < path.length) {
        if (path[cursor] === '.') {
            cursor += 1
            continue
        }
        if (path[cursor] === '[') {
            const end = path.indexOf(']', cursor + 1)
            if (end < 0 || !/^\d+$/.test(path.slice(cursor + 1, end))) return null
            tokens.push(path.slice(cursor + 1, end))
            cursor = end + 1
            continue
        }
        const start = cursor
        while (cursor < path.length && path[cursor] !== '.' && path[cursor] !== '[') cursor += 1
        if (start === cursor) return null
        tokens.push(path.slice(start, cursor))
    }
    return tokens.length > 0 ? tokens : null
}

/** Resolve the small dot/bracket path syntax used by the safe templates. */
export function getUsageJsonPath(value: unknown, path: string | undefined): unknown {
    if (!path) return undefined
    const tokens = tokenizePath(path.trim())
    if (!tokens) return undefined
    let current: unknown = value
    for (const token of tokens) {
        if (current === null || current === undefined || typeof current !== 'object') return undefined
        if (Array.isArray(current)) {
            const index = Number(token)
            if (!Number.isSafeInteger(index) || index < 0 || index >= current.length) return undefined
            current = current[index]
        } else {
            current = (current as Record<string, unknown>)[token]
        }
    }
    return current
}

export function parseResetTimestamp(value: unknown, unit: UsageQueryWindowSpec['resetUnit']): number | null {
    if (unit === 'seconds' || unit === 'milliseconds') {
        const number = parseNumber(value)
        if (number === null || number <= 0) return null
        return unit === 'milliseconds' ? Math.round(number) : Math.round(number * 1000)
    }
    if (typeof value === 'string') {
        const timestamp = Date.parse(value)
        return Number.isFinite(timestamp) ? timestamp : null
    }
    const number = parseNumber(value)
    if (number === null || number <= 0) return null
    if (number >= 1_000_000_000_000) return Math.round(number)
    return Math.round(number * 1000)
}

function clampPercent(value: number): number {
    return Math.min(100, Math.max(0, Math.round(value)))
}

async function readBoundedResponseText(response: FetchResponseLike): Promise<string> {
    const reader = response.body?.getReader()
    if (!reader) {
        // Test doubles and non-streaming fetch implementations may only expose
        // text(). Production Fetch Responses provide a body stream, so the
        // bounded path is used for real requests.
        const raw = await response.text()
        if (new TextEncoder().encode(raw).byteLength > USAGE_QUERY_MAX_RESPONSE_BYTES) {
            throw new UsageQueryExecutionError('Usage response is too large')
        }
        return raw
    }

    const chunks: Uint8Array[] = []
    let totalBytes = 0
    try {
        while (true) {
            const next = await reader.read()
            if (next.done) break
            if (!next.value) continue
            totalBytes += next.value.byteLength
            if (totalBytes > USAGE_QUERY_MAX_RESPONSE_BYTES) {
                await reader.cancel()
                throw new UsageQueryExecutionError('Usage response is too large')
            }
            chunks.push(next.value)
        }
    } finally {
        reader.releaseLock()
    }

    const bytes = new Uint8Array(totalBytes)
    let offset = 0
    for (const chunk of chunks) {
        bytes.set(chunk, offset)
        offset += chunk.byteLength
    }
    return new TextDecoder().decode(bytes)
}

/** Convert one response window into the normalized Hapi shape. */
export function normalizeUsageWindow(body: unknown, spec: UsageQueryWindowSpec): UsageQueryWindow | null {
    let percent: number | null = null
    const direct = parseNumber(getUsageJsonPath(body, spec.percentPath))
    if (direct !== null) {
        percent = (spec.percentScale ?? 'percent') === 'ratio' ? direct * 100 : direct
    }

    const limit = parseNumber(getUsageJsonPath(body, spec.limitPath))
    if (percent === null && limit !== null && limit > 0) {
        const used = parseNumber(getUsageJsonPath(body, spec.usedPath))
        const remaining = parseNumber(getUsageJsonPath(body, spec.remainingPath))
        if (used !== null) percent = (used / limit) * 100
        else if (remaining !== null) percent = ((limit - remaining) / limit) * 100
    }
    if (percent === null) return null

    return {
        usedPercent: clampPercent(percent),
        resetsAt: parseResetTimestamp(getUsageJsonPath(body, spec.resetPath), spec.resetUnit)
    }
}

function emptyUsageWindows(): { fiveHour: UsageQueryWindow | null; sevenDay: UsageQueryWindow | null } {
    return { fiveHour: null, sevenDay: null }
}

function normalizeKimiWindows(body: unknown): { fiveHour: UsageQueryWindow | null; sevenDay: UsageQueryWindow | null } {
    return {
        fiveHour: normalizeUsageWindow(body, {
            remainingPath: 'limits[0].detail.remaining',
            limitPath: 'limits[0].detail.limit',
            resetPath: 'limits[0].detail.resetTime',
            resetUnit: 'iso'
        }),
        sevenDay: normalizeUsageWindow(body, {
            remainingPath: 'usage.remaining',
            limitPath: 'usage.limit',
            resetPath: 'usage.resetTime',
            resetUnit: 'iso'
        })
    }
}

function normalizeZenMuxWindows(body: unknown): { fiveHour: UsageQueryWindow | null; sevenDay: UsageQueryWindow | null } {
    return {
        fiveHour: normalizeUsageWindow(body, {
            percentPath: 'data.quota_5_hour.usage_percentage',
            percentScale: 'ratio',
            resetPath: 'data.quota_5_hour.resets_at',
            resetUnit: 'iso'
        }),
        sevenDay: normalizeUsageWindow(body, {
            percentPath: 'data.quota_7_day.usage_percentage',
            percentScale: 'ratio',
            resetPath: 'data.quota_7_day.resets_at',
            resetUnit: 'iso'
        })
    }
}

function normalizeZhipuWindows(body: unknown): { fiveHour: UsageQueryWindow | null; sevenDay: UsageQueryWindow | null } {
    const limits = getUsageJsonPath(body, 'data.limits')
    if (!Array.isArray(limits)) return emptyUsageWindows()
    const candidates = limits.filter((item): item is Record<string, unknown> => Boolean(item) && typeof item === 'object')
        .filter((item) => {
            const type = String(item.type ?? '').toLowerCase()
            return type === 'tokens_limit' || type === 'credit_limit'
        })
        .map((item) => ({
            item,
            window: normalizeUsageWindow(item, {
                percentPath: 'percentage',
                percentScale: 'percent',
                resetPath: 'nextResetTime',
                resetUnit: 'milliseconds'
            }),
            unit: Number(item.unit)
        }))
        .filter((candidate): candidate is { item: Record<string, unknown>; window: UsageQueryWindow; unit: number } => candidate.window !== null)

    const fiveHour = candidates.find((candidate) => candidate.unit === 3)?.window ?? null
    const sevenDay = candidates.find((candidate) => candidate.unit === 6)?.window ?? null
    return { fiveHour, sevenDay }
}

function normalizeMiniMaxWindows(body: unknown): { fiveHour: UsageQueryWindow | null; sevenDay: UsageQueryWindow | null } {
    const remains = getUsageJsonPath(body, 'model_remains')
    if (!Array.isArray(remains)) return emptyUsageWindows()
    const general = remains.find((item) => item && typeof item === 'object' && (item as Record<string, unknown>).model_name === 'general')
    if (!general || typeof general !== 'object') return emptyUsageWindows()
    const item = general as Record<string, unknown>
    const fiveRemaining = parseNumber(item.current_interval_remaining_percent)
    const fiveHour = fiveRemaining === null ? null : {
        usedPercent: clampPercent(100 - fiveRemaining),
        resetsAt: parseResetTimestamp(item.end_time, 'milliseconds')
    }
    const weeklyStatus = parseNumber(item.current_weekly_status)
    const weeklyRemaining = parseNumber(item.current_weekly_remaining_percent)
    const sevenDay = weeklyStatus === 1 && weeklyRemaining !== null ? {
        usedPercent: clampPercent(100 - weeklyRemaining),
        resetsAt: parseResetTimestamp(item.weekly_end_time, 'milliseconds')
    } : null
    return { fiveHour, sevenDay }
}

export function normalizeCodexRateLimits(raw: unknown): {
    fiveHour: UsageQueryWindow | null
    sevenDay: UsageQueryWindow | null
    planType?: string | null
} {
    if (!raw || typeof raw !== 'object') return emptyUsageWindows()
    const root = raw as Record<string, unknown>
    const rateLimits = (root.rateLimits && typeof root.rateLimits === 'object' ? root.rateLimits : null)
        ?? (root.rate_limits && typeof root.rate_limits === 'object' ? root.rate_limits : null)
        ?? root
    const record = rateLimits as Record<string, unknown>

    let fiveHour: UsageQueryWindow | null = null
    let sevenDay: UsageQueryWindow | null = null

    const applyBucket = (bucket: unknown, fallbackSlot: 'fiveHour' | 'sevenDay') => {
        if (!bucket || typeof bucket !== 'object') return
        const entry = bucket as Record<string, unknown>
        const usedPercent = parseNumber(entry.usedPercent ?? entry.used_percent)
        if (usedPercent === null) return
        const window: UsageQueryWindow = {
            usedPercent: clampPercent(usedPercent),
            resetsAt: parseResetTimestamp(entry.resetsAt ?? entry.resets_at, undefined)
        }
        const durationMins = parseNumber(entry.windowDurationMins ?? entry.window_minutes)
        if (durationMins === 300) {
            fiveHour = window
        } else if (durationMins === 10080) {
            sevenDay = window
        } else if (durationMins === null) {
            if (fallbackSlot === 'fiveHour' && !fiveHour) fiveHour = window
            else if (fallbackSlot === 'sevenDay' && !sevenDay) sevenDay = window
        }
    }

    applyBucket(record.primary, 'fiveHour')
    applyBucket(record.secondary, 'sevenDay')

    const rawPlanType = typeof record.planType === 'string'
        ? record.planType.trim()
        : typeof record.plan_type === 'string'
            ? record.plan_type.trim()
            : ''

    return {
        fiveHour,
        sevenDay,
        ...(rawPlanType ? { planType: rawPlanType } : {})
    }
}

const AGY_AUTH_REQUIRED_PATTERNS = [
    'Authentication required',
    'Please sign in',
    'accounts.google.com/o/oauth2/auth'
]

function extractAgyJsonPayload(rawOutput: string | unknown): Record<string, unknown> | null {
    if (rawOutput && typeof rawOutput === 'object' && !Array.isArray(rawOutput)) {
        return rawOutput as Record<string, unknown>
    }
    if (typeof rawOutput !== 'string') return null
    for (const pattern of AGY_AUTH_REQUIRED_PATTERNS) {
        if (rawOutput.includes(pattern)) {
            throw new UsageQueryExecutionError('Antigravity authentication required. Please run agy in a terminal to sign in.')
        }
    }
    const trimmedAll = rawOutput.trim()
    if (trimmedAll.startsWith('{')) {
        try {
            const parsed: unknown = JSON.parse(trimmedAll)
            if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
                return parsed as Record<string, unknown>
            }
        } catch {
            // Fall through to line-by-line JSON discovery.
        }
    }
    for (const line of rawOutput.split(/\r?\n/)) {
        const trimmed = line.trim()
        if (!trimmed.startsWith('{')) continue
        try {
            const parsed: unknown = JSON.parse(trimmed)
            if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
                return parsed as Record<string, unknown>
            }
        } catch {
            continue
        }
    }
    return null
}

export function normalizeAgyUsageOutput(rawOutput: string | unknown): {
    fiveHour: UsageQueryWindow | null
    sevenDay: UsageQueryWindow | null
    groups: UsageQueryGroup[]
} {
    const payload = extractAgyJsonPayload(rawOutput)
    if (!payload) return { fiveHour: null, sevenDay: null, groups: [] }

    const rawGroups = getUsageJsonPath(payload, 'command.data.groups')
        ?? getUsageJsonPath(payload, 'data.groups')
        ?? payload.groups
    if (!Array.isArray(rawGroups)) return { fiveHour: null, sevenDay: null, groups: [] }

    const groups: UsageQueryGroup[] = []
    for (const rawGroup of rawGroups) {
        if (!rawGroup || typeof rawGroup !== 'object') continue
        const groupRecord = rawGroup as Record<string, unknown>
        const name = typeof groupRecord.name === 'string' ? groupRecord.name.trim() : ''
        if (!name) continue
        const id = (typeof groupRecord.id === 'string' && groupRecord.id.trim())
            ? groupRecord.id.trim()
            : name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'default'
        const buckets = Array.isArray(groupRecord.buckets) ? groupRecord.buckets : []
        let fiveHour: UsageQueryWindow | null = null
        let sevenDay: UsageQueryWindow | null = null
        for (const rawBucket of buckets) {
            if (!rawBucket || typeof rawBucket !== 'object') continue
            const bucket = rawBucket as Record<string, unknown>
            const remainingFraction = parseNumber(bucket.remaining_fraction ?? bucket.remainingFraction)
            const directUsed = parseNumber(bucket.used_percent ?? bucket.usedPercent)
            const usedPercent = remainingFraction !== null
                ? clampPercent((1 - remainingFraction) * 100)
                : directUsed !== null
                    ? clampPercent(directUsed)
                    : null
            if (usedPercent === null) continue
            const window: UsageQueryWindow = {
                usedPercent,
                resetsAt: parseResetTimestamp(bucket.reset_time ?? bucket.resetTime ?? bucket.resetsAt, 'iso')
            }
            const windowKey = String(bucket.window ?? bucket.id ?? '').toLowerCase()
            if (windowKey === '5h' || windowKey.endsWith('-5h') || windowKey === 'five_hour') {
                fiveHour = window
            } else if (windowKey === 'weekly' || windowKey.endsWith('-weekly') || windowKey === '7d' || windowKey === 'seven_day') {
                sevenDay = window
            }
        }
        if (fiveHour || sevenDay) {
            groups.push({ id, name, fiveHour, sevenDay })
        }
    }

    return {
        fiveHour: groups[0]?.fiveHour ?? null,
        sevenDay: groups[0]?.sevenDay ?? null,
        groups
    }
}

async function readLatestCodexSessionRateLimits(): Promise<{
    fiveHour: UsageQueryWindow | null
    sevenDay: UsageQueryWindow | null
    planType?: string | null
}> {
    const sessionsRoot = join(resolveCodexHome(), 'sessions')
    const jsonlFiles: Array<{ path: string; mtimeMs: number }> = []
    const walk = async (dir: string, depth: number) => {
        if (depth > 4) return
        let entries: string[]
        try {
            entries = await readdir(dir)
        } catch {
            return
        }
        for (const name of entries) {
            const full = join(dir, name)
            try {
                const info = await stat(full)
                if (info.isDirectory()) {
                    await walk(full, depth + 1)
                } else if (name.endsWith('.jsonl')) {
                    jsonlFiles.push({ path: full, mtimeMs: info.mtimeMs })
                }
            } catch {
                continue
            }
        }
    }
    await walk(sessionsRoot, 0)
    jsonlFiles.sort((left, right) => right.mtimeMs - left.mtimeMs)
    for (const file of jsonlFiles.slice(0, 5)) {
        try {
            const content = await readFile(file.path, 'utf8')
            const lines = content.trim().split(/\r?\n/)
            for (let index = lines.length - 1; index >= 0; index -= 1) {
                const line = lines[index]
                if (!line || !line.includes('rate_limits')) continue
                try {
                    const parsed = JSON.parse(line) as { payload?: { rate_limits?: unknown } }
                    const normalized = normalizeCodexRateLimits(parsed?.payload?.rate_limits ?? parsed)
                    if (normalized.fiveHour || normalized.sevenDay) return normalized
                } catch {
                    continue
                }
            }
        } catch {
            continue
        }
    }
    return emptyUsageWindows()
}

async function queryCodexNativeRateLimits(timeoutMs: number): Promise<{
    fiveHour: UsageQueryWindow | null
    sevenDay: UsageQueryWindow | null
    planType?: string | null
}> {
    const client = new CodexAppServerClient({ cwd: homedir() })
    try {
        await client.connect()
        await client.initialize({
            clientInfo: {
                name: 'hapi-codex-usage',
                version: '1.0.0'
            },
            capabilities: {
                experimentalApi: true
            }
        })
        const response = await client.request<unknown>('account/rateLimits/read', {})
        const normalized = normalizeCodexRateLimits(response)
        if (normalized.fiveHour || normalized.sevenDay) {
            return normalized
        }
    } catch {
        // Fall through to recent session logs if the app-server rpc fails.
    } finally {
        await client.disconnect({ gracefulTimeoutMs: 500 }).catch(() => undefined)
    }

    return await readLatestCodexSessionRateLimits()
}

function probeAgyUsageOutput(timeoutMs: number): Promise<string> {
    return new Promise((resolve, reject) => {
        const env: NodeJS.ProcessEnv = { ...process.env, GEMINI_FORCE_FILE_STORAGE: 'true' }
        for (const key of Object.keys(env)) {
            if (key.startsWith('SSH_')) delete env[key]
        }
        const child = spawn(getAgentLaunchCommand('agy'), ['-p', '/usage', '--output-format', 'json'], {
            stdio: ['ignore', 'pipe', 'pipe'],
            env,
            windowsHide: process.platform === 'win32'
        })
        let stdout = ''
        let stderr = ''
        let settled = false

        const timeout = setTimeout(() => {
            if (settled) return
            settled = true
            child.kill('SIGTERM')
            reject(new UsageQueryExecutionError('Usage request timed out'))
        }, timeoutMs)

        child.stdout?.on('data', (chunk: Buffer) => {
            stdout += chunk.toString()
        })
        child.stderr?.on('data', (chunk: Buffer) => {
            stderr += chunk.toString()
        })
        child.on('error', (error) => {
            if (settled) return
            settled = true
            clearTimeout(timeout)
            reject(new UsageQueryExecutionError(error.message || 'Failed to launch agy usage query'))
        })
        child.on('exit', () => {
            if (settled) return
            settled = true
            clearTimeout(timeout)
            resolve(`${stdout}\n${stderr}`)
        })
    })
}

function normalizeAdapterWindows(
    body: unknown,
    adapter: UsageQueryAdapter,
    template: UsageQueryTemplate
): { fiveHour: UsageQueryWindow | null; sevenDay: UsageQueryWindow | null } {
    switch (adapter) {
        case 'kimi-coding': return normalizeKimiWindows(body)
        case 'zenmux-subscription': return normalizeZenMuxWindows(body)
        case 'zhipu-coding': return normalizeZhipuWindows(body)
        case 'minimax-coding': return normalizeMiniMaxWindows(body)
        case 'codex-native': return normalizeCodexRateLimits(body)
        case 'agy-cli': {
            const normalized = normalizeAgyUsageOutput(body)
            return { fiveHour: normalized.fiveHour, sevenDay: normalized.sevenDay }
        }
        case 'json-path':
        default:
            return {
                fiveHour: normalizeUsageWindow(body, template.fiveHour),
                sevenDay: normalizeUsageWindow(body, template.sevenDay)
            }
    }
}

function createAbortSignal(signal: AbortSignal | undefined, timeoutMs: number): {
    signal: AbortSignal
    dispose: () => void
} {
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), timeoutMs)
    const abort = () => controller.abort()
    signal?.addEventListener('abort', abort, { once: true })
    return {
        signal: controller.signal,
        dispose: () => {
            clearTimeout(timeout)
            signal?.removeEventListener('abort', abort)
            controller.abort()
        }
    }
}

export async function executeUsageQueryTemplate(
    agent: UsageQueryAgent,
    template: UsageQueryTemplate,
    credentials: ResolvedUsageCredentials,
    options: {
        fetchImpl?: UsageQueryFetch
        codexQueryImpl?: (options: { timeoutMs: number }) => Promise<unknown>
        agyQueryImpl?: (options: { timeoutMs: number }) => Promise<string | unknown>
        timeoutMs?: number
        now?: number
    } = {}
): Promise<UsageQueryResult> {
    const timeoutMs = options.timeoutMs ?? USAGE_QUERY_TIMEOUT_MS
    const now = options.now ?? Date.now()

    if (template.adapter === 'codex-native') {
        const { fiveHour, sevenDay, planType } = options.codexQueryImpl
            ? normalizeCodexRateLimits(await options.codexQueryImpl({ timeoutMs }))
            : await queryCodexNativeRateLimits(timeoutMs)
        if (!fiveHour && !sevenDay) {
            throw new UsageQueryExecutionError('Usage response contained no configured quota windows')
        }
        return {
            agent,
            templateId: template.id,
            status: 'success',
            fiveHour,
            sevenDay,
            ...(planType ? { planType } : {}),
            queriedAt: now,
            stale: false
        }
    }

    if (template.adapter === 'agy-cli') {
        const raw = options.agyQueryImpl
            ? await options.agyQueryImpl({ timeoutMs })
            : await probeAgyUsageOutput(timeoutMs)
        const { fiveHour, sevenDay, groups } = normalizeAgyUsageOutput(raw)
        if (!fiveHour && !sevenDay) {
            throw new UsageQueryExecutionError('Usage response contained no configured quota windows')
        }
        return {
            agent,
            templateId: template.id,
            status: 'success',
            fiveHour,
            sevenDay,
            ...(groups.length > 0 ? { groups } : {}),
            queriedAt: now,
            stale: false
        }
    }

    if (!credentials.baseUrl) throw new UsageQueryExecutionError('Base URL is not configured')
    if (!credentials.apiKey) throw new UsageQueryExecutionError('API key is not configured')

    const fetchImpl = options.fetchImpl ?? (fetch as unknown as UsageQueryFetch)
    const normalizedBase = normalizeBaseUrl(credentials.baseUrl)
    const normalizedCredentials: ResolvedUsageCredentials = {
        ...credentials,
        baseUrl: normalizedBase.toString().replace(/\/+$/, '')
    }
    const requestUrl = resolveRequestUrl(template.request.url, normalizedCredentials, normalizedBase.origin)
    const headers = Object.fromEntries(
        Object.entries(template.request.headers).map(([name, value]) => [name, substitute(value, normalizedCredentials, normalizedBase.origin)])
    )
    const { signal, dispose } = createAbortSignal(undefined, options.timeoutMs ?? USAGE_QUERY_TIMEOUT_MS)
    let response: FetchResponseLike
    try {
        response = await fetchImpl(requestUrl.toString(), {
            method: template.request.method,
            headers,
            redirect: 'error',
            signal
        })
    } catch (error) {
        const timedOut = signal.aborted
        dispose()
        if (timedOut) throw new UsageQueryExecutionError('Usage request timed out')
        throw new UsageQueryExecutionError(error instanceof Error ? error.message : 'Usage request failed')
    }

    try {
        if (!response.ok) throw new UsageQueryExecutionError(`Usage request failed (HTTP ${response.status})`)
        const length = response.headers?.get('content-length')
        if (length && Number(length) > USAGE_QUERY_MAX_RESPONSE_BYTES) {
            throw new UsageQueryExecutionError('Usage response is too large')
        }

        const raw = await readBoundedResponseText(response)

        let body: unknown
        try {
            body = JSON.parse(raw) as unknown
        } catch {
            throw new UsageQueryExecutionError('Usage response was not valid JSON')
        }

        const { fiveHour, sevenDay } = normalizeAdapterWindows(body, template.adapter, template)
        if (!fiveHour && !sevenDay) throw new UsageQueryExecutionError('Usage response contained no configured quota windows')

        return {
            agent,
            templateId: template.id,
            status: 'success',
            fiveHour,
            sevenDay,
            queriedAt: options.now ?? Date.now(),
            stale: false
        }
    } finally {
        dispose()
    }
}
