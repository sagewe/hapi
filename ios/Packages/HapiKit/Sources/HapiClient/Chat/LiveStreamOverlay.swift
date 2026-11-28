import Foundation
import HapiProtocol

/// Pure state machine reconciling live `GET /v1/sessions/{id}/stream` token
/// deltas with persisted/Phase-A `WindowMessage` rows.
///
/// Key guarantees:
/// - Segments are keyed by `(turnId, segmentId ?? turnId)` in arrival order.
/// - While `/stream` is connected, Phase A `meta.streaming == true` rows whose
///   segment is actively covered by `/stream` (or already sealed) are suppressed
///   so there are no duplicate bubbles or flicker.
/// - When a user joins mid-turn, any Phase A `meta.streaming == true` segment
///   already present on `/stream` connect is recorded in
///   `preExistingStreamingSegmentIds` and stays Phase-A-authoritative until
///   sealed (or `turn_done`), even if fast post-join deltas exceed a short
///   prefix inside an 800ms Phase A throttle interval. Newly opened segments
///   stream at 60fps from `/stream`.
/// - On a sealed `WindowMessage` carrying `meta.segmentId` (with `meta.streaming`
///   absent/false) or on `turn_done`, the corresponding live overlay segment is
///   dropped immediately for a seamless handoff.
public struct LiveStreamOverlay: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public var key: String
        public var turnId: String
        public var segmentId: String?
        public var thinking: String
        public var text: String
        public var createdAt: Int

        public var totalLength: Int { thinking.count + text.count }
    }

    public private(set) var isConnected = false
    public private(set) var segments: [Segment] = []
    public private(set) var preExistingStreamingSegmentIds: Set<String> = []
    private var sealedSegmentIds: Set<String> = []
    private var awaitingInitialWindowSnapshot = false

    public init() {}

    public var hasActiveContent: Bool {
        segments.contains { !$0.thinking.isEmpty || !$0.text.isEmpty }
    }

    /// Apply one `/stream` lifecycle or wire event. Returns `true` when visible
    /// overlay output may have changed.
    @discardableResult
    public mutating func apply(
        _ event: SessionStreamClientEvent,
        now: Int,
        persistedMessages: [WindowMessage] = []
    ) -> Bool {
        switch event {
        case .connected:
            guard !isConnected else { return false }
            isConnected = true
            capturePreExistingStreaming(from: persistedMessages)
            return true

        case .disconnected:
            let changed = isConnected || !segments.isEmpty
            isConnected = false
            segments.removeAll()
            sealedSegmentIds.removeAll()
            preExistingStreamingSegmentIds.removeAll()
            awaitingInitialWindowSnapshot = false
            return changed

        case .event(let wire):
            switch wire {
            case .connected:
                guard !isConnected else { return false }
                isConnected = true
                capturePreExistingStreaming(from: persistedMessages)
                return true

            case .thinkingDelta(let turnId, let segmentId, let delta):
                guard !delta.isEmpty else { return false }
                if let segmentId,
                   sealedSegmentIds.contains(segmentId) || preExistingStreamingSegmentIds.contains(segmentId) {
                    return false
                }
                appendDelta(turnId: turnId, segmentId: segmentId, thinking: delta, text: nil, now: now)
                return true

            case .textDelta(let turnId, let segmentId, let delta):
                guard !delta.isEmpty else { return false }
                if let segmentId,
                   sealedSegmentIds.contains(segmentId) || preExistingStreamingSegmentIds.contains(segmentId) {
                    return false
                }
                appendDelta(turnId: turnId, segmentId: segmentId, thinking: nil, text: delta, now: now)
                return true

            case .turnDone(let turnId, _):
                let before = segments.count
                if turnId.isEmpty {
                    segments.removeAll()
                } else {
                    segments.removeAll { $0.turnId == turnId }
                }
                preExistingStreamingSegmentIds.removeAll()
                if segments.isEmpty {
                    sealedSegmentIds.removeAll()
                }
                return segments.count != before

            case .error(_, _, let resync):
                guard resync, !segments.isEmpty else { return false }
                segments.removeAll()
                sealedSegmentIds.removeAll()
                return true

            case .other:
                return false
            }
        }
    }

    /// Reconcile against authoritative window messages (called when `windowState`
    /// updates). Drops any live segment whose sealed `WindowMessage` has landed,
    /// clears sealed IDs from `preExistingStreamingSegmentIds`, and captures
    /// mid-turn pre-existing streaming rows if the initial window landed after
    /// `/stream` connected.
    @discardableResult
    public mutating func reconcile(with messages: [WindowMessage]) -> Bool {
        var removedAny = false
        var sealedNow = Set<String>()
        for row in messages {
            guard !Self.isStreamingRow(row), let segmentId = Self.segmentId(of: row) else { continue }
            sealedNow.insert(segmentId)
            sealedSegmentIds.insert(segmentId)
            preExistingStreamingSegmentIds.remove(segmentId)
            let before = segments.count
            segments.removeAll { $0.segmentId == segmentId }
            if segments.count != before {
                removedAny = true
            }
        }

        if isConnected && !messages.isEmpty {
            for row in messages where Self.isStreamingRow(row) {
                guard let sid = Self.segmentId(of: row),
                      !sealedNow.contains(sid),
                      !sealedSegmentIds.contains(sid),
                      !preExistingStreamingSegmentIds.contains(sid) else {
                    continue
                }
                let live = segments.first { $0.segmentId == sid }
                let persistedLen = Self.assistantTextLength(of: row)
                let shouldProtect: Bool
                if awaitingInitialWindowSnapshot {
                    shouldProtect = (live == nil) || (persistedLen > (live?.totalLength ?? 0))
                } else if let live {
                    shouldProtect = persistedLen > live.totalLength
                } else {
                    shouldProtect = false
                }
                if shouldProtect {
                    preExistingStreamingSegmentIds.insert(sid)
                    let before = segments.count
                    segments.removeAll { $0.segmentId == sid }
                    if segments.count != before {
                        removedAny = true
                    }
                }
            }
            if awaitingInitialWindowSnapshot {
                awaitingInitialWindowSnapshot = false
            }
        }

        return removedAny
    }

    /// Clear all active overlay segments (e.g. when session becomes idle or stops).
    @discardableResult
    public mutating func reset() -> Bool {
        let changed = !segments.isEmpty || !sealedSegmentIds.isEmpty || !preExistingStreamingSegmentIds.isEmpty
        isConnected = false
        segments.removeAll()
        sealedSegmentIds.removeAll()
        preExistingStreamingSegmentIds.removeAll()
        awaitingInitialWindowSnapshot = false
        return changed
    }

    /// Project the live overlay onto a window message list for `ChatPipeline`.
    public func applying(to messages: [WindowMessage]) -> [WindowMessage] {
        guard isConnected, hasActiveContent else { return messages }

        // Index active live segments by segmentId and track any unkeyed fallback
        // segment length.
        var liveBySegmentId: [String: Segment] = [:]
        var unkeyedLiveMaxLength = 0
        var hasUnkeyedLive = false
        for seg in segments where seg.totalLength > 0 {
            if let sid = seg.segmentId {
                if !preExistingStreamingSegmentIds.contains(sid) && !sealedSegmentIds.contains(sid) {
                    liveBySegmentId[sid] = seg
                }
            } else {
                hasUnkeyedLive = true
                if seg.totalLength > unkeyedLiveMaxLength {
                    unkeyedLiveMaxLength = seg.totalLength
                }
            }
        }

        var suppressedOverlayKeys = Set<String>()
        var suppressUnkeyedOverlays = false
        var filtered: [WindowMessage] = []
        filtered.reserveCapacity(messages.count + segments.count)

        for row in messages {
            guard Self.isStreamingRow(row) else {
                filtered.append(row)
                continue
            }
            if let sid = Self.segmentId(of: row) {
                if preExistingStreamingSegmentIds.contains(sid) {
                    if let live = liveBySegmentId[sid] {
                        suppressedOverlayKeys.insert(live.key)
                    }
                    filtered.append(row)
                    continue
                }
                if sealedSegmentIds.contains(sid) {
                    continue
                }
                if let live = liveBySegmentId[sid] {
                    // If the user joined mid-turn and the Phase A snapshot has
                    // more text than our post-join deltas, keep Phase A for
                    // this segment instead of truncating the prefix.
                    if Self.assistantTextLength(of: row) > live.totalLength {
                        suppressedOverlayKeys.insert(live.key)
                        filtered.append(row)
                    }
                    continue
                }
                filtered.append(row)
            } else if hasUnkeyedLive {
                if Self.assistantTextLength(of: row) > unkeyedLiveMaxLength {
                    suppressUnkeyedOverlays = true
                    filtered.append(row)
                }
                // Streaming row without segmentId while live overlay is active:
                // suppress duplicate Phase A bubble unless Phase A is longer.
                continue
            } else {
                filtered.append(row)
            }
        }

        let baseSeq = (filtered.compactMap(\.seq).max() ?? 0) + 100_000
        for (idx, seg) in segments.enumerated() where seg.totalLength > 0 {
            if suppressedOverlayKeys.contains(seg.key) { continue }
            if let sid = seg.segmentId {
                if preExistingStreamingSegmentIds.contains(sid) || sealedSegmentIds.contains(sid) {
                    continue
                }
            } else if suppressUnkeyedOverlays {
                continue
            }
            filtered.append(Self.makeWindowMessage(from: seg, syntheticSeq: baseSeq + idx))
        }
        return filtered
    }

    // MARK: - Helpers

    private mutating func capturePreExistingStreaming(from messages: [WindowMessage]) {
        preExistingStreamingSegmentIds.removeAll()
        for row in messages where Self.isStreamingRow(row) {
            if let sid = Self.segmentId(of: row), !sealedSegmentIds.contains(sid) {
                preExistingStreamingSegmentIds.insert(sid)
            }
        }
        if !preExistingStreamingSegmentIds.isEmpty {
            segments.removeAll { seg in
                guard let sid = seg.segmentId else { return false }
                return preExistingStreamingSegmentIds.contains(sid)
            }
        }
        awaitingInitialWindowSnapshot = messages.isEmpty
    }

    private mutating func appendDelta(
        turnId: String,
        segmentId: String?,
        thinking: String?,
        text: String?,
        now: Int
    ) {
        let key = segmentId.map { "\(turnId):\($0)" } ?? "\(turnId):default"
        if let idx = segments.firstIndex(where: { $0.key == key }) {
            if let thinking { segments[idx].thinking += thinking }
            if let text { segments[idx].text += text }
        } else {
            segments.append(Segment(
                key: key,
                turnId: turnId,
                segmentId: segmentId,
                thinking: thinking ?? "",
                text: text ?? "",
                createdAt: now
            ))
        }
    }

    private static func makeWindowMessage(from seg: Segment, syntheticSeq: Int) -> WindowMessage {
        var blocks: [JSONValue] = []
        if !seg.thinking.isEmpty {
            blocks.append(.object([
                "type": .string("thinking"),
                "thinking": .string(seg.thinking),
            ]))
        }
        if !seg.text.isEmpty {
            blocks.append(.object([
                "type": .string("text"),
                "text": .string(seg.text),
            ]))
        }
        var meta: [String: JSONValue] = ["streaming": .bool(true)]
        if let segmentId = seg.segmentId {
            meta["segmentId"] = .string(segmentId)
        }
        let envelope: JSONValue = .object([
            "role": .string("agent"),
            "content": .object([
                "type": .string("output"),
                "data": .object([
                    "type": .string("assistant"),
                    "message": .object([
                        "role": .string("assistant"),
                        "content": .array(blocks),
                    ]),
                ]),
            ]),
            "meta": .object(meta),
        ])
        return WindowMessage(
            id: "stream:\(seg.key)",
            seq: syntheticSeq,
            content: envelope,
            createdAt: seg.createdAt,
            invokedAt: .number(seg.createdAt)
        )
    }

    public static func isStreamingRow(_ row: WindowMessage) -> Bool {
        row.content.objectValue?["meta"]?.objectValue?["streaming"]?.boolValue == true
    }

    public static func segmentId(of row: WindowMessage) -> String? {
        let meta = row.content.objectValue?["meta"]?.objectValue
        let raw = meta?["segmentId"]?.stringValue ?? meta?["segment_id"]?.stringValue
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    private static func assistantTextLength(of row: WindowMessage) -> Int {
        guard let blocks = row.content.objectValue?["content"]?.objectValue?["data"]?
            .objectValue?["message"]?.objectValue?["content"]?.arrayValue else {
            return 0
        }
        var total = 0
        for blk in blocks {
            guard let obj = blk.objectValue else { continue }
            if let t = obj["text"]?.stringValue { total += t.count }
            if let th = obj["thinking"]?.stringValue { total += th.count }
        }
        return total
    }
}
