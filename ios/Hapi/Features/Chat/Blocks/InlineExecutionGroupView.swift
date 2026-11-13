import HapiProtocol
import HapiUI
import SwiftUI

/// Disclosure state belongs to the chat, not to recycled UIKit cells.
struct InlineExecutionGroupView: View {
    let presentation: ToolGroupPresentation
    let model: ChatModel
    let basePath: String?
    @Environment(\.hapiTheme) private var theme
    @Environment(\.openChatTool) private var openTool

    private func key(_ field: String) -> ChatPresentationState.Key { .init(id: presentation.id, field: field) }
    private var expanded: Bool { model.presentationState.values[key("inlineExpanded")] as? Bool ?? false }
    private func contains(_ field: String, _ id: String) -> Bool {
        (model.presentationState.values[key(field)] as? Set<String> ?? []).contains(id)
    }
    private func toggle(_ field: String, _ id: String) {
        model.beginContentInspection()
        var ids = model.presentationState.values[key(field)] as? Set<String> ?? []
        if !ids.insert(id).inserted { ids.remove(id) }
        model.presentationState.values[key(field)] = ids
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ToolGroupBlockView(presentation: presentation, isExpanded: expanded,
                toggleInline: { model.toggleInlineExecutionGroup(presentation.id) })
            if expanded, let group = model.toolInspection.group(presentation.id) {
                if group.processRole == "tools" {
                    ForEach(group.processBlocks ?? [], id: \.id) { step($0) }
                } else {
                    ForEach(executionDetailSections(group.processBlocks ?? [])) { section in
                        if section.isTools {
                            let open = section.blocks.contains { contains("inlineSections", $0.id) }
                            Button {
                                model.beginContentInspection()
                                var ids = model.presentationState.values[key("inlineSections")] as? Set<String> ?? []
                                for block in section.blocks { if open { ids.remove(block.id) } else { ids.insert(block.id) } }
                                model.presentationState.values[key("inlineSections")] = ids
                            } label: {
                                HStack(spacing: 8) {
                                    let count = section.blocks.compactMap(\.asToolCall).count
                                    Text(count == 0 ? String(localized: "Viewed images") : String(format: String(localized: "%lld tool calls"), Int64(count)))
                                    Image(systemName: open ? "chevron.down" : "chevron.right")
                                }
                                .font(.caption).foregroundStyle(theme.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(section.id)
                            if open { ForEach(section.blocks, id: \.id) { step($0) } }
                        } else { ForEach(section.blocks, id: \.id) { step($0) } }
                    }
                }
            }
        }
    }
    @ViewBuilder private func step(_ block: ChatBlock) -> some View {
        if case .toolCall(let tool) = block {
            let open = contains("inlineTools", tool.id)
            VStack(alignment: .leading, spacing: 8) {
                ToolSummaryRow(presentation: toolSummaryPresentation(tool.tool, basePath: basePath),
                    state: tool.tool.state, isExpanded: open) { toggle("inlineTools", tool.id) }
                    .accessibilityIdentifier("inline-tool-\(tool.id)")
                if open {
                    ScrollView { ToolCallBody(tool: tool.tool, basePath: basePath).padding(12) }
                        .frame(maxHeight: 320)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("inline-tool-body-\(tool.id)")
                    Button("View full details") { openTool?(tool) }
                        .font(.caption).frame(minHeight: 44)
                }
            }
        } else { ChatSubBlockView(block: block, basePath: basePath) }
    }
}
