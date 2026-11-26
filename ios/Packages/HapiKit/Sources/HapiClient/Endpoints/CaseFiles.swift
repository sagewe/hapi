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

    private enum CodingKeys: String, CodingKey {
        case id
        case category
        case fileName, filename
        case mimeType, mime_type
        case size
        case createdAt, created_at
        case downloadPath, download_path
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decode(String.self, forKey: .category)
        fileName = try c.decodeIfPresent(String.self, forKey: .filename)
            ?? c.decode(String.self, forKey: .fileName)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mime_type)
            ?? c.decode(String.self, forKey: .mimeType)
        size = try c.decode(Int.self, forKey: .size)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .created_at)
            ?? c.decode(Double.self, forKey: .createdAt)
        downloadPath = try c.decodeIfPresent(String.self, forKey: .download_path)
            ?? c.decodeIfPresent(String.self, forKey: .downloadPath)
            ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(category, forKey: .category)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(mimeType, forKey: .mimeType)
        try c.encode(size, forKey: .size)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(downloadPath, forKey: .downloadPath)
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
        let response: Index = try await request(.get, "/v1/sessions/\(encodePathComponent(sessionId))/case-files")
        return response.files
    }
    public func caseFileBytes(sessionId: String, file: CaseFile) async throws -> Data {
        // Never follow a server-supplied arbitrary download URL with authentication.
        let (bytes, _) = try await requestBytes("/v1/sessions/\(encodePathComponent(sessionId))/blobs/\(encodePathComponent(file.id))")
        return bytes
    }
}
