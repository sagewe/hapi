import HapiProtocol
import HapiUI
import SwiftUI

/// Inline disclosures are separate transcript rows. No row contains the whole
/// expanding process, so a new height cannot reposition its existing header.
struct InlineExecutionGroupView: View {
    let presentation: ToolGroupPresentation
    let model: ChatModel
    let basePath: String?
    var body: some View {
        ToolGroupBlockView(presentation: presentation,
            isExpanded: model.isInlineExecutionGroupExpanded(presentation.id),
            toggleInline: { model.toggleInlineExecutionGroup(presentation.id) })
    }
}

struct InlineExecutionSectionView: View {
    let groupID: String
    let section: ExecutionDetailSection
    let expanded: Bool
    let model: ChatModel
    @Environment(\.hapiTheme) private var theme
    var body: some View {
        Button { model.toggleInlineExecutionMembers(groupID, field: "inlineSections", ids: section.blocks.map(\.id)) } label: {
            HStack(spacing: 8) {
                let count = section.blocks.compactMap(\.asToolCall).count
                Text(count == 0 ? String(localized: "Viewed images") : String(format: String(localized: "%lld tool calls"), Int64(count)))
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
            }
            .font(.caption).foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(section.id)
    }
}

struct InlineExecutionToolRow: View {
    let groupID: String
    let tool: ToolCallBlock
    let expanded: Bool
    let model: ChatModel
    let basePath: String?
    var body: some View {
        ToolSummaryRow(presentation: toolSummaryPresentation(tool.tool, basePath: basePath),
            state: tool.tool.state, isExpanded: expanded) {
                model.toggleInlineExecutionMembers(groupID, field: "inlineTools", ids: [tool.id])
            }
            .accessibilityIdentifier("inline-tool-\(tool.id)")
    }
}

struct InlineExecutionToolBody: View {
    let tool: ToolCallBlock
    let basePath: String?
    @Environment(\.hapiTheme) private var theme
    @Environment(\.openChatTool) private var openTool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView { ToolCallBody(tool: tool.tool, basePath: basePath).padding(12) }
                .frame(maxHeight: 320)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("inline-tool-body-\(tool.id)")
            Button("View full details") { openTool?(tool) }.font(.caption).frame(minHeight: 44)
        }
    }
}
