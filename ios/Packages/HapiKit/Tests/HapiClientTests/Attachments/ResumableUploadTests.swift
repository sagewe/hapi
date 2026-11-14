#if canImport(CryptoKit)
import Foundation
import Testing
@testable import HapiClient
import HapiProtocol

private actor ChunkServer: HTTPPerforming {
    private var stored = Data()
    private var completed = false
    private var loseChunkResponse = true
    private var loseCompleteResponse = true
    private var offline = false
    private var rejected = false
    private var completionGate: CheckedContinuation<Void, Never>?
    private var holdCompletion = false
    private(set) var completionEntered = false
    private(set) var starts = 0
    private(set) var chunks: [Int] = []
    private(set) var ids: [String] = []
    private(set) var completions = 0

    func setOffline(_ value: Bool) { offline = value }
    func setRejected() { rejected = true }
    func gateCompletionWithoutFailures() { loseChunkResponse = false; loseCompleteResponse = false; holdCompletion = true }
    func finishCompletion() { completionGate?.resume(); completionGate = nil }
    func bytes() -> Data { stored }
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let path = url.path
        let response: [String: Any]
        let status: Int
        if path.hasSuffix("/chunk") {
            if offline { throw URLError(.networkConnectionLost) }
            let offset = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? "")
            #expect(offset == stored.count)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
            let body = try #require(request.httpBody)
            #expect(body.count <= 512 * 1024)
            chunks.append(stored.count)
            stored.append(body)
            if loseChunkResponse {
                loseChunkResponse = false
                offline = true
                throw URLError(.networkConnectionLost)
            }
            status = 200
            response = ["offset": stored.count, "chunkSize": 512 * 1024]
        } else if path.hasSuffix("/complete") {
            completionEntered = true
            if holdCompletion { await withCheckedContinuation { completionGate = $0 } }
            if !completed { completions += 1; completed = true }
            if loseCompleteResponse { loseCompleteResponse = false; throw URLError(.networkConnectionLost) }
            status = 200
            response = ["success": true, "path": "/runner/file"]
        } else if path.hasSuffix("/upload/delete") {
            status = 200
            response = ["success": true]
        } else {
            starts += 1
            ids.append(url.lastPathComponent)
            if rejected {
                status = 409
                response = ["error": "Session inactive", "code": "session_inactive"]
            } else {
                if offline { throw URLError(.notConnectedToInternet) }
                status = 200
                var checkpoint: [String: Any] = ["offset": stored.count, "chunkSize": 512 * 1024]
                if completed { checkpoint["result"] = ["success": true, "path": "/runner/file"] }
                response = checkpoint
            }
        }
        return (try JSONSerialization.data(withJSONObject: response),
                try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)))
    }
}

private actor UploadProgressRecorder {
    private(set) var values: [AttachmentUploadProgress] = []
    func append(_ progress: AttachmentUploadProgress) { values.append(progress) }
}

private func makeChunkClient(_ server: ChunkServer) throws -> APIClient {
    let origin = "https://upload.example.test"
    let url = try #require(URL(string: origin))
    let credentials = InMemoryCredentialStore()
    try credentials.store(HubCredentials(hubUrl: origin, accessToken: "test-only", jwt: makeJWT(exp: Int(Date().timeIntervalSince1970) + 3600)))
    let auth = AuthManager(baseURL: url, credentialStore: credentials, performer: server)
    return APIClient(baseURL: url, authManager: auth, performer: server)
}

@Suite("Resumable attachments")
struct ResumableUploadTests {
    @MainActor @Test func trayShowsFinishingUntilServerConfirmsAndDoesNotResurrectRemovedChip() async throws {
        let server = ChunkServer()
        await server.gateCompletionWithoutFailures()
        let client = try makeChunkClient(server)
        let tray = ComposerAttachments(api: client, sessionId: "progress-fixture")
        tray.add(PreparedAttachment(id: "progress", filename: "video.mp4", mimeType: "video/mp4", bytes: Data(repeating: 7, count: 512 * 1024)))
        for _ in 0..<200 {
            if await server.completionEntered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await server.completionEntered)
        #expect(tray.items.first?.status == .uploading)
        #expect(tray.items.first?.uploadProgress?.phase == .finishing)
        #expect(tray.items.first?.uploadProgress?.fraction == 1)
        #expect(!tray.allReady)
        tray.remove("progress")
        await server.finishCompletion()
        for _ in 0..<200 {
            if await server.completions == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tray.items.isEmpty)
    }
    @Test func resumesAcceptedChunkAfterLostResponseAndManualRetry() async throws {
        let server = ChunkServer()
        let client = try makeChunkClient(server)
        let ids = UploadIdentityStore()
        let data = Data((0..<(512 * 1024 + 123)).map { UInt8($0 % 251) })
        let first = await capturedError {
            try await client.resumableUpload(sessionId: "session", filename: "video.mp4", data: data, mimeType: "video/mp4", identities: ids)
        }
        #expect(first is URLError)
        #expect(await server.bytes().count == 512 * 1024)
        await server.setOffline(false)
        let recorder = UploadProgressRecorder()
        let result = try await client.resumableUpload(sessionId: "session", filename: "video.mp4", data: data, mimeType: "video/mp4", identities: ids) {
            await recorder.append($0)
        }
        #expect(result.path == "/runner/file")
        #expect(await server.bytes() == data)
        #expect(await server.chunks == [0, 512 * 1024])
        #expect(await server.completions == 1)
        let used = await server.ids
        #expect(Set(used).count == 1)
        let updates = await recorder.values
        #expect(updates.first?.acknowledgedBytes == 512 * 1024)
        #expect(updates.contains { $0.phase == .finishing && $0.fraction == 1 })
        #expect(updates.contains { $0.phase == .retrying && $0.acknowledgedBytes == data.count })
        #expect(updates.allSatisfy { $0.totalBytes == data.count && $0.acknowledgedBytes >= 512 * 1024 })
    }

    @Test func progressIsBoundedAndRetainedAcrossRetryUntilReady() {
        let progress = AttachmentUploadProgress(acknowledgedBytes: 35, totalBytes: 100)
        let chip = ComposerAttachmentUI(id: "test", filename: "movie.mp4", mimeType: "video/mp4", sizeBytes: 100,
                                        previewBytes: nil, status: .uploading, uploadProgress: progress)
        #expect(chip.with(status: .failed).with(status: .uploading).uploadProgress == progress)
        #expect(chip.with(status: .ready).uploadProgress == nil)
        #expect(progress.percent == 35)
        #expect(AttachmentUploadProgress(acknowledgedBytes: 200, totalBytes: 100).fraction == 1)
        #expect(AttachmentUploadProgress(acknowledgedBytes: -1, totalBytes: 100).fraction == 0)
        #expect(AttachmentUploadProgress(acknowledgedBytes: 0, totalBytes: 0).fraction == 0)
    }

    @Test func inactiveSessionIsNotRetriedByTheTransport() async throws {
        let server = ChunkServer()
        await server.setRejected()
        let client = try makeChunkClient(server)
        let error = await capturedError {
            try await client.resumableUpload(sessionId: "s", filename: "x", data: Data([1]), mimeType: "video/mp4", identities: UploadIdentityStore())
        }
        #expect((error as? APIError)?.code == "session_inactive")
        #expect(await server.starts == 1)
    }

    @Test func receiptsSurviveRestartAndSeparateConcurrentOrCompletedCopies() async throws {
        let suite = "hapi-upload-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UploadIdentityStore(defaultsSuiteName: suite)
        let id = await first.acquire(key: "file-fingerprint")
        let concurrent = await first.acquire(key: "file-fingerprint")
        #expect(id != concurrent)
        let restarted = UploadIdentityStore(defaultsSuiteName: suite)
        #expect(await restarted.acquire(key: "file-fingerprint") == id)
        await restarted.release(id: id, completed: true)
        let next = await restarted.acquire(key: "file-fingerprint")
        #expect(next == concurrent)
        await restarted.release(id: next, completed: true)
        #expect(await restarted.acquire(key: "file-fingerprint") != id)
    }
}
#endif
