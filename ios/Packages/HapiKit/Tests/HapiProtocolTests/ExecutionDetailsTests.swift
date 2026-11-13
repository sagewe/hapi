import Testing
@testable import HapiProtocol
@Suite("Execution detail outline") struct ExecutionDetailsTests {
    @Test func consecutiveToolsStayBetweenTheirOriginalProse() {
        let text = ChatBlock.agentText(.init(id: "text", localId: nil, createdAt: 1, invokedAt: nil,
            durationMs: nil, usage: nil, model: nil, text: "Plan", meta: nil))
        func tool(_ id: String) -> ChatBlock {
            .toolCall(.init(id: id, localId: nil, createdAt: 1, invokedAt: nil, durationMs: nil, usage: nil, model: nil,
                tool: .init(id: id, name: "Bash", state: .completed, createdAt: 1), children: [], meta: nil))
        }
        let blocks = [text, tool("a"), tool("b"), text, tool("c")]
        let sections = executionDetailSections(blocks)
        #expect(sections.map(\.isTools) == [false, true, false, true])
        #expect(sections.flatMap(\.blocks) == blocks)
        #expect(sections[1].id == "execution-detail:a")
    }
}
