import Foundation

public enum InitialResponseState: String, Equatable, Sendable {
    case sending, waiting, thinking
}

/// Ephemeral transcript feedback, not a message in canonical history.
public func initialResponseState(
    _ blocks: [VisibleChatBlock], isSending: Bool, isRunning: Bool, isActive: Bool,
    activeTurnStartedAt: Int? = nil, completedRounds: Set<String> = [],
    isHistory: Bool = false, isHydrating: Bool = false
) -> InitialResponseState? {
    if isHistory { return nil }
    if isSending { return .sending }
    if !isActive || isHydrating { return nil }
    let flat = blocks.flatMap { block -> [ChatBlock] in
        switch block {
        case .block(let value): return [value]
        case .toolGroup(let group): return group.processBlocks ?? group.tools.map { .toolCall($0) }
        }
    }
    let userIndex = flat.lastIndex { if case .userText = $0 { return true }; return false } ?? -1
    var user: UserTextBlock?
    if userIndex >= 0, case .userText(let value) = flat[userIndex] { user = value }
    let belongsToRun = user.map { activeTurnStartedAt == nil || ($0.invokedAt ?? $0.createdAt) >= activeTurnStartedAt! } ?? false
    if user?.status == "failed" && (!isRunning || belongsToRun) { return nil }
    let hasOutput = flat.dropFirst(userIndex + 1).contains { block in
        switch block {
        case .agentEvent, .userText: return false
        case .agentText(let text) where text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: return false
        case .agentReasoning(let text) where text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: return false
        default: return !isRunning || activeTurnStartedAt == nil || (block.invokedAt ?? block.createdAt) >= activeTurnStartedAt!
        }
    }
    if hasOutput { return nil }
    if isRunning { return belongsToRun && user?.invokedAt != nil ? .thinking : .waiting }
    guard let user, user.invokedAt == nil, !completedRounds.contains(user.id) else { return nil }
    if user.status == "sending" { return .sending }
    if user.localId != nil && (user.status == "sent" || user.status == "queued") { return .waiting }
    return nil
}
