/// Binary chunk upload metadata. SHA-256 covers the prepared file bytes.
public struct ResumableUploadRequest: Encodable, Sendable {
    public let filename: String
    public let mimeType: String
    public let size: Int
    public let sha256: String

    public init(filename: String, mimeType: String, size: Int, sha256: String) {
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.sha256 = sha256
    }
}

/// `offset` counts bytes durably accepted by the Hub. A stored completion
/// result lets clients recover when the final response was lost.
public struct ResumableUploadStatus: Decodable, Sendable {
    public let offset: Int
    public let chunkSize: Int
    public let result: UploadFileResponse?

    private enum CodingKeys: String, CodingKey {
        case offset
        case chunkSize
        case chunk_size
        case result
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offset = try c.decode(Int.self, forKey: .offset)
        chunkSize = try c.decodeIfPresent(Int.self, forKey: .chunk_size)
            ?? c.decode(Int.self, forKey: .chunkSize)
        result = try c.decodeIfPresent(UploadFileResponse.self, forKey: .result)
    }
}
