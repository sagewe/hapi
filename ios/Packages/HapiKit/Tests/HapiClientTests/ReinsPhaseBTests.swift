import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HapiClient
@testable import HapiProtocol

@Suite("Reins Phase B — Live Stream, Queue/Steer, and Usage Projection")
struct ReinsPhaseBTests {

    // MARK: - 1. meta.usage -> DecryptedMessage -> Normalize -> Reduce -> LatestUsage

    @Test("StoredMessage meta.usage projects context_tokens and context_window to LatestUsage")
    func metaUsageProjectsToLatestUsage() throws {
        let json = """
        {
          "id": "msg-usage-1",
          "seq": 10,
          "role": "assistant",
          "created_at": 1730000010000,
          "blocks": [{"type": "text", "text": "Done checking."}],
          "meta": {
            "model": "claude-opus-4-6",
            "usage": {
              "input_tokens": 12000,
              "output_tokens": 850,
              "cache_read_input_tokens": 30000,
              "context_tokens": 42000,
              "context_window": 200000
            }
          }
        }
        """
        let decoded = try HapiJSON.decoder.decode(DecryptedMessage.self, from: Data(json.utf8))
        let normalized = try #require(normalizeDecryptedMessage(decoded))
        #expect(normalized.model == "claude-opus-4-6")
        #expect(normalized.usage?.inputTokens == 12000)
        #expect(normalized.usage?.outputTokens == 850)
        #expect(normalized.usage?.cacheReadInputTokens == 30000)
        #expect(normalized.usage?.contextTokens == 42000)
        #expect(normalized.usage?.contextWindow == 200000)

        let reduced = reduceChatBlocks([normalized], agentState: nil)
        let latest = try #require(reduced.latestUsage)
        #expect(latest.contextSize == 42000)
        #expect(latest.contextWindow == 200000)
        #expect(latest.inputTokens == 12000)
        #expect(latest.outputTokens == 850)
        #expect(latest.cacheRead == 30000)
    }

    // MARK: - 2. /v1/sessions/{id}/stream decoding & LiveStreamOverlay reconciliation

    @Test("SessionStreamEvent decodes connected, thinking_delta, text_delta, turn_done, error, and unknown")
    func sessionStreamEventDecoding() throws {
        let samples: [(String, SessionStreamEvent)] = [
            (#"{"type":"connected"}"#, .connected),
            (#"{"type":"thinking_delta","turnId":"t1","segmentId":"seg-1","delta":"plan..."}"#,
             .thinkingDelta(turnId: "t1", segmentId: "seg-1", delta: "plan...")),
            (#"{"type":"text_delta","turnId":"t1","segmentId":"seg-2","delta":"Hello"}"#,
             .textDelta(turnId: "t1", segmentId: "seg-2", delta: "Hello")),
            (#"{"type":"turn_done","turnId":"t1","aborted":false}"#,
             .turnDone(turnId: "t1", aborted: false)),
            (#"{"type":"error","turnId":"t1","message":"lagged","resync":true}"#,
             .error(turnId: "t1", message: "lagged", resync: true)),
            (#"{"type":"tool_use","id":"call-1"}"#, .other(type: "tool_use")),
        ]
        for (raw, expected) in samples {
            let decoded = try HapiJSON.decoder.decode(SessionStreamEvent.self, from: Data(raw.utf8))
            #expect(decoded == expected)
        }
    }

    @Test("LiveStreamOverlay accumulates deltas, suppresses Phase A streaming duplicate, and hands off on seal / turn_done")
    func liveStreamOverlayReconciliation() throws {
        var overlay = LiveStreamOverlay()
        let c0 = overlay.apply(.connected, now: 1000)
        #expect(c0)
        let c1 = overlay.apply(.event(.thinkingDelta(turnId: "t1", segmentId: "seg-1", delta: "Think ")), now: 1001)
        #expect(c1)
        let c2 = overlay.apply(.event(.thinkingDelta(turnId: "t1", segmentId: "seg-1", delta: "step")), now: 1002)
        #expect(c2)
        let c3 = overlay.apply(.event(.textDelta(turnId: "t1", segmentId: "seg-2", delta: "Hello ")), now: 1003)
        #expect(c3)
        let c4 = overlay.apply(.event(.textDelta(turnId: "t1", segmentId: "seg-2", delta: "world")), now: 1004)
        #expect(c4)

        // Phase A streaming upsert for seg-2 arrives with shorter prefix -> suppressed (no duplicate bubble!)
        let streamingRow = try makeStoredRow(
            id: "msg-seg-2",
            seq: 5,
            text: "Hello",
            meta: ["streaming": .bool(true), "segmentId": .string("seg-2")]
        )
        let projected = overlay.applying(to: [streamingRow])
        // Expect 2 synthetic stream rows (seg-1 thinking, seg-2 text) and 0 duplicate msg-seg-2
        #expect(projected.count == 2)
        #expect(projected.contains { $0.id == "msg-seg-2" } == false)
        #expect(projected.last?.id == "stream:t1:seg-2")

        // Sealed message for seg-2 lands -> overlay drops seg-2 cleanly, leaving sealed row + seg-1
        let sealedRow = try makeStoredRow(
            id: "msg-seg-2",
            seq: 5,
            text: "Hello world",
            meta: ["segmentId": .string("seg-2")]
        )
        let reconciled = overlay.reconcile(with: [sealedRow])
        #expect(reconciled)
        let afterSeal = overlay.applying(to: [sealedRow])
        #expect(afterSeal.count == 2)
        #expect(afterSeal.contains { $0.id == "msg-seg-2" })
        #expect(afterSeal.contains { $0.id == "stream:t1:seg-2" } == false)

        // Late delta for already-sealed seg-2 is ignored
        let lateDelta = overlay.apply(.event(.textDelta(turnId: "t1", segmentId: "seg-2", delta: "!")), now: 1005)
        #expect(lateDelta == false)

        // turn_done clears remaining segments for t1
        let doneChanged = overlay.apply(.event(.turnDone(turnId: "t1", aborted: false)), now: 1006)
        #expect(doneChanged)
        #expect(overlay.hasActiveContent == false)
        #expect(overlay.applying(to: [sealedRow]).count == 1)
    }

    @Test("LiveStreamOverlay protects mid-turn pre-existing segments from fast bursts while streaming new segments at 60fps")
    func liveStreamOverlayMidTurnPreExistingProtection() throws {
        let shortPrefix = "First 50 chars already streamed before join..."
        let preExistingRow = try makeStoredRow(
            id: "msg-mid",
            seq: 8,
            text: shortPrefix,
            meta: ["streaming": .bool(true), "segmentId": .string("seg-mid")]
        )

        var overlay = LiveStreamOverlay()
        let connected = overlay.apply(.connected, now: 2000, persistedMessages: [preExistingRow])
        #expect(connected)
        // Duplicate wire connected frame must not clear preExistingStreamingSegmentIds.
        let dupConnected = overlay.apply(.event(.connected), now: 2001, persistedMessages: [preExistingRow])
        #expect(dupConnected == false)
        #expect(overlay.preExistingStreamingSegmentIds.contains("seg-mid"))

        // Fast streaming burst exceeding the 46-char Phase A prefix inside an 800ms interval must be ignored.
        let burst = String(repeating: "B", count: 120)
        let burstApplied = overlay.apply(.event(.textDelta(turnId: "t1", segmentId: "seg-mid", delta: burst)), now: 2002)
        #expect(burstApplied == false)
        #expect(overlay.segments.isEmpty)

        // Newly opened segment in the same turn streams at 60fps without disturbing preExistingRow.
        let newSegApplied = overlay.apply(.event(.textDelta(turnId: "t1", segmentId: "seg-new", delta: "Fresh 60fps")), now: 2003)
        #expect(newSegApplied)
        let newSegmentPhaseA = try makeStoredRow(
            id: "msg-new",
            seq: 9,
            text: "Fresh",
            meta: ["streaming": .bool(true), "segmentId": .string("seg-new")]
        )
        let projected = overlay.applying(to: [preExistingRow, newSegmentPhaseA])
        #expect(projected.count == 2)
        #expect(projected.contains { $0.id == "msg-mid" })
        #expect(projected.contains { $0.id == "msg-new" } == false)
        #expect(projected.contains { $0.id == "stream:t1:seg-new" })

        // Sealing seg-mid clears it from preExistingStreamingSegmentIds.
        let sealedMid = try makeStoredRow(
            id: "msg-mid",
            seq: 8,
            text: shortPrefix + burst,
            meta: ["segmentId": .string("seg-mid")]
        )
        _ = overlay.reconcile(with: [sealedMid, newSegmentPhaseA])
        #expect(overlay.preExistingStreamingSegmentIds.contains("seg-mid") == false)

        // turn_done clears remaining segments and any remaining pre-existing tracking.
        let doneChanged = overlay.apply(.event(.turnDone(turnId: "t1", aborted: false)), now: 2010)
        #expect(doneChanged)
        #expect(overlay.preExistingStreamingSegmentIds.isEmpty)
        #expect(overlay.hasActiveContent == false)
    }

    @Test("LiveStreamOverlay protects 3000-char mid-turn Phase A prefix when stream connects before initial window arrives")
    func liveStreamOverlayColdOpenMidTurnProtection() throws {
        var overlay = LiveStreamOverlay()
        let connected = overlay.apply(.connected, now: 3000, persistedMessages: [])
        #expect(connected)
        let firstDelta = overlay.apply(.event(.textDelta(turnId: "t2", segmentId: "seg-cold", delta: "x")), now: 3001)
        #expect(firstDelta)

        let phaseA3000 = try makeStoredRow(
            id: "msg-cold",
            seq: 20,
            text: String(repeating: "Z", count: 3000),
            meta: ["streaming": .bool(true), "segmentId": .string("seg-cold")]
        )

        // Reconciling initial window promotes seg-cold to preExistingStreamingSegmentIds and drops the 1-char tail.
        let reconciled = overlay.reconcile(with: [phaseA3000])
        #expect(reconciled)
        #expect(overlay.preExistingStreamingSegmentIds.contains("seg-cold"))
        #expect(overlay.segments.isEmpty)

        // Even a subsequent 5000-char burst stays ignored so Phase A remains authoritative until seal.
        let bigBurst = String(repeating: "Y", count: 5000)
        let burstApplied = overlay.apply(.event(.textDelta(turnId: "t2", segmentId: "seg-cold", delta: bigBurst)), now: 3002)
        #expect(burstApplied == false)
        let projected = overlay.applying(to: [phaseA3000])
        #expect(projected.count == 1)
        #expect(projected.first?.id == "msg-cold")
    }

    // MARK: - 3. Queue / Steer / Cancel / Retry wire shapes

    @Test("QueuedStateResponse decodes dispatchingLocalIds and SyncEvent decodes Phase B queue events")
    func queueAndSteerWireContracts() throws {
        let qsJson = """
        {
          "queuedLocalIds": ["l-1"],
          "indeterminateLocalIds": ["l-2"],
          "dispatchingLocalIds": ["l-3"],
          "invokedLocalMessages": [{"localId": "l-0", "invokedAt": 1730000005000}]
        }
        """
        let qs = try HapiJSON.decoder.decode(QueuedStateResponse.self, from: Data(qsJson.utf8))
        #expect(qs.queuedLocalIds == ["l-1"])
        #expect(qs.indeterminateLocalIds == ["l-2"])
        #expect(qs.dispatchingLocalIds == ["l-3"])
        #expect(qs.invokedLocalMessages == [InvokedLocalMessage(localId: "l-0", invokedAt: 1730000005000)])

        let consumedJson = """
        {"type":"messages_consumed","session_id":"s1","local_ids":["l-1"],"invoked_at":1730000009000,"steered":true}
        """
        let consumed = try HapiJSON.decoder.decode(SyncEvent.self, from: Data(consumedJson.utf8))
        #expect(consumed == .messagesConsumed(namespace: nil, sessionId: "s1", localIds: ["l-1"], invokedAt: 1730000009000))

        let indetJson = """
        {"type":"messages_indeterminate","session_id":"s1","local_ids":["l-2"],"dispatching":true}
        """
        let indet = try HapiJSON.decoder.decode(SyncEvent.self, from: Data(indetJson.utf8))
        #expect(indet == .messagesIndeterminate(namespace: nil, sessionId: "s1", localIds: ["l-2"]))

        let steerResp = try HapiJSON.decoder.decode(
            SteerQueuedMessageResponse.self,
            from: Data(#"{"status":"steered","localId":"l-1"}"#.utf8)
        )
        #expect(steerResp == .steered(localId: "l-1"))

        let cancelResp = try HapiJSON.decoder.decode(
            CancelMessageResponse.self,
            from: Data(#"{"status":"cancelled","localId":"l-1"}"#.utf8)
        )
        #expect(cancelResp == .cancelled(localId: "l-1"))

        let retryResp = try HapiJSON.decoder.decode(
            RetryIndeterminateMessageResponse.self,
            from: Data(#"{"status":"retried","localId":"l-2"}"#.utf8)
        )
        #expect(retryResp.status == "retried")
        #expect(retryResp.localId == "l-2")
    }

    // MARK: - 4. SessionStreamClient end-to-end with mock SSETransport

    @Test("SessionStreamClient connects with Bearer auth to /v1/sessions/{id}/stream and streams events")
    func sessionStreamClientStreamsWithBearerAuth() async throws {
        let transport = MockStreamTransport(chunks: [
            "data: {\"type\":\"connected\"}\n\n",
            "data: {\"type\":\"text_delta\",\"turnId\":\"t9\",\"segmentId\":\"s9\",\"delta\":\"Hi\"}\n\n",
            "data: {\"type\":\"turn_done\",\"turnId\":\"t9\",\"aborted\":false}\n\n",
        ])
        let client = SessionStreamClient(
            baseURL: URL(string: "https://hub.example")!,
            sessionId: "sess-42",
            tokenProvider: { _ in "jwt-abc" },
            transport: transport
        )
        let stream = await client.start()
        var received: [SessionStreamClientEvent] = []
        for await event in stream {
            received.append(event)
            if case .event(.turnDone) = event {
                await client.stop()
                break
            }
        }
        let req = try #require(await transport.lastRequest())
        #expect(req.url?.absoluteString == "https://hub.example/v1/sessions/sess-42/stream")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-abc")
        #expect(received.contains(.connected))
        #expect(received.contains(.event(.textDelta(turnId: "t9", segmentId: "s9", delta: "Hi"))))
        #expect(received.contains(.event(.turnDone(turnId: "t9", aborted: false))))
    }

    // MARK: - Helpers

    private func makeStoredRow(id: String, seq: Int, text: String, meta: [String: JSONValue]) throws -> WindowMessage {
        let payload: JSONValue = .object([
            "id": .string(id),
            "seq": .number(Double(seq)),
            "role": .string("assistant"),
            "created_at": .number(1730000001000),
            "blocks": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "meta": .object(meta),
        ])
        let data = try HapiJSON.encoder.encode(payload)
        let wire = try HapiJSON.decoder.decode(DecryptedMessage.self, from: data)
        return WindowMessage(wire: wire)
    }
}

private actor MockStreamTransport: SSETransport {
    private let chunks: [String]
    private var captured: URLRequest?

    init(chunks: [String]) {
        self.chunks = chunks
    }

    func lastRequest() -> URLRequest? { captured }

    nonisolated func connect(_ request: URLRequest) -> AsyncThrowingStream<SSETransportEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(request)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
                continuation.yield(.connected(response))
                for chunk in self.chunks {
                    continuation.yield(.bytes(Data(chunk.utf8)))
                }
                continuation.finish()
            }
        }
    }

    private func record(_ request: URLRequest) {
        captured = request
    }
}
