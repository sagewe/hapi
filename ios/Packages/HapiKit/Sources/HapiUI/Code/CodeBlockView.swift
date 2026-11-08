import Foundation
import SwiftUI

private final class CodeHighlightMemoryCache: @unchecked Sendable {
    static let shared = CodeHighlightMemoryCache()
    private let lock = NSLock()
    private var entries: [String: (value: AttributedString, tick: Int)] = [:]
    private var clock = 0
    private let maxEntries = 256

    func get(_ key: String) -> AttributedString? {
        lock.withLock {
            guard var hit = entries[key] else { return nil }
            clock &+= 1
            hit.tick = clock
            entries[key] = hit
            return hit.value
        }
    }

    func set(_ value: AttributedString, forKey key: String) {
        lock.withLock {
            clock &+= 1
            entries[key] = (value, clock)
            if entries.count > maxEntries,
               let oldest = entries.min(by: { $0.value.tick < $1.value.tick })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
    }
}

/// Fenced code block: rounded container with a header (language chip + copy
/// button) and horizontally scrollable monospaced body. Highlighting runs off
/// the main thread through the injected `SyntaxHighlighting` engine and is
/// applied when ready; until then (or when the engine declines) the code
/// renders as plain text.
///
/// Math fences and unsupported languages fall back to this view. On iOS,
/// Mermaid fences are dispatched to MermaidDiagramView by MarkdownBlockView.
public struct CodeBlockView: View {
    public let language: String?
    public let code: String

    @Environment(\.hapiTheme) private var theme
    @Environment(\.hapiTypography) private var typography
    @Environment(\.hapiSyntaxHighlighter) private var highlighter
    @Environment(\.hapiPasteboard) private var pasteboard

    @State private var highlighted: AttributedString?
    @State private var showCopied = false

    public init(language: String?, code: String) {
        self.language = language
        self.code = code
    }

    private var displayLanguage: String {
        guard let language, !language.isEmpty else { return "text" }
        return language.lowercased()
    }

    /// Recompute highlighting when content or palette changes.
    private var highlightID: String {
        "\(displayLanguage)|\(theme.isDark ? "d" : "l")|\(code.count)|\(code.hashValue)"
    }

    public var body: some View {
        let currentHighlighted = highlighted ?? CodeHighlightMemoryCache.shared.get(highlightID)
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                #if targetEnvironment(macCatalyst)
                MacSelectableText(
                    content: .code(
                        highlighted: currentHighlighted,
                        fallbackCode: code,
                        size: typography.codeSize,
                        weight: typography.boldText ? .semibold : .regular,
                        defaultColor: .init(theme.textPrimary),
                        lineSpacing: typography.codeLineSpacing
                    ),
                    wraps: false,
                    fillsWidth: false
                )
                .padding(12)
                #else
                Text(currentHighlighted ?? AttributedString(code))
                    .font(typography.codeFont)
                    .lineSpacing(typography.codeLineSpacing)
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(12)
                #endif
            }
        }
        .background(theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: highlightID) {
            if let cached = CodeHighlightMemoryCache.shared.get(highlightID) {
                if highlighted != cached { highlighted = cached }
                return
            }
            if let result = await highlighter.highlightAsync(
                code,
                language: language,
                dark: theme.isDark
            ) {
                CodeHighlightMemoryCache.shared.set(result, forKey: highlightID)
                highlighted = result
            } else {
                highlighted = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(displayLanguage)
                .font(typography.captionMonoFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button {
                // Explicit MainActor hop: keeps the @MainActor pasteboard
                // call valid regardless of the SDK's Button-action isolation.
                let pasteboard = pasteboard
                let code = code
                Task { @MainActor in
                    pasteboard.copy(code)
                    showCopied = true
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    showCopied = false
                }
            } label: {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                    .font(typography.captionFont)
                    .frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(showCopied ? theme.success : theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(showCopied ? "Copied" : "Copy code"))
        }
        .padding(.horizontal, 12)
        .background(theme.codeHeaderBackground)
    }
}
