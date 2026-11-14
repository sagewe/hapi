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
}
