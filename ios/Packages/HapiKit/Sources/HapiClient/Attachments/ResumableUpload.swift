import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
import HapiProtocol

extension APIClient {
    /// Binary chunks cross the public relay; only the Hub→Runner handoff uses
    /// the existing base64 RPC. Unfinished ids survive client restarts:
    /// selecting the same prepared file again resumes its server checkpoint.
    /// No file bytes or credential material are persisted by the client here.
    func resumableUpload(sessionId: String, filename: String, data: Data, mimeType: String,
                         identities: UploadIdentityStore = .shared,
                         progress: @escaping AttachmentUploadProgressHandler = { _ in }) async throws -> UploadFileResponse {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let identity = try HapiJSON.encoder.encode([baseURL.absoluteString, sessionId, filename, mimeType, digest])
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let uploadId = await identities.acquire(key: key)
        do {
            let result = try await transferUpload(sessionId: sessionId, filename: filename, data: data,
                                                  mimeType: mimeType, digest: digest, uploadId: uploadId, progress: progress)
            await identities.release(id: uploadId, completed: true)
            return result
        } catch {
            await identities.release(id: uploadId, completed: false)
            throw error
        }
        #else
        // Linux protocol consumers do not ship CryptoKit; Apple clients use
        // the binary resumable path. Retain the existing transport on Linux.
        return try await legacyUploadFile(sessionId: sessionId, filename: filename, data: data, mimeType: mimeType)
        #endif
    }

    private func transferUpload(sessionId: String, filename: String, data: Data, mimeType: String,
                                digest: String, uploadId: String,
                                progress: @escaping AttachmentUploadProgressHandler) async throws -> UploadFileResponse {
        let path = "/api/sessions/\(encodePathComponent(sessionId))/uploads/\(uploadId)"
        let metadata = ResumableUploadRequest(filename: filename, mimeType: mimeType, size: data.count, sha256: digest)
        var failures = 0
        var acknowledged = 0
        var hasCheckpoint = false
        while true {
            try Task.checkCancellation()
            do {
                // Always re-read the authoritative offset after an uncertain
                // response: the previous chunk may already be on disk.
                var checkpoint: ResumableUploadStatus = try await request(.post, path, body: metadata)
                if let result = checkpoint.result { return result }
                guard checkpoint.chunkSize > 0, checkpoint.chunkSize <= 512 * 1024,
                      checkpoint.offset >= 0, checkpoint.offset <= data.count else {
                    throw URLError(.cannotParseResponse)
                }
                acknowledged = checkpoint.offset
                hasCheckpoint = true
                await progress(AttachmentUploadProgress(acknowledgedBytes: acknowledged, totalBytes: data.count,
                                                       phase: acknowledged == data.count ? .finishing : .uploading))
                while checkpoint.offset < data.count {
                    try Task.checkCancellation()
                    let offset = checkpoint.offset
                    let end = min(data.count, offset + checkpoint.chunkSize)
                    let next: ResumableUploadStatus = try await request(
                        .put, path + "/chunk",
                        query: [URLQueryItem(name: "offset", value: String(offset))],
                        rawBody: data.subdata(in: offset..<end),
                        contentType: "application/octet-stream"
                    )
                    guard next.offset == end, next.chunkSize == checkpoint.chunkSize else {
                        throw URLError(.cannotParseResponse)
                    }
                    checkpoint = next
                    acknowledged = next.offset
                    await progress(AttachmentUploadProgress(acknowledgedBytes: acknowledged, totalBytes: data.count,
                                                           phase: acknowledged == data.count ? .finishing : .uploading))
                    failures = 0
                }
                return try await request(.post, path + "/complete")
            } catch {
                try Task.checkCancellation()
                guard Self.canResumeUpload(after: error), failures < 3 else { throw error }
                failures += 1
                if hasCheckpoint {
                    await progress(AttachmentUploadProgress(acknowledgedBytes: acknowledged, totalBytes: data.count, phase: .retrying))
                }
                try await Task.sleep(for: .milliseconds(500 * (1 << (failures - 1))))
            }
        }
    }

    private static func canResumeUpload(after error: Error) -> Bool {
        if let error = error as? APIError {
            // 409 is a stale chunk offset; start returns the persisted offset.
            return (error.status == 409 && error.code != "session_inactive")
                || error.status == 429 || error.status >= 500
        }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }
}
