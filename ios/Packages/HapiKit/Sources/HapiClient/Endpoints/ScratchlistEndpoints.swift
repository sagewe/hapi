import Foundation
import HapiProtocol

/// Scratchlist endpoints (A-M4b, `docs/api/client-contract/rest.md#scratchlist`,
/// `hub/src/web/routes/sessions.ts`). Mutations bump `scratchlistUpdatedAt`
/// in the session's SSE patch — a bare refetch trigger for
/// ``scratchlistEntries(sessionId:)``, never data
/// (see `SessionListStore.onScratchlistInvalidation`).
extension APIClient {
    /// `GET /v1/sessions/:id/scratchlist` — all entries, `createdAt DESC`.
    public func scratchlistEntries(sessionId: String) async throws -> ScratchlistEntriesResponse {
        try await request(.get, "/v1/sessions/\(encodePathComponent(sessionId))/scratchlist")
    }

    /// `POST /v1/sessions/:id/scratchlist` — 201 with the canonical row; 200
    /// with the existing row when `entryId` is already known (idempotent
    /// retry); 409 `scratchlist_at_cap` at 200 entries.
    public func createScratchlistEntry(
        sessionId: String,
        _ body: ScratchlistEntryCreateRequest
    ) async throws -> ScratchlistEntryResponse {
        try await request(
            .post,
            "/v1/sessions/\(encodePathComponent(sessionId))/scratchlist",
            body: body
        )
    }

    /// `PUT /v1/sessions/:id/scratchlist/:entryId` — 404 when the entry is gone.
    public func updateScratchlistEntry(
        sessionId: String,
        entryId: String,
        _ body: ScratchlistEntryUpdateRequest
    ) async throws -> ScratchlistEntryResponse {
        try await request(
            .put,
            "/v1/sessions/\(encodePathComponent(sessionId))/scratchlist/\(encodePathComponent(entryId))",
            body: body
        )
    }

    /// `DELETE /v1/sessions/:id/scratchlist/:entryId` — 404 when already gone.
    public func deleteScratchlistEntry(sessionId: String, entryId: String) async throws {
        try await requestVoid(
            .delete,
            "/v1/sessions/\(encodePathComponent(sessionId))/scratchlist/\(encodePathComponent(entryId))"
        )
    }

    /// `GET /v1/sessions/:id/scratchlist/limits` — attachment size/count/byte
    /// budgets (``ScratchlistAttachmentLimits``).
    public func scratchlistLimits(sessionId: String) async throws -> ScratchlistLimitsResponse {
        try await request(
            .get,
            "/v1/sessions/\(encodePathComponent(sessionId))/scratchlist/limits"
        )
    }

    /// `POST /v1/sessions/:id/uploads` — JSON + base64 (**not**
    /// multipart). Adapts Reins v1 `{success, path}` into `ScratchlistAttachment`
    /// when `attachment` is not directly returned.
    public func uploadScratchlistAttachment(
        sessionId: String,
        filename: String,
        data: Data,
        mimeType: String
    ) async throws -> ScratchlistUploadResponse {
        var response: ScratchlistUploadResponse = try await request(
            .post,
            "/v1/sessions/\(encodePathComponent(sessionId))/uploads",
            body: UploadFileRequest(
                filename: filename,
                content: data.base64EncodedString(),
                mimeType: mimeType
            )
        )
        if response.attachment == nil, response.success, let path = response.path, !path.isEmpty {
            response.attachment = ScratchlistAttachment(
                id: response.mediaId ?? UUID().uuidString,
                filename: filename,
                mimeType: mimeType,
                size: data.count,
                path: path
            )
        }
        return response
    }

    /// `GET /v1/sessions/:id/blobs/:attachmentId` — raw
    /// bytes (`Content-Type` from stored metadata). Attachment content is
    /// immutable per id, so any `URLCache` hit is safe — same plumbing as
    /// ``generatedImage(sessionId:imageId:)``.
    public func scratchlistAttachment(
        sessionId: String,
        attachmentId: String
    ) async throws -> (data: Data, mimeType: String?) {
        let (data, response) = try await requestBytes(
            "/v1/sessions/\(encodePathComponent(sessionId))/blobs/\(encodePathComponent(attachmentId))"
        )
        return (data, response.value(forHTTPHeaderField: "Content-Type"))
    }

    /// `DELETE /v1/sessions/:id/uploads` — deletes a staged upload by path/id.
    public func deleteScratchlistAttachment(sessionId: String, attachmentId: String) async throws {
        struct DeleteUploadBody: Encodable { let path: String }
        try await requestVoid(
            .delete,
            "/v1/sessions/\(encodePathComponent(sessionId))/uploads",
            body: DeleteUploadBody(path: attachmentId)
        )
    }
}
