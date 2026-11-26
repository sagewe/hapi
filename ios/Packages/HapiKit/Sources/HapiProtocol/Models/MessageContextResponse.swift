import Foundation

/// Cursor block of `GET /api/sessions/:id/messages/:messageId/context`
/// (`MessageContextResponse['page']` in `shared/src/apiTypes.ts`): the bounded
/// context window carries no direction/limit/reset keys.
public struct MessageContextPage: Codable, Equatable, Sendable {
    public var epoch: Int
    public var nextBeforeSeq: Int?
    public var nextBeforeAt: Int?
    public var snapshotHeadSeq: Int?
    public var snapshotHeadAt: Int?
    public var hasMore: Bool

    public init(
        epoch: Int,
        nextBeforeSeq: Int? = nil,
        nextBeforeAt: Int? = nil,
        snapshotHeadSeq: Int? = nil,
        snapshotHeadAt: Int? = nil,
        hasMore: Bool
    ) {
        self.epoch = epoch
        self.nextBeforeSeq = nextBeforeSeq
        self.nextBeforeAt = nextBeforeAt
        self.snapshotHeadSeq = snapshotHeadSeq
        self.snapshotHeadAt = snapshotHeadAt
        self.hasMore = hasMore
    }

    private enum CodingKeys: String, CodingKey {
        case epoch
        case nextBeforeSeq
        case next_before_seq
        case nextBeforeAt
        case next_before_at
        case snapshotHeadSeq
        case snapshot_head_seq
        case snapshotHeadAt
        case snapshot_head_at
        case hasMore
        case has_more
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        epoch = try c.decode(Int.self, forKey: .epoch)
        nextBeforeSeq = try c.decodeIfPresent(Int.self, forKey: .next_before_seq)
            ?? c.decodeIfPresent(Int.self, forKey: .nextBeforeSeq)
        nextBeforeAt = try c.decodeIfPresent(Int.self, forKey: .next_before_at)
            ?? c.decodeIfPresent(Int.self, forKey: .nextBeforeAt)
        snapshotHeadSeq = try c.decodeIfPresent(Int.self, forKey: .snapshot_head_seq)
            ?? c.decodeIfPresent(Int.self, forKey: .snapshotHeadSeq)
        snapshotHeadAt = try c.decodeIfPresent(Int.self, forKey: .snapshot_head_at)
            ?? c.decodeIfPresent(Int.self, forKey: .snapshotHeadAt)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .has_more)
            ?? c.decode(Bool.self, forKey: .hasMore)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(epoch, forKey: .epoch)
        try c.encodeIfPresent(nextBeforeSeq, forKey: .nextBeforeSeq)
        try c.encodeIfPresent(nextBeforeAt, forKey: .nextBeforeAt)
        try c.encodeIfPresent(snapshotHeadSeq, forKey: .snapshotHeadSeq)
        try c.encodeIfPresent(snapshotHeadAt, forKey: .snapshotHeadAt)
        try c.encode(hasMore, forKey: .hasMore)
    }
}

/// `GET /v1/sessions/:id/messages/:messageId/context` — a bounded history
/// window centered on one message. The hub answers a bare JSON `null` when the
/// message does not resolve (web `MessageContextResponse | null`).
public struct MessageContextResponse: Codable, Equatable, Sendable {
    public var messages: [DecryptedMessage]
    public var targetMessageId: String
    public var page: MessageContextPage

    public init(
        messages: [DecryptedMessage],
        targetMessageId: String,
        page: MessageContextPage
    ) {
        self.messages = messages
        self.targetMessageId = targetMessageId
        self.page = page
    }

    private enum CodingKeys: String, CodingKey {
        case messages
        case targetMessageId
        case target_message_id
        case page
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decode([DecryptedMessage].self, forKey: .messages)
        targetMessageId = try c.decodeIfPresent(String.self, forKey: .target_message_id)
            ?? c.decode(String.self, forKey: .targetMessageId)
        page = try c.decode(MessageContextPage.self, forKey: .page)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(messages, forKey: .messages)
        try c.encode(targetMessageId, forKey: .targetMessageId)
        try c.encode(page, forKey: .page)
    }
}