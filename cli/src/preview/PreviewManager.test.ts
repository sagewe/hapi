import { afterEach, expect, it, vi } from 'vitest'
import { createServer } from 'node:http'
import { spawn } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { WebSocket, WebSocketServer } from 'ws'
import { PreviewManager } from './PreviewManager'
import { PreviewOpenSchema } from '@hapi/protocol'

afterEach(() => vi.unstubAllEnvs())
it('rejects arbitrary hosts and privileged ports', () => {
    for (const host of ['example.com', '169.254.169.254', '127.0.0.2', 'localhost.attacker.com']) {
        expect(PreviewOpenSchema.safeParse({ sessionId: 's', host, port: 3000 }).success).toBe(false)
    }
    expect(PreviewOpenSchema.safeParse({ sessionId: 's', host: 'localhost', port: 22 }).success).toBe(false)
})
it('gates HTTP/WebSocket, strips credentials and closes its listener', async () => {
    const home = mkdtempSync(join(tmpdir(), 'preview-test-'))
    vi.stubEnv('HAPI_HOME', home)
    vi.stubEnv('HAPI_PREVIEW_RELAY_API', 'relay.example')
    vi.stubEnv('HAPI_PREVIEW_RELAY_AUTH', 'fixture-relay-key')
    const target = createServer((req, res) => {
        res.setHeader('Content-Type', 'application/json')
        res.setHeader('Set-Cookie', 'app=ok; Domain=localhost; Path=/')
        res.end(JSON.stringify({ auth: req.headers.authorization ?? null, path: req.url, cookie: req.headers.cookie ?? null }))
    })
    const ws = new WebSocketServer({ server: target })
    ws.on('connection', socket => socket.on('message', data => socket.send(data)))
    await new Promise<void>(resolve => target.listen(0, '127.0.0.1', resolve))
    let gateway = ''
    const manager = new PreviewManager(((binary: string, args: string[]) => {
        gateway = args.find(a => a.startsWith('--forward='))!.slice('--forward='.length)
        return spawn(process.execPath, ['-e', `console.log(JSON.stringify({msg:'listener started',url:'https://preview.relay.example'}));setInterval(()=>{},1000)`], { stdio: ['ignore', 'pipe', 'ignore'] })
    }) as typeof spawn)
    try {
        const address = target.address(); if (!address || typeof address === 'string') throw Error('port')
        const lease = await manager.open({ sessionId: 's', host: 'localhost', port: address.port })
        expect((await fetch(gateway)).status).toBe(401)
        const auth = 'Basic ' + Buffer.from('preview:' + lease.password).toString('base64')
        const response = await fetch(gateway + '/api?q=中文', { headers: { Authorization: auth } })
        expect(await response.json()).toEqual({ auth: null, path: '/api?q=%E4%B8%AD%E6%96%87', cookie: null })
        expect(response.headers.get('set-cookie')).not.toContain('Domain=')
        const cookie = response.headers.getSetCookie().find(value => value.startsWith('__Host-hapi_preview='))!.split(';')[0]
        const viaCookie = await fetch(gateway + '/cookie', { headers: { Cookie: cookie + '; app=hello' } })
        expect(await viaCookie.json()).toEqual({ auth: null, path: '/cookie', cookie: 'app=hello' })
        expect((await fetch(gateway, { headers: { Authorization: auth, Origin: 'https://attacker.example' } })).status).toBe(403)
        expect((await fetch(gateway)).status).toBe(401)
        const upgrade = await new Promise<number>(resolve => {
            const socket = new WebSocket(gateway.replace('http:', 'ws:'))
            socket.on('unexpected-response', (_, res) => { res.resume(); socket.terminate(); resolve(res.statusCode!) }); socket.on('error', () => {})
        })
        expect(upgrade).toBe(401)
        await new Promise<void>((resolve, reject) => {
            const socket = new WebSocket(gateway.replace('http:', 'ws:'), { headers: { Cookie: cookie, Origin: lease.origin } })
            socket.on('open', () => socket.send('预览'))
            socket.on('message', data => { expect(data.toString()).toBe('预览'); socket.close(); resolve() }); socket.on('error', reject)
        })
        expect(() => manager.close({ id: lease.id, sessionId: 'other' })).toThrow()
        expect((await fetch(gateway, { headers: { Cookie: cookie } })).status).toBe(200)
        const clock = vi.spyOn(Date, 'now').mockReturnValue(lease.expiresAt + 1)
        expect((await fetch(gateway, { headers: { Cookie: cookie } })).status).toBe(401)
        clock.mockRestore()
        manager.close({ id: lease.id, sessionId: 's' })
        await expect(fetch(gateway)).rejects.toThrow()
    } finally { manager.shutdown(); ws.close(); target.closeAllConnections(); target.close(); rmSync(home, { recursive: true, force: true }) }
}, 15000)
