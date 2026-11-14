/// Bytes acknowledged by the Hub, rather than bytes merely sent by the phone.
public struct AttachmentUploadProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case uploading, retrying, finishing }
    public let acknowledgedBytes: Int
    public let totalBytes: Int
    public let phase: Phase

    public init(acknowledgedBytes: Int, totalBytes: Int, phase: Phase = .uploading) {
        self.totalBytes = max(0, totalBytes)
        self.acknowledgedBytes = min(max(0, acknowledgedBytes), max(0, totalBytes))
        self.phase = phase
    }

    public var fraction: Double { totalBytes > 0 ? Double(acknowledgedBytes) / Double(totalBytes) : 0 }
    public var percent: Int { Int(fraction * 100) }
}

public typealias AttachmentUploadProgressHandler = @Sendable (AttachmentUploadProgress) async -> Void
