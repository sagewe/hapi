import { createServer, request, type IncomingMessage } from 'node:http'
import { connect, type Socket } from 'node:net'
import { randomBytes, randomUUID, createHash, timingSafeEqual } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { spawn, type ChildProcess } from 'node:child_process'
import { PreviewOpenSchema, PreviewCloseSchema, type PreviewLease } from '@hapi/protocol'
import { getTunwgPath } from '../runtime/assets'
import { resolveHapiHomeDir } from '../configuration'

const PREVIEW_COOKIE = '__Host-hapi_preview'
const MAX_LIFETIME = 60 * 60_000
const IDLE = 10 * 60_000
const digest = (s: string) => createHash('sha256').update(s).digest()
export function previewAuthorized(header: string | undefined, expected: string): boolean {
    return !!header && timingSafeEqual(digest(header), digest(expected))
}
export function previewHeaders(req: IncomingMessage, targetHost: string, port: number, origin: string) {
    const headers = { ...req.headers }
    if (headers.cookie) headers.cookie = headers.cookie.split(';').map(v => v.trim()).filter(v => !v.startsWith(PREVIEW_COOKIE + '=')).join('; ')
    delete headers.authorization
    delete headers['proxy-authorization']
    delete headers['x-forwarded-for']
    headers.host = `${targetHost === '::1' ? '[::1]' : targetHost}:${port}`
    headers['x-forwarded-proto'] = 'https'
    delete headers['x-forwarded-host']
    if (origin) {
        headers['x-forwarded-host'] = new URL(origin).host
        if (headers.origin === origin) headers.origin = 'http://' + headers.host
        if (headers.referer?.startsWith(origin + '/')) headers.referer = 'http://' + headers.host + headers.referer.slice(origin.length)
    }
    // Forwarding credentials are never passed to the development server.
    return headers
}

type Entry = { sessionId: string; close: () => void }
export class PreviewManager {
    private stopped = false
    constructor(private readonly launchTunnel: typeof spawn = spawn) {}
    private entries = new Map<string, Entry>()
    private opening = 0
    private slots = new Set<string>()
    async open(raw: unknown): Promise<PreviewLease> {
        if (this.stopped || this.entries.size + this.opening >= 4) throw new Error('Preview limit reached; close an existing preview')
        this.opening++
        try { return await this.create(raw) } finally { this.opening-- }
    }
    private async create(raw: unknown): Promise<PreviewLease> {
        const input = PreviewOpenSchema.parse(raw)
        if (this.entries.size >= 4) throw new Error('Preview limit reached; close an existing preview')
        const api = process.env.HAPI_PREVIEW_RELAY_API
        const auth = process.env.HAPI_PREVIEW_RELAY_AUTH
        if (!api || !/^[a-z0-9.-]+$/i.test(api) || !auth) throw new Error('Runner preview relay is not configured')
        const host = input.host === '::1' ? '::1' : '127.0.0.1'
        // Test the exact loopback target, never resolve a user-supplied hostname.
        await new Promise<void>((resolve, reject) => {
            const probe = connect({ host, port: input.port })
            probe.setTimeout(3000, () => probe.destroy(new Error('Local web service is not listening')))
            probe.once('connect', () => { probe.destroy(); resolve() }); probe.once('error', reject)
        })
        const id = randomUUID(), password = randomBytes(32).toString('base64url')
        const expected = 'Basic ' + Buffer.from('preview:' + password).toString('base64')
        const expiresAt = Date.now() + MAX_LIFETIME
        let lastUsed = Date.now(), origin = '', child: ChildProcess | undefined, closed = false
        const targetKey = createHash('sha256').update(`${input.sessionId}:${host}:${input.port}`).digest('hex')
        let slot = 0
        while (this.slots.has(`${targetKey}:${slot}`)) slot++
        const slotKey = `${targetKey}:${slot}`
        this.slots.add(slotKey)
        // Stable WireGuard identity + forwarding port reuse the TLS hostname
        // on reopening, instead of issuing a new certificate on every tap.
        const directory = join(resolveHapiHomeDir(), 'web-preview', targetKey, String(slot))
        try { await mkdir(directory, { recursive: true, mode: 0o700 }) }
        catch (error) { this.slots.delete(slotKey); throw error }
        if (this.stopped) { this.slots.delete(slotKey); throw new Error('Runner stopped') }
        let gatewayPort = 0
        try {
            const saved = JSON.parse(await readFile(join(directory, 'gateway.json'), 'utf8'))
            if (Number.isInteger(saved.port) && saved.port >= 1024 && saved.port <= 65535) gatewayPort = saved.port
        } catch { /* First use allocates an ephemeral port, then persists it. */ }
        const sockets = new Set<Socket>()
        const cookieAuthorized = (req: IncomingMessage) => previewAuthorized(req.headers.cookie?.split(';').map(v => v.trim()).find(v => v.startsWith(PREVIEW_COOKIE + '='))?.slice(PREVIEW_COOKIE.length + 1), password)
        const authorized = (req: IncomingMessage) => !closed && Date.now() < expiresAt && (previewAuthorized(req.headers.authorization, expected) || cookieAuthorized(req))
        const server = createServer((req, res) => {
            if (!authorized(req)) { res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="HAPI Preview"', 'Cache-Control': 'no-store' }); res.end('Unauthorized'); return }
            if (req.headers.origin && req.headers.origin !== origin) { res.writeHead(403); res.end('Cross-origin preview request denied'); return }
            lastUsed = Date.now()
            if (!req.url?.startsWith('/') || req.url.startsWith('//')) { res.writeHead(400); res.end(); return }
            const upstream = request({ hostname: host, port: input.port, path: req.url, method: req.method, headers: previewHeaders(req, host, input.port, origin) }, response => {
                const headers = { ...response.headers }
                if (headers.location && origin) {
                    try {
                        const location = new URL(headers.location)
                        if (['localhost', '127.0.0.1', '[::1]'].includes(location.hostname) && Number(location.port || 80) === input.port) {
                            headers.location = origin + location.pathname + location.search + location.hash
                        }
                    } catch { /* Relative redirects remain relative. */ }
                }
                headers['set-cookie'] = (headers['set-cookie'] ?? []).filter(cookie => !cookie.startsWith(PREVIEW_COOKIE + '=')).map(cookie => cookie.replace(/;\s*Domain=[^;]+/ig, ''))
                if (!cookieAuthorized(req)) headers['set-cookie'].push(`${PREVIEW_COOKIE}=${password}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=${Math.max(0, Math.floor((expiresAt - Date.now()) / 1000))}`)
                res.writeHead(response.statusCode ?? 502, headers); response.pipe(res)
            })
            upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end('Preview target unavailable') })
            req.on('aborted', () => upstream.destroy()); res.on('close', () => upstream.destroy()); req.pipe(upstream)
        })
        server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)) })
        server.on('upgrade', (req, socket, head) => {
            if (!authorized(req) || !req.url?.startsWith('/') || req.url.startsWith('//') || (req.headers.origin && req.headers.origin !== origin)) {
                socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); return
            }
            lastUsed = Date.now()
            const upstream = request({ hostname: host, port: input.port, path: req.url, headers: previewHeaders(req, host, input.port, origin) })
            upstream.on('upgrade', (response, remote, remoteHead) => {
                socket.write(`HTTP/1.1 ${response.statusCode} Switching Protocols\r\n`)
                for (let i = 0; i < response.rawHeaders.length; i += 2) socket.write(response.rawHeaders[i] + ': ' + response.rawHeaders[i + 1] + '\r\n')
                socket.write('\r\n'); if (remoteHead.length) socket.write(remoteHead); if (head.length) remote.write(head)
                remote.pipe(socket); socket.pipe(remote)
                const touch = () => { lastUsed = Date.now() }; socket.on('data', touch); remote.on('data', touch)
                remote.on('error', () => socket.destroy()); socket.on('close', () => remote.destroy())
            })
            upstream.on('response', response => { socket.end(`HTTP/1.1 ${response.statusCode} Rejected\r\nConnection: close\r\n\r\n`); response.resume() })
            upstream.on('error', () => socket.destroy()); socket.on('error', () => upstream.destroy()); upstream.end()
        })
        const timer = setInterval(() => { if (Date.now() >= expiresAt || Date.now() - lastUsed > IDLE) close() }, 10_000)
        timer.unref()
        const close = () => {
            if (closed) return
            closed = true; clearInterval(timer); this.entries.delete(id); this.slots.delete(slotKey)
            for (const socket of sockets) socket.destroy()
            server.close()
            if (child && child.exitCode === null && child.signalCode === null) {
                const process = child
                process.kill('SIGTERM')
                const force = setTimeout(() => { if (process.exitCode === null && process.signalCode === null) process.kill('SIGKILL') }, 5000)
                force.unref()
            }
        }
        this.entries.set(id, { sessionId: input.sessionId, close })
        try {
            await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(gatewayPort, '127.0.0.1', resolve) })
            const address = server.address(); if (!address || typeof address === 'string') throw new Error('Cannot start preview gateway')
            await writeFile(join(directory, 'gateway.json'), JSON.stringify({ port: address.port }), { mode: 0o600 })
            origin = await new Promise<string>((resolve, reject) => {
                const timeout = setTimeout(() => { close(); reject(new Error('Preview tunnel startup timed out')) }, 45_000)
                child = this.launchTunnel(getTunwgPath(), ['--json', '--log_level=0', `--forward=http://127.0.0.1:${address.port}`], {
                    env: { ...process.env, TUNWG_API: api, TUNWG_AUTH: auth, TUNWG_PATH: directory }, stdio: ['ignore', 'pipe', 'pipe'],
                })
                let buffer = ''
                const consume = (chunk: Buffer) => {
                    buffer += chunk.toString(); if (buffer.length > 64_000) buffer = buffer.slice(-32_000)
                    const lines = buffer.split('\n'); buffer = lines.pop() ?? ''
                    for (const line of lines) {
                        try {
                            const value = JSON.parse(line)
                            if (value.msg !== 'listener started') continue
                            const url = new URL(value.url)
                            if (url.protocol !== 'https:' || !url.hostname.endsWith('.' + api) || url.username || url.password) throw new Error('Unexpected preview origin')
                            clearTimeout(timeout); resolve(url.origin)
                        } catch { /* Only accept an authenticated relay's expected URL shape. */ }
                    }
                }
                child.stdout?.on('data', consume)
                child.stderr?.on('data', consume)
                child.once('error', () => { clearTimeout(timeout); reject(new Error('Cannot start preview tunnel')); close() })
                child.once('exit', () => { clearTimeout(timeout); reject(new Error('Preview tunnel exited')); close() })
            })
            return { id, origin, username: 'preview', password, expiresAt }
        } catch (error) { close(); throw error }
    }
    close(raw: unknown): { ok: boolean } {
        const input = PreviewCloseSchema.parse(raw), entry = this.entries.get(input.id)
        if (entry && entry.sessionId !== input.sessionId) throw new Error('Preview belongs to another session')
        entry?.close(); return { ok: true }
    }
    shutdown() { this.stopped = true; for (const entry of this.entries.values()) entry.close() }
}
