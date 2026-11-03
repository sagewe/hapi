import Foundation

public struct WebPreviewLease: Decodable, Sendable {
    public let id: String
    public let origin: String
    public let username: String
    public let password: String
    public let expiresAt: Int
}
extension APIClient {
    public func openWebPreview(sessionId: String, host: String, port: Int) async throws -> WebPreviewLease {
        struct Target: Encodable { let host: String; let port: Int }
        return try await request(.post, "/api/sessions/\(encodePathComponent(sessionId))/preview", body: Target(host: host, port: port))
    }
    public func closeWebPreview(sessionId: String, id: String) async throws {
        try await requestVoid(.delete, "/api/sessions/\(encodePathComponent(sessionId))/preview/\(encodePathComponent(id))")
    }
}
