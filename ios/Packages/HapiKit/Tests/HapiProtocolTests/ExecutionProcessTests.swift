import Testing
@testable import HapiProtocol

@Suite("Execution process projection")
struct ExecutionProcessTests {
    private func text(_ id: String, phase: String? = nil) -> ChatBlock {
        .agentText(.init(id: id, localId: nil, createdAt: 1, invokedAt: nil, durationMs: nil,
            usage: nil, model: nil, text: id, meta: phase.map { .object(["assistantPhase": .string($0)]) }))
    }
    private func tool(_ id: String, name: String = "Bash", state: ToolCallState = .completed) -> ChatBlock {
        .toolCall(.init(id: id, localId: nil, createdAt: 1, invokedAt: nil, durationMs: nil,
            usage: nil, model: nil, tool: .init(id: id, name: name, state: state, createdAt: 1), children: [], meta: nil))
    }
    private var user: ChatBlock {
        .userText(.init(id: "u", localId: nil, createdAt: 0, invokedAt: nil, text: "request", attachments: nil,
            status: nil, originalText: nil, meta: nil))
    }
    private func project(_ blocks: [ChatBlock], running: Bool = false, held: Set<String> = [], more: Bool = false,
                         previous: [ToolGroupBlock] = []) -> [VisibleChatBlock] {
        buildExecutionProcessBlocks(blocks.map { .block($0) }, completedRounds: ["u"], isRunning: running,
            hasMoreMessages: more, keepVisibleIds: held, previousGroups: previous)
    }
    private func groups(_ blocks: [VisibleChatBlock]) -> [ToolGroupBlock] {
        blocks.compactMap { if case .toolGroup(let group) = $0, group.processRole != "header" { return group }; return nil }
    }
    @Test(arguments: ["CodexBash", "run_command", "Bash", "Shell"])
    func allProvidersUseTheSamePresentation(_ name: String) {
        let result = project([user, text("progress", phase: "progress"), tool("tool", name: name), text("answer", phase: "final")])
        #expect(result.count == 3)
        #expect(groups(result).first?.processBlocks?.map(\.id) == ["progress", "tool"])
        #expect(result.last?.testID == "answer")
    }
    @Test func concurrentToolsAndFailuresStayInOneProcess() {
        let input = [user, text("progress", phase: "progress"), tool("failed", state: .error),
            tool("parallel-a", state: .running), text("update", phase: "progress"), tool("finished"),
            tool("parallel-b", state: .running), text("answer", phase: "final")]
        let result = project(input, running: true)
        #expect(groups(result).count == 1)
        #expect(groups(result).first?.summary.runningCount == 2)
        #expect(groups(result).first?.summary.errorCount == 1)
        #expect(groups(result).first?.processBlocks?.map(\.id) == Array(input.dropFirst().dropLast()).map(\.id))
    }
    @Test func currentActivityMovesIntoStableProcessAfterFinalAnswer() {
        let input = [user, tool("earlier"), text("progress", phase: "progress"), tool("tool")]
        let before = project(input, running: true)
        #expect(before.contains { $0.testID == "progress" })
        #expect(before.count == 5)
        #expect(groups(before).flatMap { $0.tools.map(\.id) } == ["earlier", "tool"])
        let after = project(input + [text("answer", phase: "final")], previous: groups(before))
        #expect(groups(before).first?.id == groups(after).first?.id)
        #expect(groups(after).first?.processBlocks?.map(\.id) == ["earlier", "progress", "tool"])
    }
    @Test func explanationSurvivesToolsUntilNewExplanationOrAnswer() {
        for phase: String? in ["progress", nil] {
            for state: ToolCallState in [.running, .completed, .error] {
                let steps = [user, text("intro", phase: phase), text("detail", phase: phase),
                    tool("first", state: state), tool("second", state: .running)]
                let live = project(steps, running: true)
                #expect(live.contains { $0.testID == "intro" })
                #expect(live.contains { $0.testID == "detail" })
                let updated = project(steps + [text("update", phase: phase), tool("third")], running: true)
                #expect(updated.contains { $0.testID == "intro" })
                #expect(updated.contains { $0.testID == "detail" })
                #expect(updated.contains { $0.testID == "update" })
                let final = project(steps + [text("answer", phase: "final")], running: true)
                #expect(!final.contains { $0.testID == "intro" || $0.testID == "detail" })
                #expect(final.last?.testID == "answer")
                #expect(groups(final).count == 1)
            }
        }
    }
    @Test func timingUsesRoundSpanAndPartialHistoryHasNoInventedStart() {
        let input = [user, text("progress", phase: "progress"), tool("a", state: .running), tool("b", state: .running)]
        let timed = buildExecutionProcessBlocks(input.map { .block($0) }, completedRounds: [], isRunning: true,
            hasMoreMessages: false, roundTimings: ["u": .init(startedAt: 1000, endedAt: 41000)])
        #expect(timed.count == 4)
        #expect(timed[1].testID == "execution-timer:u")
        if case .toolGroup(let header) = timed[1] {
            #expect(header.processTiming == .init(startedAt: 1000, endedAt: 41000, running: true))
        }
        let partial = project(Array(input.dropFirst()), more: true)
        #expect(groups(partial).first?.processTiming?.startedAt == nil)
        let prompt = NormalizedMessage(id: "u", createdAt: 0, content: .user(text: "request", attachments: nil), invokedAt: 1000)
        let ready = NormalizedMessage(id: "r", createdAt: 41000, content: .event(.init(object: ["type": .string("ready")])))
        #expect(executionRoundTimings([prompt, ready])["u"] == .init(startedAt: 1000, endedAt: 41000))
    }
    @Test func inspectedImagesStayInDetailsWhileExplicitDisplaysRemainVisible() {
        let image = GeneratedImageBlock(id: "image", localId: nil, createdAt: 3, invokedAt: nil,
            imageId: "image", fileName: "input.png", mimeType: "image/png",
            source: .init(ingress: .toolResult, toolName: "view_image"), meta: nil)
        let input = [user, text("progress", phase: "progress"), tool("read")]
        let result = project(input + [.generatedImage(image)], running: true)
        #expect(result.count == 4)
        #expect(result.contains { $0.testID == "progress" })
        #expect(groups(result).first?.processBlocks?.contains(.generatedImage(image)) == true)
        var displayed = image
        displayed.source = .init(ingress: .mcp, toolName: "display_image")
        #expect(project(input + [.generatedImage(displayed)], running: true).contains { $0.testID == "image" })
        displayed.source = nil
        #expect(project(input + [.generatedImage(displayed)], running: true).contains { $0.testID == "image" })
    }
    @Test func liveTimelinePreservesAllProseAndProtectsReadingOnCompletion() {
        let input = [user, text("first", phase: "progress"), tool("a"), text("second", phase: "progress"), tool("b")]
        let live = project(input, running: true)
        #expect(live.map(\.testID) == ["u", "execution-timer:u", "first", "execution-tools:a", "second", "execution-tools:b"])
        let held = project(input + [text("answer", phase: "final")], held: ["first"], previous: groups(live))
        #expect(held.contains { $0.testID == "first" })
        #expect(held.contains { $0.testID == "second" })
        #expect(groups(held).map(\.id) == groups(live).map(\.id))
        let settled = project(input + [text("answer", phase: "final")], previous: groups(live))
        #expect(settled.count == 3)
        #expect(groups(settled).count == 1)
    }
    @Test func exceptionsAndUserReadingRemainVisible() {
        let error = tool("error", state: .error)
        let question = tool("question", name: "request_user_input")
        let plan = tool("plan", name: "ExitPlanMode")
        let result = project([user, text("reading", phase: "progress"), tool("work"), error, question, plan, tool("later-work"), text("answer")], held: ["reading"])
        for id in ["reading", "question", "plan", "answer"] { #expect(result.contains { $0.testID == id }) }
        #expect(groups(result).count == 1)
        #expect(groups(result).first?.tools.map(\.id) == ["work", "error", "later-work"])
    }
    @Test func resolvedQuestionsCanJoinTheProcess() {
        var answered = tool("answered", name: "request_user_input").asToolCall!
        answered.tool.permission = ToolPermission(id: "question", status: .resolved)
        let result = project([user, .toolCall(answered), text("answer")])
        #expect(groups(result).first?.tools.first?.tool.permission?.status == .resolved)
        #expect(!result.contains { $0.testID == "answered" })
    }

    @Test func trailingAnswerParagraphsAreNeverLostWithoutPhaseMetadata() {
        let input = [user, tool("work"), text("part1"), text("part2")]
        for running in [true, false] {
            let result = project(input, running: running)
            #expect(result.contains { $0.testID == "part1" })
            #expect(result.contains { $0.testID == "part2" })
        }
    }
    @Test func paginationAndSplittingKeepStableUniqueIdentities() {
        let first = project([tool("c"), tool("d"), text("answer")], more: true)
        #expect(groups(first).first?.needsOlderHistory == true)
        let grown = project([user, tool("a"), tool("b"), tool("c"), tool("d"), text("answer")], previous: groups(first))
        #expect(groups(grown).first?.id == groups(first).first?.id)
        let split = project([user, tool("a"), tool("b"), tool("error", state: .error), tool("c"), tool("d"), text("answer")], previous: groups(grown))
        #expect(groups(split).count == 1)
        #expect(Set(split.map(\.testID)).count == split.count)
    }
    @Test(arguments: ["progress", "final"])
    func nativePhasesSurviveNormalization(_ phase: String) {
        let wire = DecryptedMessage(id: "phase", seq: 1, content: [
            "role": "agent", "meta": .null, "content": ["type": "codex", "data": [
                "type": "message", "message": "answer", "phase": .string(phase)
            ]]
        ], createdAt: 1)
        #expect(normalizeDecryptedMessage(wire)?.meta?["assistantPhase"] == .string(phase))
    }

    @Test func rootReadyEvidenceDoesNotSurviveNewActivity() {
        let prompt = NormalizedMessage(id: "u", createdAt: 0, content: .user(text: "request", attachments: nil))
        let ready = NormalizedMessage(id: "ready", createdAt: 1, content: .event(.init(object: ["type": .string("ready")])))
        #expect(completedExecutionRounds([prompt, ready]) == ["u"])
        let activity = NormalizedMessage(id: "next", createdAt: 2, content: .agent([.text(.init(text: "next", uuid: "next", parentUUID: nil))]))
        #expect(completedExecutionRounds([prompt, ready, activity]).isEmpty)
    }
}

private extension VisibleChatBlock {
    var testID: String {
        switch self { case .block(let block): return block.id; case .toolGroup(let group): return group.id }
    }
}
