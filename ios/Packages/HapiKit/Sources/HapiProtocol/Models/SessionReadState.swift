import Foundation

public struct SessionReadState: Codable, Equatable, Sendable {
    public var readRevision: Int
    public var manualUnread: Bool
    public var version: Int

    public init(readRevision: Int = 0, manualUnread: Bool = false, version: Int = 0) {
        self.readRevision = readRevision
        self.manualUnread = manualUnread
        self.version = version
    }

    public static func merge(_ current: Self?, _ incoming: Self?) -> Self? {
        guard let incoming else { return current }
        guard let current else { return incoming }
        var next = incoming.version > current.version ? incoming : current
        next.readRevision = max(current.readRevision, incoming.readRevision)
        return next
    }
}

public struct SessionReadStateRequest: Codable, Equatable, Sendable {
    public var type: String
    public var readRevision: Int?
    public var expectedVersion: Int
    public var manualUnread: Bool?

    public init(type: String = "read", readRevision: Int? = nil, expectedVersion: Int, manualUnread: Bool? = nil) {
        self.type = type
        self.readRevision = readRevision
        self.expectedVersion = expectedVersion
        self.manualUnread = manualUnread ?? (type == "unread")
    }
}

public struct SessionReadStateResponse: Codable, Equatable, Sendable {
    public var readState: SessionReadState
    public var contentRevision: Int

    public init(readState: SessionReadState, contentRevision: Int) {
        self.readState = readState
        self.contentRevision = contentRevision
    }

    private enum CodingKeys: String, CodingKey {
        case readState
        case contentRevision
        case readRevision
        case readStateVersion
        case manualUnread
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentRevision = try c.decode(Int.self, forKey: .contentRevision)
        if let nested = try c.decodeIfPresent(SessionReadState.self, forKey: .readState) {
            readState = nested
        } else {
            let readRev = try c.decode(Int.self, forKey: .readRevision)
            let manualUnread = try c.decodeIfPresent(Bool.self, forKey: .manualUnread) ?? false
            let version = try c.decodeIfPresent(Int.self, forKey: .readStateVersion) ?? 0
            readState = SessionReadState(readRevision: readRev, manualUnread: manualUnread, version: version)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(readState, forKey: .readState)
        try c.encode(contentRevision, forKey: .contentRevision)
    }
}
