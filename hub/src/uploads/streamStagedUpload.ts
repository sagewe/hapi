import { createReadStream } from 'node:fs'
import { DEFAULT_MAX_UPLOAD_BYTES, UPLOAD_CHUNK_MAX_BYTES, type InitChunkedUploadRequest, type UploadFileResponse } from '@hapi/protocol/apiTypes'
import type { RpcGateway } from '../sync/rpcGateway'

type UploadRunner = Pick<RpcGateway, 'initChunkedUpload' | 'uploadFileChunk' | 'finalizeChunkedUpload' | 'abortChunkedUpload'>

/** Transfer an already verified, locked Hub staging file without a whole-file
 * Buffer/base64 RPC. Hub staging remains durable until the Runner confirms. */
export async function streamStagedUpload(
    runner: UploadRunner,
    sessionId: string,
    metadata: InitChunkedUploadRequest,
    path: string
): Promise<UploadFileResponse> {
    if (!Number.isSafeInteger(metadata.size) || metadata.size < 0 || metadata.size > DEFAULT_MAX_UPLOAD_BYTES) {
        throw new Error('Invalid staged upload size')
    }
    const initialized = await runner.initChunkedUpload(sessionId, metadata)
    if (!initialized.success || !initialized.uploadId) {
        throw new Error(initialized.error ?? 'Runner rejected upload initialization')
    }
    const uploadId = initialized.uploadId
    try {
        const chunkSize = initialized.chunkSize
        if (!Number.isSafeInteger(chunkSize) || !chunkSize || chunkSize < 1 || chunkSize > UPLOAD_CHUNK_MAX_BYTES) {
            throw new Error('Runner returned an invalid upload chunk size')
        }
        let index = 0
        let received = 0
        for await (const chunk of createReadStream(path, { highWaterMark: chunkSize })) {
            const bytes = chunk as Buffer
            received += bytes.length
            if (received > metadata.size) throw new Error('Staged upload size changed')
            const result = await runner.uploadFileChunk(sessionId, uploadId, index++, bytes.toString('base64'))
            if (!result.success || result.receivedBytes !== received) {
                throw new Error(result.error ?? 'Runner did not confirm the uploaded bytes')
            }
        }
        if (received !== metadata.size) throw new Error('Staged upload size changed')
        const result = await runner.finalizeChunkedUpload(sessionId, uploadId)
        if (!result.success || !result.path) throw new Error(result.error ?? 'Runner did not confirm upload finalization')
        return result
    } catch (error) {
        // Do not retry ambiguous writes or finalize calls within this handoff.
        // The durable Hub completion can be retried as a fresh Runner transfer.
        await runner.abortChunkedUpload(sessionId, uploadId).catch(() => {})
        throw error
    }
}
