import Foundation

public func executionRoundTimings(_ messages: [NormalizedMessage]) -> [String: ExecutionProcessTiming] {
    var result: [String: ExecutionProcessTiming] = [:]
    var round = "initial"
    for message in messages where !message.isSidechain {
        switch message.content {
        case .user:
            round = message.id
            if let start = message.invokedAt { result[round] = .init(startedAt: start, endedAt: start) }
        case .agent(let content) where content.contains(where: {
            if case .toolResult = $0 { return false }
            if case .generatedImage(let image) = $0, image.source?.ingress == .toolResult, image.source?.toolName == "view_image" { return false }
            return true
        }):
            let prior = result[round]
            result[round] = .init(startedAt: prior?.startedAt ?? message.createdAt,
                endedAt: max(prior?.endedAt ?? message.createdAt, message.createdAt))
        case .event(let event) where event.type == "ready" && (event.object["agentId"] == nil || event.object["agentId"] == .null || event.object["agentId"] == .string("")):
            if var prior = result[round] { prior.endedAt = max(prior.endedAt, message.createdAt); result[round] = prior }
        default: break
        }
    }
    return result
}

/// Provider-neutral outer presentation; canonical messages remain untouched.
public func completedExecutionRounds(_ messages: [NormalizedMessage]) -> Set<String> {
    var completed = Set<String>()
    var round = "initial"
    for message in messages where !message.isSidechain {
        switch message.content {
        case .user: round = message.id
        case .event(let event) where event.type == "ready" && (event.object["agentId"] == nil || event.object["agentId"] == .null || event.object["agentId"] == .string("")):
            completed.insert(round)
        case .agent(let content) where !content.isEmpty: completed.remove(round)
        default: break
        }
    }
    return completed
}

private func isProtectedExecutionTool(_ block: ToolCallBlock) -> Bool {
    var handled = false
    if let permission = block.tool.permission, permission.reason?.isEmpty != false {
        switch permission.status {
        case .approved, .resolved, .canceled: handled = true
        default: break
        }
    }
    if isInteractiveToolBlock(block) && !handled { return true }
    let name = block.tool.name.lowercased().filter { $0.isLetter || $0.isNumber }
    if ["exitplanmode", "cursorcreateplan"].contains(name) { return true }
    if getInputStringAny(block.tool.input, ["command_source", "commandSource"])?.lowercased() == "usershell" { return true }
    return block.children.contains { child in
        if case .toolCall(let tool) = child { return isProtectedExecutionTool(tool) }
        if case .agentEvent(let event) = child { return ["error", "limit-reached"].contains(event.event.type) }
        return false
    }
}

private func canFoldExecutionBlock(_ block: ChatBlock) -> Bool {
    switch block {
    case .agentText(let text): return text.meta?["assistantPhase"]?.stringValue != "final"
    case .agentReasoning: return true
    case .generatedImage(let image): return image.source?.ingress == .toolResult && image.source?.toolName == "view_image"
    case .toolCall(let tool): return !isProtectedExecutionTool(tool)
    default: return false
    }
}

public func buildExecutionProcessBlocks(
    _ visible: [VisibleChatBlock], completedRounds: Set<String>, isRunning: Bool,
    hasMoreMessages: Bool, roundTimings: [String: ExecutionProcessTiming] = [:], keepVisibleIds: Set<String> = [], previousGroups: [ToolGroupBlock] = []
) -> [VisibleChatBlock] {
    let blocks: [ChatBlock] = visible.flatMap { block in
        switch block {
        case .block(let value): return [value]
        case .toolGroup(let group): return group.processBlocks ?? group.tools.map { .toolCall($0) }
        }
    }
    var output: [VisibleChatBlock] = []
    var used = Set<String>()
    let rawIDs = Set(blocks.map(\.id))
    let reserved = rawIDs.union(previousGroups.map(\.id))
    var previousByMember: [String: Int] = [:]
    for (index, group) in previousGroups.enumerated() {
        for member in group.processBlocks ?? [] where previousByMember[member.id] == nil { previousByMember[member.id] = index }
    }
    var roundID = "initial"
    var round: [ChatBlock] = []
    func flush(tail: Bool) {
        guard !round.isEmpty else { return }
        let completed = completedRounds.contains(roundID) && !(tail && isRunning)
        let roundStartIndex = output.count
        let timestamps = round.flatMap { block -> [Int] in
            if case .toolCall(let tool) = block { return [block.createdAt, tool.tool.completedAt ?? block.createdAt] }
            return [block.createdAt]
        }
        let observed = roundTimings[roundID]
        var timing = ExecutionProcessTiming(
            startedAt: hasMoreMessages && roundID == "initial" ? nil : observed?.startedAt ?? timestamps.min(),
            endedAt: observed?.endedAt ?? timestamps.max() ?? 0, running: tail && isRunning)
        let lastWork = round.lastIndex { block in
            switch block { case .toolCall, .agentReasoning: return true; default: return false }
        } ?? -1
        let replies = Set(round.enumerated().compactMap { index, block -> String? in
            guard index > lastWork, case .agentText(let text) = block,
                  text.meta?["assistantPhase"]?.stringValue != "progress" else { return nil }
            return text.id
        })
        if replies.isEmpty { timing.endedAt = max(timing.endedAt, timestamps.max() ?? timing.endedAt) }
        var decisionContext = Set<String>()
        for (index, block) in round.enumerated() {
            guard case .toolCall(let tool) = block, isInteractiveToolBlock(tool), isProtectedExecutionTool(tool) else { continue }
            var cursor = index - 1
            scan: while cursor >= 0 {
                switch round[cursor] {
                case .toolCall, .userText, .cliOutput: break scan
                case .agentText(let text): decisionContext.insert(text.id)
                default: break
                }
                cursor -= 1
            }
        }
        // Match Web: tool activity must not evict the latest explanation.
        var explanation = Set<String>()
        let hasFinal = round.contains { block in
            if case .agentText(let text) = block { return text.meta?["assistantPhase"]?.stringValue == "final" }
            return false
        }
        if !completed && !hasFinal, let lastExplanation = round.lastIndex(where: { block in
            switch block { case .agentText, .agentReasoning: return true; default: return false }
        }) {
            var cursor = lastExplanation
            scan: while cursor >= 0 {
                switch round[cursor] {
                case .agentText, .agentReasoning: explanation.insert(round[cursor].id)
                case .agentEvent: break
                default: break scan
                }
                cursor -= 1
            }
        }
        let latest = round.last { if case .agentEvent = $0 { return false }; return true }?.id
        var members: [ChatBlock] = []
        func emit() {
            guard let first = members.first, let last = members.last else { return }
            let previous = members.lazy.compactMap { previousByMember[$0.id] }.map { previousGroups[$0] }
                .first { !used.contains($0.id) && !rawIDs.contains($0.id) }
            let base = "execution-process:\(first.id)"
            var id = previous?.id ?? base
            if previous == nil {
                var suffix = 2
                while used.contains(id) || reserved.contains(id) {
                    id = "\(base)#\(suffix)"
                    suffix += 1
                }
            }
            used.insert(id)
            let tools = members.compactMap(\.asToolCall)
            let partial = hasMoreMessages && roundID == "initial"
            var group = ToolGroupBlock(id: id, createdAt: first.createdAt, invokedAt: first.invokedAt,
                firstToolId: first.id, lastToolId: last.id, tools: tools, defaultOpen: false,
                historyState: partial ? .needsOlderHistory : .complete, needsOlderHistory: partial,
                activityTitle: nil, presentationMode: .default, summary: summarizeToolGroup(tools))
            group.processBlocks = members
            group.processTiming = timing
            output.append(.toolGroup(group))
            members = []
        }
        var insertionIndex: Int?
        for block in round {
            if !canFoldExecutionBlock(block) || replies.contains(block.id) || explanation.contains(block.id) || decisionContext.contains(block.id) || keepVisibleIds.contains(block.id)
                || ((!completed || replies.isEmpty) && block.id == latest && block.asToolCall == nil && block.kind != "generated-image") {
                output.append(.block(block))
            } else {
                if insertionIndex == nil { insertionIndex = output.count }
                members.append(block)
            }
        }
        emit()
        if insertionIndex != nil {
            let group = output.removeLast()
            output.insert(group, at: roundStartIndex)
        }
        round = []
    }
    for block in blocks {
        let boundary: Bool
        switch block {
        case .userText: boundary = true
        case .cliOutput(let value): boundary = value.source == .user
        default: boundary = false
        }
        if boundary {
            flush(tail: false)
            roundID = block.id
            output.append(.block(block))
        } else { round.append(block) }
    }
    flush(tail: true)
    return output
}
