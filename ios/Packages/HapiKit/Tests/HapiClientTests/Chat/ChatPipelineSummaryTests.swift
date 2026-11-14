import Foundation
import HapiClient
import HapiProtocol
import Testing

@Suite("Chat pipeline legacy summary stripping")
struct ChatPipelineSummaryTests {
    @Test func stripsLegacyInThreadSummaryRowsWhilePreservingUserAndAssistantBlocks() async {
        let pipeline = ChatPipeline()
        let userRow = WindowMessage(
            id: "u1",
            seq: 1,
            localId: "loc-1",
            content: .object([
                "role": .string("user"),
                "content": .object(["type": .string("text"), "text": .string("hapi ios缺少了快速模式")])
            ]),
            createdAt: 1000,
            invokedAt: .number(1000)
        )
        let summaryRow = WindowMessage(
            id: "sum1",
            seq: 2,
            localId: nil,
            content: .object([
                "role": .string("agent"),
                "content": .object([
                    "type": .string("output"),
                    "data": .object([
                        "type": .string("summary"),
                        "summary": .string("Hapi iOS Missing Quick Mode")
                    ])
                ])
            ]),
            createdAt: 4177,
            invokedAt: .number(4177)
        )
        let assistantRow = WindowMessage(
            id: "a1",
            seq: 3,
            localId: nil,
            content: .object([
                "role": .string("agent"),
                "content": .object([
                    "type": .string("output"),
                    "data": .object([
                        "type": .string("assistant"),
                        "uuid": .string("msg-a1"),
                        "message": .object([
                            "content": .array([
                                .object(["type": .string("text"), "text": .string("收到")])
                            ])
                        ])
                    ])
                ])
            ]),
            createdAt: 5000,
            invokedAt: .number(5000)
        )

        let visible = await pipeline.run(
            messages: [userRow, summaryRow, assistantRow],
            agentState: nil,
            hasMoreMessages: false
        )
        let summaryEvents = visible.filter { block in
            if case .block(.agentEvent) = block { return true }
            return false
        }
        #expect(summaryEvents.isEmpty)
        #expect(visible.count == 2)

        let beforeReply = await pipeline.run(
            messages: [userRow, summaryRow],
            agentState: AgentState(controlledByUser: false),
            hasMoreMessages: false
        )
        let completed = await pipeline.executionCompletionEvidence()
        let timings = await pipeline.executionTimingEvidence()
        let projected = buildExecutionProcessBlocks(
            beforeReply,
            completedRounds: completed,
            isRunning: true,
            hasMoreMessages: false,
            roundTimings: timings
        )
        let timerGroups = projected.filter { block in
            if case .toolGroup(let group) = block, group.id.hasPrefix("execution-timer:") { return true }
            return false
        }
        #expect(beforeReply.count == 1)
        #expect(timerGroups.isEmpty)
        #expect(timings["u1"] == .init(startedAt: 1000, endedAt: 1000))
    }

    @Test func hidesToolTitleChangesOnLiveAndCachedHistoryWhilePreservingOtherEvents() async throws {
        struct Fixture: Decodable {
            struct Input: Decodable { let messages: [DecryptedMessage] }
            let input: Input
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../../shared/fixtures/chat/event-title-changed-dedupe.json")
            .standardizedFileURL
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let messages = fixture.input.messages
        let reduced = reduceChatBlocks(messages.compactMap(normalizeDecryptedMessage), agentState: nil)
        #expect(reduced.blocks.contains { block in
            if case .agentEvent(let event) = block { return event.event.kind == .titleChanged }
            return false
        })
        let rows = messages.map { wire in
            WindowMessage(id: wire.id, seq: wire.seq, localId: wire.localId,
                          content: wire.content, createdAt: wire.createdAt,
                          invokedAt: wire.invokedAt.map(InvokedAtField.number) ?? .absent)
        }
        let pipeline = ChatPipeline()
        let visible = await pipeline.run(messages: rows, agentState: nil, hasMoreMessages: false)
        #expect(visible.count == 2)
        #expect(visible.contains { block in
            if case .block(.agentEvent(let event)) = block { return event.event.kind == .message }
            return false
        })
        #expect(!visible.contains { block in
            if case .block(.agentEvent(let event)) = block { return event.event.kind == .titleChanged }
            return false
        })
        let cached = await pipeline.run(messages: rows, agentState: nil, hasMoreMessages: false)
        #expect(cached == visible)
    }
}
