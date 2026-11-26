import Foundation

/// Cursor block of a `GET /api/sessions/:id/messages` response.
///
/// Mirrors `MessagesResponse['page']` (`shared/src/apiTypes.ts`); full cursor
/// semantics in `docs/api/client-contract/pagination.md`. Every cursor is a
/// `(seq, at)` pair — both halves travel together.
public struct MessagesPage: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable {
        case latest
        case before
        case after
    }

    public var readThroughRevision: Int?
    public var direction: Direction
    public var limit: Int
    /// Server's current epoch for this session; a mismatch on your next
    /// `after` request yields a `reset: true` latest page.
    public var epoch: Int
    /// `true` ⇒ discard the local window, this page replaces it.
    public var reset: Bool
    public var nextBeforeSeq: Int?
    public var nextBeforeAt: Int?
    public var nextAfterSeq: Int?
    public var nextAfterAt: Int?
    /// Newest position at snapshot time (inclusive catch-up bound).
    public var snapshotHeadSeq: Int?
    public var snapshotHeadAt: Int?
    /// More rows exist in the requested direction.
    public var hasMore: Bool

    public init(
        readThroughRevision: Int? = nil,
        direction: Direction,
        limit: Int,
        epoch: Int,
        reset: Bool,
        nextBeforeSeq: Int? = nil,
        nextBeforeAt: Int? = nil,
        nextAfterSeq: Int? = nil,
        nextAfterAt: Int? = nil,
        snapshotHeadSeq: Int? = nil,
        snapshotHeadAt: Int? = nil,
        hasMore: Bool
    ) {
        self.readThroughRevision = readThroughRevision
        self.direction = direction
        self.limit = limit
        self.epoch = epoch
        self.reset = reset
        self.nextBeforeSeq = nextBeforeSeq
        self.nextBeforeAt = nextBeforeAt
        self.nextAfterSeq = nextAfterSeq
        self.nextAfterAt = nextAfterAt
        self.snapshotHeadSeq = snapshotHeadSeq
        self.snapshotHeadAt = snapshotHeadAt
        self.hasMore = hasMore
    }

    private enum CodingKeys: String, CodingKey {
        case readThroughRevision
        case read_through_revision
        case direction
        case limit
        case epoch
        case reset
        case nextBeforeSeq
        case next_before_seq
        case nextBeforeAt
        case next_before_at
        case nextAfterSeq
        case next_after_seq
        case nextAfterAt
        case next_after_at
        case snapshotHeadSeq
        case snapshot_head_seq
        case snapshotHeadAt
        case snapshot_head_at
        case hasMore
        case has_more
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        readThroughRevision = try c.decodeIfPresent(Int.self, forKey: .read_through_revision)
            ?? c.decodeIfPresent(Int.self, forKey: .readThroughRevision)
        direction = try c.decode(Direction.self, forKey: .direction)
        limit = try c.decode(Int.self, forKey: .limit)
        epoch = try c.decode(Int.self, forKey: .epoch)
        reset = try c.decode(Bool.self, forKey: .reset)
        nextBeforeSeq = try c.decodeIfPresent(Int.self, forKey: .next_before_seq)
            ?? c.decodeIfPresent(Int.self, forKey: .nextBeforeSeq)
        nextBeforeAt = try c.decodeIfPresent(Int.self, forKey: .next_before_at)
            ?? c.decodeIfPresent(Int.self, forKey: .nextBeforeAt)
        nextAfterSeq = try c.decodeIfPresent(Int.self, forKey: .next_after_seq)
            ?? c.decodeIfPresent(Int.self, forKey: .nextAfterSeq)
        nextAfterAt = try c.decodeIfPresent(Int.self, forKey: .next_after_at)
            ?? c.decodeIfPresent(Int.self, forKey: .nextAfterAt)
        snapshotHeadSeq = try c.decodeIfPresent(Int.self, forKey: .snapshot_head_seq)
            ?? c.decodeIfPresent(Int.self, forKey: .snapshotHeadSeq)
        snapshotHeadAt = try c.decodeIfPresent(Int.self, forKey: .snapshot_head_at)
            ?? c.decodeIfPresent(Int.self, forKey: .snapshotHeadAt)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .has_more)
            ?? c.decode(Bool.self, forKey: .hasMore)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(readThroughRevision, forKey: .readThroughRevision)
        try c.encode(direction, forKey: .direction)
        try c.encode(limit, forKey: .limit)
        try c.encode(epoch, forKey: .epoch)
        try c.encode(reset, forKey: .reset)
        try c.encodeIfPresent(nextBeforeSeq, forKey: .nextBeforeSeq)
        try c.encodeIfPresent(nextBeforeAt, forKey: .nextBeforeAt)
        try c.encodeIfPresent(nextAfterSeq, forKey: .nextAfterSeq)
        try c.encodeIfPresent(nextAfterAt, forKey: .nextAfterAt)
        try c.encodeIfPresent(snapshotHeadSeq, forKey: .snapshotHeadSeq)
        try c.encodeIfPresent(snapshotHeadAt, forKey: .snapshotHeadAt)
        try c.encode(hasMore, forKey: .hasMore)
    }
}

/// Envelope of `GET /api/sessions/:id/messages`.
public struct MessagesResponse: Codable, Equatable, Sendable {
    /// Ascending display order.
    public var messages: [DecryptedMessage]
    public var page: MessagesPage

    public init(messages: [DecryptedMessage], page: MessagesPage) {
        self.messages = messages
        self.page = page
    }
}
