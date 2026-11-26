import Foundation

/// Why a session ended (`session-ended` event).
public enum SessionEndReason: String, Codable, Sendable {
    case completed
    case terminated
    case error
    case handoff
    case cleared
}

/// Payload of a `toast` event (visibility-targeted in-app notification).
public struct ToastPayload: Codable, Equatable, Sendable {
    public var title: String
    public var body: String
    public var sessionId: String
    public var url: String

    public init(title: String, body: String, sessionId: String, url: String) {
        self.title = title
        self.body = body
        self.sessionId = sessionId
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case body
        case sessionId
        case session_id
        case url
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        sessionId = try c.decodeIfPresent(String.self, forKey: .session_id)
            ?? c.decode(String.self, forKey: .sessionId)
        url = try c.decode(String.self, forKey: .url)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(body, forKey: .body)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(url, forKey: .url)
    }
}

/// Reconnect verdict inside `connection_changed` / `connection-changed`.
///
/// `ok` = the hub replays every missed event right after the handshake, so
/// the client may skip its REST resync. `gap` — or an absent/unknown verdict
/// — means a full refetch is required.
public enum ResumeVerdict: String, Codable, Sendable {
    case ok
    case gap
}

/// Payload of the `connection_changed` handshake frame.
public struct ConnectionChangedPayload: Codable, Equatable, Sendable {
    public var status: String
    /// Needed for `POST /v1/visibility`; new on every reconnect.
    public var subscriptionId: String?
    /// Decoded leniently: an unknown wire verdict becomes `nil`, which
    /// clients must treat as `gap` (the contract's "absence" rule).
    public var resume: ResumeVerdict?

    public init(status: String, subscriptionId: String? = nil, resume: ResumeVerdict? = nil) {
        self.status = status
        self.subscriptionId = subscriptionId
        self.resume = resume
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case subscriptionId
        case subscription_id
        case resume
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        subscriptionId = try container.decodeIfPresent(String.self, forKey: .subscription_id)
            ?? container.decodeIfPresent(String.self, forKey: .subscriptionId)
        if let raw = try container.decodeIfPresent(String.self, forKey: .resume) {
            resume = ResumeVerdict(rawValue: raw)
        } else {
            resume = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(subscriptionId, forKey: .subscriptionId)
        try container.encodeIfPresent(resume, forKey: .resume)
    }
}

/// The `session-updated` (and `session-added`) data union:
/// a full `Session`, a strict `SessionPatch`, or something this client cannot
/// interpret (the caller must fall back to a REST refetch, mirroring the web
/// client's behavior when `SessionUpdatedDataSchema` fails to parse).
public enum SessionUpdatedData: Equatable, Sendable {
    case session(Session)
    case patch(SessionPatch)
    case unrecognized(JSONValue)
}

extension SessionUpdatedData: Decodable {
    public init(from decoder: Decoder) throws {
        // Same order as `z.union([SessionSchema, SessionPatchSchema])`.
        if let session = try? Session(from: decoder) {
            self = .session(session)
            return
        }
        if let patch = try? SessionPatch(from: decoder) {
            self = .patch(patch)
            return
        }
        self = .unrecognized(try JSONValue(from: decoder))
    }
}

/// The `machine-updated` data union: full `Machine`, strict `MachinePatch`,
/// explicit `null` (machine removed), or unrecognized (refetch machines).
public enum MachineUpdatedData: Equatable, Sendable {
    case machine(Machine)
    case patch(MachinePatch)
    case removed
    case unrecognized(JSONValue)
}

extension MachineUpdatedData: Decodable {
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), single.decodeNil() {
            self = .removed
            return
        }
        if let machine = try? Machine(from: decoder) {
            self = .machine(machine)
            return
        }
        if let patch = try? MachinePatch(from: decoder) {
            self = .patch(patch)
            return
        }
        self = .unrecognized(try JSONValue(from: decoder))
    }
}

/// One frame of the `GET /api/events` SSE stream.
///
/// Mirrors `SyncEventSchema` (`shared/src/schemas.ts:535-605`) and
/// `docs/api/client-contract/sse.md`. Every case carries the optional
/// `namespace`. Unknown event types decode to `.unknown` — never throw —
/// so a hub newer than this client degrades gracefully; known types with
/// malformed payloads throw, mirroring a zod parse failure.
public enum SyncEvent: Equatable, Sendable {
    /// Handle exactly like `session-updated` (the web client shares the
    /// branch): `.session` upserts, anything else falls back to a refetch.
    case sessionAdded(namespace: String?, sessionId: String, data: SessionUpdatedData?)
    case sessionUpdated(namespace: String?, sessionId: String, data: SessionUpdatedData?)
    case sessionRemoved(namespace: String?, sessionId: String)
    case messageReceived(namespace: String?, sessionId: String, message: DecryptedMessage)
    /// History changed structurally (rewind/fork/import/clear): discard the
    /// window and tail-sync.
    case messagesInvalidated(namespace: String?, sessionId: String)
    /// A scheduled message became due and was handed to the agent.
    case scheduledMatured(namespace: String?, sessionId: String)
    /// `reason` is `nil` when absent or unknown on the wire.
    case sessionEnded(namespace: String?, sessionId: String, reason: SessionEndReason?)
    /// `data` is `nil` when the wire field is absent (refetch machines).
    case machineUpdated(namespace: String?, machineId: String, data: MachineUpdatedData?)
    case toast(namespace: String?, data: ToastPayload)
    /// Queued user messages were consumed: stamp `invokedAt` on the rows.
    case messagesConsumed(namespace: String?, sessionId: String, localIds: [String], invokedAt: Int)
    case messagesIndeterminate(namespace: String?, sessionId: String, localIds: [String])
    case messagesRequeued(namespace: String?, sessionId: String, localIds: [String])
    case messageCancelled(namespace: String?, sessionId: String, messageId: String, localId: String?)
    /// Feeds the staleness watchdog only. Carries no SSE `id`.
    case heartbeat(namespace: String?, timestamp: Int?)
    /// Subscription handshake. Carries no SSE `id`.
    case connectionChanged(namespace: String?, data: ConnectionChangedPayload?)
    /// Any `type` this client does not know. Ignore.
    case unknown(type: String, namespace: String?)
}

extension SyncEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case namespace
        case sessionId
        case session_id
        case machineId
        case machine_id
        case data
        case session
        case machine
        case active
        case updated_at
        case message
        case reason
        case localIds
        case local_ids
        case invokedAt
        case invoked_at
        case messageId
        case message_id
        case localId
        case local_id
    }

    private struct HeartbeatData: Decodable {
        let timestamp: Int
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let namespace = try container.decodeIfPresent(String.self, forKey: .namespace)

        func decodeSessionId() throws -> String {
            if let s = try container.decodeIfPresent(String.self, forKey: .session_id) {
                return s
            }
            return try container.decode(String.self, forKey: .sessionId)
        }

        func decodeMachineId() throws -> String {
            if let m = try container.decodeIfPresent(String.self, forKey: .machine_id) {
                return m
            }
            return try container.decode(String.self, forKey: .machineId)
        }

        func decodeSessionData() throws -> SessionUpdatedData? {
            if container.contains(.session) {
                return try container.decodeIfPresent(SessionUpdatedData.self, forKey: .session)
            }
            return try container.decodeIfPresent(SessionUpdatedData.self, forKey: .data)
        }

        switch type {
        case "session_added", "session-added":
            self = .sessionAdded(
                namespace: namespace,
                sessionId: try decodeSessionId(),
                data: try decodeSessionData()
            )
        case "session_updated", "session-updated":
            self = .sessionUpdated(
                namespace: namespace,
                sessionId: try decodeSessionId(),
                data: try decodeSessionData()
            )
        case "session_removed", "session-removed":
            self = .sessionRemoved(
                namespace: namespace,
                sessionId: try decodeSessionId()
            )
        case "message_received", "message-received":
            self = .messageReceived(
                namespace: namespace,
                sessionId: try decodeSessionId(),
                message: try container.decode(DecryptedMessage.self, forKey: .message)
            )
        case "messages_invalidated", "messages-invalidated":
            self = .messagesInvalidated(
                namespace: namespace,
                sessionId: try decodeSessionId()
            )
        case "scheduled_matured", "scheduled-matured":
            self = .scheduledMatured(
                namespace: namespace,
                sessionId: try decodeSessionId()
            )
        case "session_ended", "session-ended":
            let reason = try container.decodeIfPresent(String.self, forKey: .reason)
                .flatMap(SessionEndReason.init(rawValue:))
            self = .sessionEnded(
                namespace: namespace,
                sessionId: try decodeSessionId(),
                reason: reason
            )
        case "machine_updated", "machine-updated":
            let machineId = try decodeMachineId()
            let data: MachineUpdatedData?
            if container.contains(.machine) {
                if try container.decodeNil(forKey: .machine) {
                    let active = try container.decodeIfPresent(Bool.self, forKey: .active)
                    let updatedAt = try container.decodeIfPresent(Int.self, forKey: .updated_at)
                    if active != nil || updatedAt != nil {
                        data = .patch(MachinePatch(active: active, activeAt: updatedAt, updatedAt: updatedAt))
                    } else {
                        data = .removed
                    }
                } else {
                    data = try container.decode(MachineUpdatedData.self, forKey: .machine)
                }
            } else if container.contains(.data) {
                if try container.decodeNil(forKey: .data) {
                    data = .removed
                } else {
                    data = try container.decode(MachineUpdatedData.self, forKey: .data)
                }
            } else {
                let active = try container.decodeIfPresent(Bool.self, forKey: .active)
                let updatedAt = try container.decodeIfPresent(Int.self, forKey: .updated_at)
                if active != nil || updatedAt != nil {
                    data = .patch(MachinePatch(active: active, activeAt: updatedAt, updatedAt: updatedAt))
                } else {
                    data = nil
                }
            }
            self = .machineUpdated(namespace: namespace, machineId: machineId, data: data)
        case "toast":
            self = .toast(
                namespace: namespace,
                data: try container.decode(ToastPayload.self, forKey: .data)
            )
        case "messages_consumed", "messages-consumed":
            let localIds = try container.decodeIfPresent([String].self, forKey: .local_ids)
                ?? container.decode([String].self, forKey: .localIds)
            let invokedAt = try container.decodeIfPresent(Int.self, forKey: .invoked_at)
                ?? container.decode(Int.self, forKey: .invokedAt)
            self = .messagesConsumed(
                namespace: namespace,
                sessionId: try decodeSessionId(),
                localIds: localIds,
                invokedAt: invokedAt
            )
        case "messages_indeterminate", "messages-indeterminate":
            let localIds = try container.decodeIfPresent([String].self, forKey: .local_ids)
                ?? container.decode([String].self, forKey: .localIds)
            self = .messagesIndeterminate(
                namespace: namespace,
                sessionId: try decodeSessionId(),
                localIds: localIds
            )
        case "messages_requeued", "messages-requeued":
            let localIds = try container.decodeIfPresent([String].self, forKey: .local_ids)
                ?? container.decode([String].self, forKey: .localIds)
            self = .messagesRequeued(
                namespace: namespace,
                sessionId: try decodeSessionId(),
                localIds: localIds
            )
        case "message_cancelled", "message-cancelled":
            let messageId = try container.decodeIfPresent(String.self, forKey: .message_id)
                ?? container.decode(String.self, forKey: .messageId)
            let localId = try container.decodeIfPresent(String.self, forKey: .local_id)
                ?? container.decodeIfPresent(String.self, forKey: .localId)
            self = .messageCancelled(
                namespace: namespace,
                sessionId: try decodeSessionId(),
                messageId: messageId,
                localId: localId
            )
        case "heartbeat":
            self = .heartbeat(
                namespace: namespace,
                timestamp: try container.decodeIfPresent(HeartbeatData.self, forKey: .data)?.timestamp
            )
        case "connection_changed", "connection-changed":
            self = .connectionChanged(
                namespace: namespace,
                data: try container.decodeIfPresent(ConnectionChangedPayload.self, forKey: .data)
            )
        default:
            self = .unknown(type: type, namespace: namespace)
        }
    }
}
