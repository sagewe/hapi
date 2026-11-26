import Foundation

/// One chat message as returned by `GET /api/sessions/:id/messages` and the
/// `message-received` SSE event.
///
/// Mirrors `DecryptedMessageSchema` (`shared/src/schemas.ts`). `content` is
/// deliberately left as raw ``JSONValue``: it is the role-wrapped envelope
/// whose decode tree (`docs/api/client-contract/messages.md`) is ported in the
/// M2 chat milestones. Decoding a message is total — an absent or `null`
/// `content` degrades to `.null` instead of throwing.
public struct DecryptedMessage: Codable, Equatable, Sendable {
    /// Server uuid. Optimistic rows use the client `localId` until echoed.
    public var contentRevision: Int?
    public var id: String
    /// Per-session insert counter; `null` on optimistic rows.
    public var seq: Int?
    /// Client-generated id for optimistic reconciliation.
    public var localId: String?
    /// Role-wrapped envelope, kept wire-verbatim (decoded by the chat pipeline).
    public var content: JSONValue
    /// Hub receive time (epoch ms).
    public var createdAt: Int
    /// When the agent consumed the message (epoch ms). `nil` covers both
    /// wire-`null` (still queued) and an absent key (pre-V8 hubs stamped
    /// rows as already invoked without the field). Current hubs always send
    /// the key, so treating `nil` as "queued" is correct against them; if
    /// pre-V8 hub support is ever needed, the M2 window store must
    /// distinguish explicit null (see pagination.md "Queued semantics").
    public var invokedAt: Int?
    /// Future-scheduled send time (epoch ms), when set.
    public var scheduledAt: Int?
    /// `indeterminate` means a steer outcome is unknown and needs explicit resolution.
    public var deliveryState: String?

    public init(
        contentRevision: Int? = nil,
        id: String,
        seq: Int? = nil,
        localId: String? = nil,
        content: JSONValue = .null,
        createdAt: Int,
        invokedAt: Int? = nil,
        scheduledAt: Int? = nil,
        deliveryState: String? = nil
    ) {
        self.contentRevision = contentRevision
        self.id = id
        self.seq = seq
        self.localId = localId
        self.content = content
        self.createdAt = createdAt
        self.invokedAt = invokedAt
        self.scheduledAt = scheduledAt
        self.deliveryState = deliveryState
    }

    private enum V1CodingKeys: String, CodingKey {
        case id
        case seq
        case local_id
        case role
        case content_rev
        case invoked_at
        case delivery_state
        case blocks
        case meta
        case created_at
    }

    public init(from decoder: Decoder) throws {
        let legacy = try decoder.container(keyedBy: CodingKeys.self)
        let v1 = try decoder.container(keyedBy: V1CodingKeys.self)

        // Native Reins v1 `StoredMessage` carries `role` + `blocks` + `created_at`
        // instead of the legacy `content` role-wrapped envelope.
        if !legacy.contains(.content) && (v1.contains(.blocks) || v1.contains(.created_at)) {
            id = try v1.decode(String.self, forKey: .id)
            seq = try v1.decodeIfPresent(Int.self, forKey: .seq)
            localId = try v1.decodeIfPresent(String.self, forKey: .local_id)
            contentRevision = try v1.decodeIfPresent(Int.self, forKey: .content_rev)
            createdAt = try v1.decode(Int.self, forKey: .created_at)
            invokedAt = try v1.decodeIfPresent(Int.self, forKey: .invoked_at)
            scheduledAt = nil
            deliveryState = try v1.decodeIfPresent(String.self, forKey: .delivery_state)

            let role = try v1.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
            let blocks = (try v1.decodeIfPresent([JSONValue].self, forKey: .blocks)) ?? []
            let meta = try v1.decodeIfPresent(JSONValue.self, forKey: .meta)
            content = Self.synthesizeContentEnvelope(id: id, role: role, blocks: blocks, meta: meta)
            return
        }

        contentRevision = try legacy.decodeIfPresent(Int.self, forKey: .contentRevision)
        id = try legacy.decode(String.self, forKey: .id)
        seq = try legacy.decodeIfPresent(Int.self, forKey: .seq)
        localId = try legacy.decodeIfPresent(String.self, forKey: .localId)
        content = try legacy.decodeIfPresent(JSONValue.self, forKey: .content) ?? .null
        createdAt = try legacy.decode(Int.self, forKey: .createdAt)
        invokedAt = try legacy.decodeIfPresent(Int.self, forKey: .invokedAt)
        scheduledAt = try legacy.decodeIfPresent(Int.self, forKey: .scheduledAt)
        deliveryState = try legacy.decodeIfPresent(String.self, forKey: .deliveryState)
    }

    private static func synthesizeContentEnvelope(
        id: String,
        role: String,
        blocks: [JSONValue],
        meta: JSONValue?
    ) -> JSONValue {
        switch role {
        case "user":
            var texts: [String] = []
            var attachments: [JSONValue] = []
            for blk in blocks {
                guard case .object(let obj) = blk, let kind = obj["type"]?.stringValue else { continue }
                switch kind {
                case "text":
                    if let t = obj["text"]?.stringValue { texts.append(t) }
                case "attachment":
                    let attId = obj["id"]?.stringValue ?? ""
                    let filename = obj["filename"]?.stringValue ?? ""
                    let mimeType = obj["mimeType"]?.stringValue ?? obj["mime_type"]?.stringValue ?? "application/octet-stream"
                    let size = obj["size"]?.numberValue ?? 0
                    let path = obj["previewUrl"]?.stringValue ?? obj["preview_url"]?.stringValue ?? filename
                    var attObj: [String: JSONValue] = [
                        "id": .string(attId),
                        "filename": .string(filename),
                        "mimeType": .string(mimeType),
                        "size": .number(size),
                        "path": .string(path),
                    ]
                    if let preview = obj["previewUrl"]?.stringValue ?? obj["preview_url"]?.stringValue {
                        attObj["previewUrl"] = .string(preview)
                    }
                    attachments.append(.object(attObj))
                default:
                    break
                }
            }
            var inner: [String: JSONValue] = [
                "type": .string("text"),
                "text": .string(texts.joined(separator: "\n")),
            ]
            if !attachments.isEmpty {
                inner["attachments"] = .array(attachments)
            }
            var envelope: [String: JSONValue] = [
                "role": .string("user"),
                "content": .object(inner),
            ]
            if let meta, meta != .null { envelope["meta"] = meta }
            return .object(envelope)

        case "assistant":
            if blocks.count == 1,
               case .object(let obj) = blocks[0],
               obj["type"]?.stringValue == "generated_media",
               let mediaId = obj["id"]?.stringValue,
               let filename = obj["filename"]?.stringValue {
                let mimeType = obj["mime_type"]?.stringValue ?? obj["mimeType"]?.stringValue ?? "image/png"
                return .object([
                    "role": .string("agent"),
                    "content": .object([
                        "type": .string("codex"),
                        "data": .object([
                            "type": .string("generated-image"),
                            "id": .string(id),
                            "imageId": .string(mediaId),
                            "fileName": .string(filename),
                            "mimeType": .string(mimeType),
                        ]),
                    ]),
                ])
            }
            var contentBlocks: [JSONValue] = []
            for blk in blocks {
                guard case .object(let obj) = blk, let kind = obj["type"]?.stringValue else { continue }
                switch kind {
                case "text":
                    if let t = obj["text"]?.stringValue {
                        contentBlocks.append(.object(["type": .string("text"), "text": .string(t)]))
                    }
                case "thinking":
                    if let t = obj["thinking"]?.stringValue {
                        contentBlocks.append(.object(["type": .string("thinking"), "thinking": .string(t)]))
                    }
                case "tool_use":
                    contentBlocks.append(.object([
                        "type": .string("tool_use"),
                        "id": obj["id"] ?? .string(""),
                        "name": obj["name"] ?? .string(""),
                        "input": obj["input"] ?? .object([:]),
                    ]))
                default:
                    break
                }
            }
            var envelope: [String: JSONValue] = [
                "role": .string("agent"),
                "content": .object([
                    "type": .string("output"),
                    "data": .object([
                        "type": .string("assistant"),
                        "message": .object([
                            "role": .string("assistant"),
                            "content": .array(contentBlocks),
                        ]),
                    ]),
                ]),
            ]
            if let meta, meta != .null { envelope["meta"] = meta }
            return .object(envelope)

        case "tool":
            var contentBlocks: [JSONValue] = []
            var firstToolName: String?
            var firstReceipt: JSONValue?
            for blk in blocks {
                guard case .object(let obj) = blk, obj["type"]?.stringValue == "tool_result" else { continue }
                if firstToolName == nil, let name = obj["name"]?.stringValue {
                    firstToolName = name
                }
                if firstReceipt == nil, let receipt = obj["receipt"], receipt != .null {
                    firstReceipt = receipt
                }
                var outObj: [String: JSONValue] = [
                    "type": .string("tool_result"),
                    "tool_use_id": obj["tool_use_id"] ?? .string(""),
                    "content": obj["content"] ?? .string(""),
                    "is_error": obj["is_error"] ?? .bool(false),
                ]
                if let receipt = obj["receipt"], receipt != .null {
                    outObj["tool_receipt"] = receipt
                }
                contentBlocks.append(.object(outObj))
            }
            var mergedMeta = meta?.objectValue ?? [:]
            if let firstToolName, mergedMeta["toolName"] == nil {
                mergedMeta["toolName"] = .string(firstToolName)
            }
            if let firstReceipt, mergedMeta["toolReceipt"] == nil {
                mergedMeta["toolReceipt"] = firstReceipt
            }
            return .object([
                "role": .string("agent"),
                "content": .object([
                    "type": .string("output"),
                    "data": .object([
                        "type": .string("user"),
                        "message": .object([
                            "role": .string("user"),
                            "content": .array(contentBlocks),
                        ]),
                    ]),
                ]),
                "meta": .object(mergedMeta),
            ])

        default: // "system" or other
            let texts = blocks.compactMap { blk -> String? in
                guard case .object(let obj) = blk, obj["type"]?.stringValue == "text" else { return nil }
                return obj["text"]?.stringValue
            }
            return .object([
                "role": .string("system"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string(texts.joined(separator: "\n")),
                ]),
            ])
        }
    }
}

/// Metadata describing an uploaded message attachment.
///
/// Mirrors `AttachmentMetadataSchema` (`shared/src/schemas.ts`). Used inside
/// user-message payloads and in the send-message request body.
public struct AttachmentMetadata: Codable, Equatable, Sendable {
    public var id: String
    public var filename: String
    public var mimeType: String
    /// Size in bytes.
    public var size: Int
    public var path: String
    /// Web-serving detail; present on wire payloads, absent from fixtures.
    public var previewUrl: String?

    public init(
        id: String,
        filename: String,
        mimeType: String,
        size: Int,
        path: String,
        previewUrl: String? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.path = path
        self.previewUrl = previewUrl
    }
}
