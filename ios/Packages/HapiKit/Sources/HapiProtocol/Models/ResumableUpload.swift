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
}
