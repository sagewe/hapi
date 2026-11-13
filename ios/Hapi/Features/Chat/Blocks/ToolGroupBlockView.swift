import HapiProtocol
import HapiUI
import SwiftUI

/// Only visible summary fields participate in equality. Streaming a member's
/// result must not reconfigure the group's recycled transcript cell.
struct ToolGroupPresentation: Identifiable, Equatable {
    let id: String
    let activityTitle: String?
    let totalTools: Int
    let countsByKind: [ToolGroupActionKind: Int]
    let runningCount: Int
    let errorCount: Int
    let isExecutionProcess: Bool
    let processTiming: ExecutionProcessTiming?
    let processRole: String?

    init(_ block: ToolGroupBlock) {
        id = block.id
        processTiming = block.processTiming
        processRole = block.processRole
        isExecutionProcess = block.processBlocks != nil
        activityTitle = block.activityTitle
        totalTools = block.summary.totalTools
        countsByKind = block.summary.countsByKind
        runningCount = block.summary.runningCount
        errorCount = block.summary.errorCount
    }

    var title: String {
        if processRole == "tools" && totalTools == 0 { return String(localized: "Viewed images") }
        if isExecutionProcess && processRole != "tools" { return String(localized: "Elapsed time") }
        let title = totalTools == 1 ? String(localized: "1 tool call")
            : String(format: String(localized: "%lld tool calls"), Int64(totalTools))
        return activityTitle.map { "\($0) · \(title)" } ?? title
    }

    var categorySummary: String {
        if isExecutionProcess && processRole != "tools" { return "" }
        let parts = ToolGroupActionKind.allCases.compactMap { kind -> String? in
            let count = countsByKind[kind] ?? 0
            guard count > 0 else { return nil }
            // Interpolated lookups pass the count to the catalog so the Russian
            // plural variations are selected; the explicit singular keys keep
            // the English labels grammatical.
            switch kind {
            case .read:
                return count == 1 ? String(localized: "1 read") : String(localized: "\(count) reads")
            case .search:
                return count == 1 ? String(localized: "1 search") : String(localized: "\(count) searches")
            case .command:
                return count == 1 ? String(localized: "1 command") : String(localized: "\(count) commands")
            case .mutation:
                return count == 1 ? String(localized: "1 edit") : String(localized: "\(count) edits")
            case .web:
                return count == 1 ? String(localized: "1 web request") : String(localized: "\(count) web requests")
            case .other:
                return count == 1 ? String(localized: "1 other tool") : String(localized: "\(count) other tools")
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// A navigation affordance, never an inline disclosure. Resolve the live group
/// by ID when tapped rather than capturing members in the summary row.
struct ToolGroupBlockView: View {
    let presentation: ToolGroupPresentation
    @Environment(\.openChatToolGroup) private var openGroup
    @Environment(\.hapiTheme) private var theme
    @Environment(\.hapiTypography) private var typography

    var body: some View {
        if presentation.processRole == "header" {
            Group {
                if presentation.processTiming?.running == true {
                    TimelineView(.periodic(from: .now, by: 1)) { context in Text(timingLabel(now: context.date)) }
                } else { Text(timingLabel(now: .now)) }
            }
            .font(.caption).foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else if presentation.processRole == "tools" {
            Button { openGroup?(presentation.id) } label: {
                HStack(spacing: 8) {
                    Text(presentation.categorySummary.isEmpty ? presentation.title : presentation.categorySummary)
                    Image(systemName: "chevron.right")
                }
                .font(.caption).foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tool-group-\(presentation.id)")
        } else if presentation.isExecutionProcess {
            Button { openGroup?(presentation.id) } label: {
                Group {
                    if presentation.processTiming?.running == true {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            timingContent(now: context.date)
                        }
                    } else { timingContent(now: .now) }
                }
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tool-group-\(presentation.id)")
        } else { legacyBody }
    }

    private func timingContent(now: Date) -> some View {
        HStack(spacing: 8) {
            Text(timingLabel(now: now))
            Image(systemName: "chevron.right")
        }
    }

    private func timingLabel(now: Date) -> String {
        guard let timing = presentation.processTiming, let start = timing.startedAt else {
            return presentation.processTiming?.running == true ? String(localized: "Running") : String(localized: "Time unavailable")
        }
        let end = timing.running ? Int(now.timeIntervalSince1970 * 1000) : timing.endedAt
        let seconds = max(0, (end - start) / 1000)
        let duration = seconds < 60
            ? String(format: String(localized: "%llds"), Int64(seconds))
            : String(format: String(localized: "%lldm %llds"), Int64(seconds / 60), Int64(seconds % 60))
        return String(format: String(localized: timing.running ? "Running for %@" : "Took %@"), duration)
    }

    private var legacyBody: some View {
        Button { openGroup?(presentation.id) } label: {
            let layout = typography.usesStackedToolLayout
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(typography.toolSubtitleFont)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: typography.toolIconWidth)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(presentation.title)
                            .font(typography.toolTitleFont)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(typography.usesStackedToolLayout ? 2 : 1)
                            .fixedSize(horizontal: false, vertical: true)
                        if !presentation.categorySummary.isEmpty {
                            Text(presentation.categorySummary)
                                .font(typography.toolSubtitleFont)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(typography.usesStackedToolLayout ? 2 : 1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !typography.usesStackedToolLayout { Spacer(minLength: 8) }
                trailingIndicator
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHint("View tool group")
        .accessibilityIdentifier("tool-group-\(presentation.id)")
    }

    private var trailingIndicator: some View {
        HStack(spacing: 8) {
            if presentation.runningCount > 0 {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Running")
            }
            if presentation.errorCount > 0 {
                Label("\(presentation.errorCount)", systemImage: "exclamationmark.circle")
                    .font(typography.toolSubtitleFont).foregroundStyle(.red)
                    .accessibilityLabel(String(format: String(localized: "%lld failed tools"), Int64(presentation.errorCount)))
            }
            Image(systemName: "chevron.right")
                .font(typography.captionFont).foregroundStyle(theme.textSecondary)
        }
    }
}
