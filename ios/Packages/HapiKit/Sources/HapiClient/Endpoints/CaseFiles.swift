import Foundation

public struct CaseFile: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let category: String
    public let fileName: String
    public let mimeType: String
    public let size: Int
    public let createdAt: Double
    public let downloadPath: String
    public init(id: String, category: String, fileName: String, mimeType: String, size: Int, createdAt: Double, downloadPath: String = "") {
        self.id = id; self.category = category; self.fileName = fileName; self.mimeType = mimeType
        self.size = size; self.createdAt = createdAt; self.downloadPath = downloadPath
    }
    public var isUpload: Bool { category == "uploads" }
    public var isImage: Bool { mimeType.hasPrefix("image/") }
    public var isZIP: Bool { fileName.lowercased().hasSuffix(".zip") }
    public var isPDF: Bool { fileName.lowercased().hasSuffix(".pdf") }
    public var selectionID: String { "\(category):\(id)" }
}

extension APIClient {
    public func caseFiles(sessionId: String) async throws -> [CaseFile] {
        struct Index: Decodable { let files: [CaseFile] }
        let response: Index = try await request(.get, "/api/sessions/\(encodePathComponent(sessionId))/case-files")
        return response.files
    }
    public func caseFileBytes(sessionId: String, file: CaseFile) async throws -> Data {
        // Never follow a server-supplied arbitrary download URL with authentication.
        let category = file.isUpload ? "uploads" : "generated-images"
        let (bytes, _) = try await requestBytes("/api/sessions/\(encodePathComponent(sessionId))/\(category)/\(encodePathComponent(file.id))")
        return bytes
    }
}
