import { afterEach, describe, expect, it } from 'bun:test'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { RpcGateway } from '../sync/rpcGateway'
import type { Server } from 'socket.io'
import type { RpcRegistry } from '../socket/rpcRegistry'
import { DEFAULT_MAX_UPLOAD_BYTES, resolveMaxUploadBytes } from '@hapi/protocol/apiTypes'
import { streamStagedUpload } from './streamStagedUpload'

const roots: string[] = []
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))) })
async function setup() {
    const root = await mkdtemp(join(tmpdir(), 'hapi-stream-upload-'))
    roots.push(root)
    const path = join(root, 'data')
    await writeFile(path, 'abcdefg')
    const chunks: Buffer[] = []
    const calls: string[] = []
    const runner: Parameters<typeof streamStagedUpload>[0] = {
        async initChunkedUpload(sessionId: string) {
            expect(sessionId).toBe('session')
            calls.push('init')
            return { success: true, uploadId: 'upload', chunkSize: 3 }
        },
        async uploadFileChunk(sessionId: string, uploadId: string, index: number, content: string) {
            expect([sessionId, uploadId, index]).toEqual(['session', 'upload', chunks.length])
            calls.push('chunk')
            chunks.push(Buffer.from(content, 'base64'))
            return { success: true, receivedBytes: Buffer.concat(chunks).length }
        },
        async finalizeChunkedUpload() { calls.push('finalize'); return { success: true, path: '/runner/file' } },
        async abortChunkedUpload() { calls.push('abort'); return { success: true } }
    }
    const metadata = { filename: 'test.bin', mimeType: 'application/octet-stream', size: 7 }
    return { runner, calls, chunks, path, metadata }
}

describe('durable upload Runner handoff', () => {
    it('retains the 50 MiB policy even when an upstream-style larger limit is configured', async () => {
        expect(DEFAULT_MAX_UPLOAD_BYTES).toBe(50 * 1024 * 1024)
        expect(resolveMaxUploadBytes(String(1024 * 1024 * 1024))).toBe(DEFAULT_MAX_UPLOAD_BYTES)
        const { runner, calls, path, metadata } = await setup()
        await expect(streamStagedUpload(runner, 'session', { ...metadata, size: DEFAULT_MAX_UPLOAD_BYTES + 1 }, path)).rejects.toThrow('Invalid staged upload size')
        expect(calls).toEqual([])
    })

    it('streams bounded ordered chunks and finalizes after every byte is confirmed', async () => {
        const { runner, calls, chunks, path, metadata } = await setup()
        expect(await streamStagedUpload(runner, 'session', metadata, path)).toEqual({ success: true, path: '/runner/file' })
        expect(chunks.map(chunk => chunk.length)).toEqual([3, 3, 1])
        expect(Buffer.concat(chunks).toString()).toBe('abcdefg')
        expect(calls).toEqual(['init', 'chunk', 'chunk', 'chunk', 'finalize'])
    })

    it('aborts on a failed or unconfirmed chunk without finalizing or retrying', async () => {
        for (const response of [{ success: false, error: 'offline' }, { success: true, receivedBytes: 0 }]) {
            const { runner, calls, path, metadata } = await setup()
            runner.uploadFileChunk = async () => { calls.push('chunk'); return response }
            await expect(streamStagedUpload(runner, 'session', metadata, path)).rejects.toThrow()
            expect(calls).toEqual(['init', 'chunk', 'abort'])
        }
    })

    it('uses the legacy handoff only when an old CLI has no init handler before dispatch', async () => {
        for (const registered of [false, true]) {
            const { path, metadata } = await setup()
            const registry = { getSocketIdForMethod: () => registered ? 'socket' : undefined } as unknown as RpcRegistry
            const gateway = new RpcGateway({} as Server, registry)
            let legacyCalls = 0
            gateway.uploadFile = async (sessionId, filename, content, mimeType) => {
                legacyCalls++
                expect([sessionId, filename, mimeType]).toEqual(['session', metadata.filename, metadata.mimeType])
                expect(Buffer.from(content, 'base64').toString()).toBe('abcdefg')
                return { success: true, path: '/legacy/file' }
            }
            gateway.initChunkedUpload = async () => { throw new Error('init timed out') }
            if (registered) {
                await expect(gateway.uploadStagedFile('session', metadata, path)).rejects.toThrow('init timed out')
                expect(legacyCalls).toBe(0)
            } else {
                expect(await gateway.uploadStagedFile('session', metadata, path)).toEqual({ success: true, path: '/legacy/file' })
                expect(legacyCalls).toBe(1)
            }
        }
    })

    it('rejects invalid chunk bounds, changed files, and lost finalization responses', async () => {
        for (const mode of ['bounds', 'short', 'long', 'finalize'] as const) {
            const { runner, calls, path, metadata } = await setup()
            if (mode === 'bounds') runner.initChunkedUpload = async () => ({ success: true, uploadId: 'upload', chunkSize: Number.MAX_SAFE_INTEGER })
            if (mode === 'short') await writeFile(path, 'abc')
            if (mode === 'long') await writeFile(path, 'abcdefghi')
            if (mode === 'finalize') runner.finalizeChunkedUpload = async () => { calls.push('finalize'); throw new Error('connection lost') }
            await expect(streamStagedUpload(runner, 'session', metadata, path)).rejects.toThrow()
            expect(calls.at(-1)).toBe('abort')
            if (mode !== 'finalize') expect(calls).not.toContain('finalize')
        }
    })
})
