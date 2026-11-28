import HapiClient
import HapiProtocol
import HapiUI
import SwiftUI

// MARK: - User bubble

/// Operator prompt: right-aligned bubble. Whitespace is preserved and the
/// text is NOT rendered as markdown — matching the web user bubble and the
/// Android port. Image attachments with a `previewUrl` render as thumbnails
/// (decoded off-main; also covers web-sent attachments), everything else as
/// filename chips (`AttachmentPreviewView`, A-M3f); a failed optimistic row
/// gets a "Not delivered" hint that retries the send when the interaction
/// engine is present (A-M3a).
struct UserTextBlockView: View {
    let block: UserTextBlock
    var isHighlighted: Bool = false
    private let preview: MessageTextPage

    @Environment(\.chatInteractions) private var interactions
    @Environment(\.hapiTypography) private var typography
    @Environment(\.hapiTheme) private var theme
    @Environment(\.openTextSelection) private var openTextSelection
    @Environment(\.hapiPasteboard) private var pasteboard
    @Environment(\.openChatMessage) private var openMessage

    init(block: UserTextBlock, isHighlighted: Bool = false) {
        self.block = block
        self.isHighlighted = isHighlighted
        preview = .preview(block.text)
    }

    private var bubbleShape: UnevenRoundedRectangle {
        .rect(
            topLeadingRadius: 16,
            bottomLeadingRadius: 16,
            bottomTrailingRadius: 4,
            topTrailingRadius: 16
        )
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 2) {
                VStack(alignment: .leading, spacing: 8) {
                    if !block.text.isEmpty {
                        #if targetEnvironment(macCatalyst)
                        if preview.end == block.text.endIndex {
                            MacSelectableText(
                                content: .plain(
                                    preview.text,
                                    size: typography.bodySize,
                                    weight: typography.boldText ? .semibold : .regular,
                                    monospaced: false,
                                    foregroundColor: UIColor(theme.textPrimary),
                                    lineSpacing: typography.bodyLineSpacing
                                ),
                                wraps: true,
                                fillsWidth: false
                            )
                        } else {
                            Text(verbatim: preview.text)
                                .font(typography.bodyFont)
                                .lineSpacing(typography.bodyLineSpacing)
                                .lineLimit(MessageTextPage.previewLines)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        #else
                        if let localId = block.localId, interactions?.voiceMessageLocalIds.contains(localId) == true {
                            VoiceParticleText(text: preview.text)
                                .lineLimit(preview.end < block.text.endIndex ? MessageTextPage.previewLines : nil)
                                .foregroundStyle(theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(verbatim: preview.text)
                                .font(typography.bodyFont)
                                .lineSpacing(typography.bodyLineSpacing)
                                .lineLimit(preview.end < block.text.endIndex ? MessageTextPage.previewLines : nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        #endif
                        if preview.end < block.text.endIndex {
                            Button { openMessage?(block) } label: {
                                Label("View full message", systemImage: "doc.text")
                                    .font(.footnote)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("message-full-\(block.id)")
                        }
                    }
                    if let localId = block.localId, interactions?.recognizingVoiceLocalId == localId {
                        Text("Recognizing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("voice-message-recognizing")
                    }
                    if let attachments = block.attachments, !attachments.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(attachments, id: \.id) { attachment in
                                AttachmentPreviewView(attachment: attachment)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    Color.accentColor.opacity(isHighlighted ? 0.28 : 0.16),
                    in: bubbleShape
                )
                .overlay {
                    if isHighlighted {
                        bubbleShape
                            .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
                    }
                }
                .shadow(
                    color: isHighlighted ? Color.accentColor.opacity(0.22) : .clear,
                    radius: 8,
                    y: 2
                )
                .animation(.easeInOut(duration: 0.25), value: isHighlighted)
                .contextMenu {
                    if !block.text.isEmpty {
                        Button("Select Text", systemImage: "text.cursor") {
                            openTextSelection?(block.id, block.text)
                        }
                        Button("Copy Message", systemImage: "doc.on.doc") {
                            pasteboard.copy(block.text)
                        }
                    }
                }
                if block.status == "failed" {
                    if let interactions, let retryLocalId = block.localId {
                        Button {
                            interactions.retryFailedMessage(localId: retryLocalId)
                        } label: {
                            Text("Not delivered — tap to retry")
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .padding(.trailing, 4)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("Not delivered")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .padding(.trailing, 4)
                    }
                }
            }
        }
    }
}

// MARK: - Agent prose

/// Assistant prose: full-width markdown through the shared M2e renderer.
struct AgentTextBlockView: View {
    @Environment(\.isAssistantMode) private var assistant
    let block: AgentTextBlock
    var isHighlighted: Bool = false
    @Environment(\.openTextSelection) private var openTextSelection
    @Environment(\.hapiPasteboard) private var pasteboard
    @Environment(\.hapiTheme) private var theme
    @State private var copied = false

    var body: some View {
        let extracted = assistant ? SceneDraftParser.extract(from: block.text) : SceneDraftParser.Extraction(markdown: block.text, drafts: [])
        VStack(alignment: .leading, spacing: 8) {
            if !extracted.markdown.isEmpty || extracted.drafts.isEmpty {
                CachedMarkdownView(markdown: extracted.markdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if assistant && !extracted.drafts.isEmpty {
                ForEach(extracted.drafts) { draft in
                    SceneDraftCardView(draft: draft)
                }
            }
            #if !targetEnvironment(macCatalyst)
            if assistant {
                HStack {
                    Spacer()
                    Button {
                        pasteboard.copy(block.text)
                        withAnimation(.snappy(duration: 0.2)) { copied = true }
                        Task {
                            try? await Task.sleep(for: .milliseconds(1500))
                            withAnimation(.snappy(duration: 0.2)) { copied = false }
                        }
                    } label: {
                        Label(copied ? "已复制" : "复制结论", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(copied ? AssistantDesign.accent : AssistantDesign.inkSecondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(copied ? AssistantDesign.accentSoft : AssistantDesign.surfaceMuted, in: Capsule())
                    }
                    .buttonStyle(AssistantPressStyle(scale: 0.95))
                    .sensoryFeedback(.selection, trigger: copied)
                }
                .padding(.top, 4)
            }
            #endif
            #if targetEnvironment(macCatalyst)
            HStack {
                Spacer(minLength: 0)
                Button {
                    pasteboard.copy(block.text)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(1500))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.caption2)
                    .foregroundStyle(copied ? theme.success : theme.textSecondary.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .help("Copy full message")
                .accessibilityLabel(copied ? "Copied" : "Copy message")
            }
            #endif
        }
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.07))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
            }
        }
        .overlay(alignment: .leading) {
            if isHighlighted {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, -2)
                    .offset(x: -8)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isHighlighted)
        .contextMenu {
            Button("Select Text", systemImage: "text.cursor") {
                openTextSelection?(block.id, block.text)
            }
            Button("Copy Message", systemImage: "doc.on.doc") {
                pasteboard.copy(block.text)
            }
        }
    }
}

/// Extended thinking: streams open while active, collapses to a subdued
/// single-line summary once superseded, and expands in place on tap.
struct AgentReasoningBlockView: View {
    @Environment(\.executionDetailsHidden) private var executionDetailsHidden
    let block: AgentReasoningBlock
    let isStreaming: Bool
    @ChatStoredState private var expandedOverride: Bool?

    init(block: AgentReasoningBlock, isStreaming: Bool = false) {
        self.block = block
        self.isStreaming = isStreaming
        _expandedOverride = ChatStoredState(wrappedValue: nil, id: block.id, field: "expanded")
    }

    private var isExpanded: Bool {
        expandedOverride ?? isStreaming
    }

    private var headerTitle: String {
        if isExpanded {
            return String(localized: "Reasoning")
        }
        if let summary = Self.summaryLine(for: block.text) {
            return "\(String(localized: "Reasoning")) · \(summary)"
        }
        return isStreaming ? String(localized: "Reasoning…") : String(localized: "Reasoning")
    }

    static func summaryLine(for text: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            while let first = line.first, "#*_>-`".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                line.removeSubrange(match)
            }
            line = line
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                return line
            }
        }
        return nil
    }

    var body: some View {
        if executionDetailsHidden {
            HStack(spacing: 8) {
                AssistantPulseDot(color: AssistantDesign.accent, size: 5)
                Text("正在检索与核验资料…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .accessibilityIdentifier("assistant.progress")
        } else { developerBody }
    }

    private var developerBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedOverride = !isExpanded
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    Text(headerTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                CachedMarkdownView(markdown: block.text)
                    .opacity(0.75)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expandedOverride = false
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Event rows

/// Compact centered status row for the `'event'` family (limits, compaction,
/// switches, errors, turn duration, …); wording via `eventPresentation`.
struct AgentEventBlockView: View {
    @Environment(\.chatInteractions) private var interactions
    @Environment(\.isAssistantMode) private var isAssistantMode
    let block: AgentEventBlock
    @ChatStoredState private var expanded: Bool
    @ChatStoredState private var continued: Bool

    init(block: AgentEventBlock) {
        self.block = block
        _expanded = ChatStoredState(wrappedValue: false, id: block.id, field: "expanded")
        _continued = ChatStoredState(wrappedValue: false, id: block.id, field: "continued")
    }

    var body: some View {
        if block.event.type == "thinking-only" {
            ThinkingOnlyEventRow(
                id: block.id,
                event: block.event,
                isAssistantMode: isAssistantMode,
                interactions: interactions,
                continued: $continued
            )
        } else if let compact = compactionPresentation(block.event), compact.hasSummary || compact.tokenDelta != nil {
            CompactionSummaryCard(id: block.id, presentation: compact, expanded: $expanded)
        } else {
            let presentation = eventPresentation(block.event)
            Text([presentation.icon, presentation.text].compactMap { $0 }.joined(separator: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 2)
        }
    }
}

private struct ThinkingOnlyEventRow: View {
    let id: String
    let event: AgentEvent
    let isAssistantMode: Bool
    let interactions: ChatInteractor?
    @Binding var continued: Bool

    private var labelText: String {
        if isAssistantMode {
            return "本次分析已完成，但未生成正文"
        }
        return eventPresentation(event).text
    }

    private var canContinue: Bool {
        guard let interactions, !continued else { return false }
        return !interactions.isSending
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(labelText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if interactions != nil {
                Button {
                    continued = true
                    interactions?.sendQuickMessage("请继续，直接输出最终回复。")
                } label: {
                    Text(continued ? "已继续" : "继续输出")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canContinue)
                .accessibilityIdentifier("thinking-only-continue-\(id)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("thinking-only-card-\(id)")
    }
}

struct CompactionSummaryCard: View {
    let id: String
    let presentation: CompactionPresentation
    @Binding var expanded: Bool

    private var header: some View {
        HStack {
            Text(verbatim: "📦 \(presentation.title)")
                .fixedSize(horizontal: false, vertical: true)
            if presentation.hasSummary {
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .accessibilityHidden(true)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "📦 \(presentation.title)"))
        .accessibilityIdentifier("compaction-header-\(id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if presentation.hasSummary {
                Button { expanded.toggle() } label: { header.frame(minHeight: 44) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("compaction-toggle-\(id)")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            } else {
                header
            }
            if presentation.hasSummary && expanded {
                CachedMarkdownView(markdown: presentation.summary)
                    .accessibilityIdentifier("compaction-summary-\(id)")
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.2)))
    }
}

// MARK: - CLI output

/// `<local-command-stdout>` / slash-command echo: terminal-styled monospace
/// panel (no header chrome — this is transcript, not a code sample).
struct CliOutputBlockView: View {
    let block: CliOutputBlock

    var body: some View {
        TerminalTextView(text: block.text)
    }
}

/// Shared terminal-look panel (cli output + tool stdout).
struct TerminalTextView: View {
    let text: String
    var isError = false

    @Environment(\.hapiTheme) private var theme
    @Environment(\.hapiTypography) private var typography

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            #if targetEnvironment(macCatalyst)
            MacSelectableText(
                content: .plain(
                    text,
                    size: typography.codeSize,
                    weight: typography.boldText ? .semibold : .regular,
                    monospaced: true,
                    foregroundColor: UIColor(isError ? theme.danger : theme.textPrimary),
                    lineSpacing: typography.codeLineSpacing
                ),
                wraps: false,
                fillsWidth: false
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            #else
            Text(text)
                .font(typography.codeFont)
                .lineSpacing(typography.codeLineSpacing)
                .foregroundStyle(isError ? AnyShapeStyle(theme.danger) : AnyShapeStyle(theme.textPrimary))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
