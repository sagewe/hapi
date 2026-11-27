import Foundation

/// One SSE frame from `GET /v1/sessions/{id}/stream` (Reins Native v1 Phase B).
///
/// Mirrors `StreamEvent::to_sse_json()` in `reins-proto`. Unknown event types
/// decode to `.other(type:)` rather than throwing so newer hubs degrade safely.
public enum SessionStreamEvent: Equatable, Sendable {
    case connected
    case textDelta(turnId: String, segmentId: String?, delta: String)
    case thinkingDelta(turnId: String, segmentId: String?, delta: String)
    case turnDone(turnId: String, aborted: Bool)
    case error(turnId: String?, message: String, resync: Bool)
    case other(type: String)
}

extension SessionStreamEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case turnId
        case turn_id
        case segmentId
        case segment_id
        case delta
        case aborted
        case message
        case resync
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        func decodeTurnId() -> String {
            (try? c.decodeIfPresent(String.self, forKey: .turnId))
                ?? (try? c.decodeIfPresent(String.self, forKey: .turn_id))
                ?? ""
        }
        func decodeSegmentId() -> String? {
            let raw = (try? c.decodeIfPresent(String.self, forKey: .segmentId))
                ?? (try? c.decodeIfPresent(String.self, forKey: .segment_id))
            guard let raw, !raw.isEmpty else { return nil }
            return raw
        }

        switch type {
        case "connected":
            self = .connected
        case "text_delta":
            let delta = try c.decodeIfPresent(String.self, forKey: .delta) ?? ""
            self = .textDelta(turnId: decodeTurnId(), segmentId: decodeSegmentId(), delta: delta)
        case "thinking_delta":
            let delta = try c.decodeIfPresent(String.self, forKey: .delta) ?? ""
            self = .thinkingDelta(turnId: decodeTurnId(), segmentId: decodeSegmentId(), delta: delta)
        case "turn_done":
            let aborted = try c.decodeIfPresent(Bool.self, forKey: .aborted) ?? false
            self = .turnDone(turnId: decodeTurnId(), aborted: aborted)
        case "error":
            let turnId = (try? c.decodeIfPresent(String.self, forKey: .turnId))
                ?? (try? c.decodeIfPresent(String.self, forKey: .turn_id))
            let message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? "Stream error"
            let resync = (try? c.decodeIfPresent(Bool.self, forKey: .resync)) ?? false
            self = .error(turnId: turnId, message: message, resync: resync)
        default:
            self = .other(type: type)
        }
    }
}
