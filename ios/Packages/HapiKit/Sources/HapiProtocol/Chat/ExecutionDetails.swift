import Foundation

public struct ExecutionDetailSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var blocks: [ChatBlock]
    public var isTools: Bool
}

public func executionDetailSections(_ blocks: [ChatBlock]) -> [ExecutionDetailSection] {
    var result: [ExecutionDetailSection] = []
    var pending: [ChatBlock] = []
    func flush() {
        if let first = pending.first { result.append(.init(id: "execution-detail:\(first.id)", blocks: pending, isTools: true)) }
        pending = []
    }
    for block in blocks {
        let activity: Bool
        switch block {
        case .toolCall: activity = true
        case .generatedImage(let image): activity = image.source?.ingress == .toolResult && image.source?.toolName == "view_image"
        default: activity = false
        }
        if activity { pending.append(block) }
        else { flush(); result.append(.init(id: block.id, blocks: [block], isTools: false)) }
    }
    flush()
    return result
}
