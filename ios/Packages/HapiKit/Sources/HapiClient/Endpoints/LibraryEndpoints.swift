import Foundation
import HapiProtocol

extension APIClient {
    public func recentDeliverables(limit: Int = 40) async throws -> [RecentDeliverable] {
        struct Response: Decodable { let files: [RecentDeliverable] }
        let clamped = max(1, min(limit, 100))
        let res: Response = try await request(
            .get,
            "/v1/library/deliverables",
            query: [URLQueryItem(name: "limit", value: String(clamped))]
        )
        return res.files
    }

    public func deliverableBytes(sessionId: String, mediaId: String) async throws -> Data {
        let (bytes, _) = try await requestBytes(
            "/v1/sessions/\(encodePathComponent(sessionId))/blobs/\(encodePathComponent(mediaId))"
        )
        return bytes
    }

    public func referenceDocs() async throws -> [ReferenceDoc] {
        struct Response: Decodable { let files: [ReferenceDoc] }
        let res: Response = try await request(.get, "/v1/library/reference-docs")
        return res.files
    }

    public func uploadReferenceDoc(
        filename: String,
        data: Data,
        mimeType: String,
        scope: String = "library",
        scenarioIds: [String] = []
    ) async throws -> ReferenceDoc {
        struct Body: Encodable {
            let filename: String
            let content: String
            let mimeType: String
            let scope: String
            let scenarioIds: [String]
        }
        struct Response: Decodable { let file: ReferenceDoc }
        let body = Body(
            filename: filename,
            content: data.base64EncodedString(),
            mimeType: mimeType,
            scope: scope,
            scenarioIds: scenarioIds
        )
        let res: Response = try await request(.post, "/v1/library/reference-docs", body: body)
        return res.file
    }

    public func updateReferenceDoc(
        id: String,
        filename: String? = nil,
        scope: String? = nil,
        scenarioIds: [String]? = nil
    ) async throws -> ReferenceDoc {
        struct Body: Encodable {
            let filename: String?
            let scope: String?
            let scenarioIds: [String]?
        }
        struct Response: Decodable { let file: ReferenceDoc }
        let res: Response = try await request(
            .patch,
            "/v1/library/reference-docs/\(encodePathComponent(id))",
            body: Body(filename: filename, scope: scope, scenarioIds: scenarioIds)
        )
        return res.file
    }

    public func referenceDocBytes(id: String) async throws -> Data {
        let (bytes, _) = try await requestBytes("/v1/library/reference-docs/\(encodePathComponent(id))/blob")
        return bytes
    }

    public func deleteReferenceDoc(id: String) async throws {
        try await requestVoid(.delete, "/v1/library/reference-docs/\(encodePathComponent(id))")
    }

    public func libraryScenarios() async throws -> ScenariosPayload {
        try await request(.get, "/v1/library/scenarios")
    }

    public func saveLibraryScenarios(_ scenarios: [ClientQuickAction]) async throws -> ScenariosPayload {
        struct Body: Encodable { let scenarios: [ClientQuickAction] }
        return try await request(.put, "/v1/library/scenarios", body: Body(scenarios: scenarios))
    }

    public func resetLibraryScenarios() async throws -> ScenariosPayload {
        try await request(.post, "/v1/library/scenarios/reset", body: EmptyRequestBody())
    }
}
