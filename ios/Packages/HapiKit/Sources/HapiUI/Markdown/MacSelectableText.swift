#if canImport(UIKit)
import SwiftUI
import UIKit

/// Tracks the most recent non-empty text selection inside any `MacSelectableText`
/// so `⌘C` works reliably even when `ComposerTextView` holds first responder.
@MainActor
public final class MacTextSelectionTracker {
    public static let shared = MacTextSelectionTracker()
    public private(set) var selectedText: String?
    weak var activeView: UITextView?

    private init() {}

    func updateSelection(from textView: UITextView) {
        let range = textView.selectedRange
        if range.length > 0,
           let nsText = textView.text as NSString?,
           range.location + range.length <= nsText.length {
            if let previous = activeView, previous !== textView, previous.selectedRange.length > 0 {
                previous.selectedRange = NSRange(location: 0, length: 0)
            }
            selectedText = nsText.substring(with: range)
            activeView = textView
        } else if activeView === textView {
            selectedText = nil
            activeView = nil
        }
    }

    public func clear() {
        if let previous = activeView, previous.selectedRange.length > 0 {
            previous.selectedRange = NSRange(location: 0, length: 0)
        }
        selectedText = nil
        activeView = nil
    }
}

/// Read-only selectable `UITextView` for Mac Catalyst so mouse pointer I-beam
/// drag-selection, double/triple-click selection, and ⌘C work natively inside
/// chat transcripts, code blocks, and user bubbles without redundant TextKit work.
public struct MacSelectableText: UIViewRepresentable {
    public enum Content: Equatable {
        case markdown(
            AttributedString,
            baseSize: CGFloat,
            baseWeight: UIFont.Weight,
            lineSpacing: CGFloat,
            theme: HapiTheme,
            typography: HapiTypography
        )
        case plain(
            String,
            size: CGFloat,
            weight: UIFont.Weight,
            monospaced: Bool,
            foregroundColor: UIColor,
            lineSpacing: CGFloat
        )
        case code(
            highlighted: AttributedString?,
            fallbackCode: String,
            size: CGFloat,
            weight: UIFont.Weight,
            defaultColor: UIColor,
            lineSpacing: CGFloat
        )

        @MainActor
        func buildAttributedString() -> NSAttributedString {
            switch self {
            case let .markdown(source, baseSize, baseWeight, lineSpacing, theme, typography):
                return MacSelectableText.markdownAttributedString(
                    source,
                    baseSize: baseSize,
                    baseWeight: baseWeight,
                    lineSpacing: lineSpacing,
                    theme: theme,
                    typography: typography
                )
            case let .plain(text, size, weight, monospaced, foregroundColor, lineSpacing):
                return MacSelectableText.plainAttributedString(
                    text,
                    size: size,
                    weight: weight,
                    monospaced: monospaced,
                    foregroundColor: foregroundColor,
                    lineSpacing: lineSpacing
                )
            case let .code(highlighted, fallbackCode, size, weight, defaultColor, lineSpacing):
                return MacSelectableText.codeAttributedString(
                    highlighted: highlighted,
                    fallbackCode: fallbackCode,
                    size: size,
                    weight: weight,
                    defaultColor: defaultColor,
                    lineSpacing: lineSpacing
                )
            }
        }
    }

    public let content: Content
    public var wraps: Bool
    public var fillsWidth: Bool
    public var linkColor: UIColor?
    public var onOpenURL: ((URL) -> Void)?

    public init(
        content: Content,
        wraps: Bool = true,
        fillsWidth: Bool = true,
        linkColor: UIColor? = nil,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.content = content
        self.wraps = wraps
        self.fillsWidth = fillsWidth
        self.linkColor = linkColor
        self.onOpenURL = onOpenURL
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onOpenURL: onOpenURL)
    }

    public func makeUIView(context: Context) -> SelectableUITextView {
        let view = SelectableUITextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.contentInset = .zero
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.delegate = context.coordinator
        applyConfiguration(to: view, coordinator: context.coordinator)
        return view
    }

    public func updateUIView(_ view: SelectableUITextView, context: Context) {
        applyConfiguration(to: view, coordinator: context.coordinator)
    }

    private func applyConfiguration(to view: SelectableUITextView, coordinator: Coordinator) {
        coordinator.onOpenURL = onOpenURL
        view.textContainer.widthTracksTextView = wraps
        if let linkColor, view.lastLinkColor != linkColor {
            view.lastLinkColor = linkColor
            view.linkTextAttributes = [
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        }
        if view.lastContent != content {
            view.lastContent = content
            view.clearSizeCache()
            view.attributedText = content.buildAttributedString()
            view.invalidateIntrinsicContentSize()
        }
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: SelectableUITextView,
        context: Context
    ) -> CGSize? {
        applyConfiguration(to: uiView, coordinator: context.coordinator)

        if !wraps {
            let unwrapped = uiView.measureUnwrapped()
            return CGSize(width: max(1, unwrapped.width), height: max(1, unwrapped.height))
        }

        // SwiftUI HStack/VStack minimum-width probe: wrapping text can shrink to 0.
        if let proposedWidth = proposal.width, proposedWidth <= 0 {
            return CGSize(width: 0, height: 1)
        }

        // Unspecified (ideal) or .infinity (maximum-width) probe from HStack/VStack:
        // Never pass CGFloat.greatestFiniteMagnitude to UITextView.sizeThatFits, as UIKit
        // falls back to NSTextContainer's default 100pt width when given CGFLOAT_MAX.
        guard let proposedWidth = proposal.width, proposedWidth.isFinite else {
            let unwrapped = uiView.measureUnwrapped()
            if fillsWidth, proposal.width == .infinity {
                return CGSize(width: max(10_000, unwrapped.width), height: max(1, unwrapped.height))
            }
            return CGSize(width: max(1, unwrapped.width), height: max(1, unwrapped.height))
        }

        let measured = uiView.measureWrapped(width: proposedWidth)
        let width = fillsWidth ? proposedWidth : min(proposedWidth, measured.width)
        return CGSize(width: max(1, width), height: max(1, measured.height))
    }

    public final class SelectableUITextView: UITextView {
        var lastContent: Content?
        var lastLinkColor: UIColor?
        private var cachedUnwrappedSize: CGSize?
        private var cachedWrappedSizes: [Int: CGSize] = [:]

        func clearSizeCache() {
            cachedUnwrappedSize = nil
            cachedWrappedSizes.removeAll(keepingCapacity: true)
        }

        func measureUnwrapped() -> CGSize {
            if let cached = cachedUnwrappedSize { return cached }
            guard attributedText.length > 0 else {
                let empty = CGSize(width: 1, height: 1)
                cachedUnwrappedSize = empty
                return empty
            }
            let maxDimension: CGFloat = 100_000
            let previousTracks = textContainer.widthTracksTextView
            let previousWidth = bounds.width > 0 ? bounds.width : textContainer.size.width
            textContainer.widthTracksTextView = false
            textContainer.size = CGSize(width: maxDimension, height: maxDimension)
            layoutManager.ensureLayout(for: textContainer)
            let raw = layoutManager.usedRect(for: textContainer).size
            if previousTracks, previousWidth > 0 {
                textContainer.size = CGSize(width: previousWidth, height: maxDimension)
            }
            textContainer.widthTracksTextView = previousTracks
            let size = CGSize(width: ceil(raw.width), height: ceil(raw.height))
            cachedUnwrappedSize = size
            return size
        }

        func measureWrapped(width: CGFloat) -> CGSize {
            let key = Int((width * 2).rounded())
            if let cached = cachedWrappedSizes[key] { return cached }
            guard attributedText.length > 0 else {
                let empty = CGSize(width: 1, height: 1)
                cachedWrappedSizes[key] = empty
                return empty
            }
            let maxDimension: CGFloat = 100_000
            let previousTracks = textContainer.widthTracksTextView
            textContainer.widthTracksTextView = false
            textContainer.size = CGSize(width: width, height: maxDimension)
            layoutManager.ensureLayout(for: textContainer)
            let raw = layoutManager.usedRect(for: textContainer).size
            textContainer.widthTracksTextView = previousTracks
            let size = CGSize(width: ceil(raw.width), height: ceil(raw.height))
            cachedWrappedSizes[key] = size
            return size
        }
    }

    public final class Coordinator: NSObject, UITextViewDelegate {
        var onOpenURL: ((URL) -> Void)?

        init(onOpenURL: ((URL) -> Void)?) {
            self.onOpenURL = onOpenURL
        }

        public func textViewDidChangeSelection(_ textView: UITextView) {
            MacTextSelectionTracker.shared.updateSelection(from: textView)
        }

        public func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            if case .link(let url) = textItem.content, let onOpenURL {
                return UIAction { _ in onOpenURL(url) }
            }
            return defaultAction
        }
    }

    // MARK: - Attributed string builders

    private static func makeUIFont(
        size: CGFloat,
        weight: UIFont.Weight,
        italic: Bool = false,
        monospaced: Bool = false
    ) -> UIFont {
        let base: UIFont = monospaced
            ? .monospacedSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
        guard italic,
              let descriptor = base.fontDescriptor.withSymbolicTraits(
                  base.fontDescriptor.symbolicTraits.union(.traitItalic)
              ) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    public static func markdownAttributedString(
        _ source: AttributedString,
        baseSize: CGFloat,
        baseWeight: UIFont.Weight,
        lineSpacing: CGFloat,
        theme: HapiTheme,
        typography: HapiTypography
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        let defaultColor = UIColor(theme.textPrimary)
        let linkUIColor = UIColor(theme.link)
        let inlineCodeFG = UIColor(theme.inlineCodeForeground)
        let inlineCodeBG = UIColor(theme.inlineCodeBackground)

        for run in source.runs {
            let text = String(source.characters[run.range])
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [
                .paragraphStyle: paragraphStyle,
            ]
            if intent.contains(.code) {
                attributes[.font] = makeUIFont(
                    size: typography.inlineCodeSize,
                    weight: typography.boldText ? .semibold : .regular,
                    monospaced: true
                )
                attributes[.foregroundColor] = run.link != nil ? linkUIColor : inlineCodeFG
                attributes[.backgroundColor] = inlineCodeBG
            } else {
                let weight: UIFont.Weight = intent.contains(.stronglyEmphasized)
                    ? (typography.boldText ? .bold : .semibold)
                    : baseWeight
                attributes[.font] = makeUIFont(
                    size: baseSize,
                    weight: weight,
                    italic: intent.contains(.emphasized)
                )
                attributes[.foregroundColor] = run.link != nil ? linkUIColor : defaultColor
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let url = run.link {
                attributes[.link] = url
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    public static func plainAttributedString(
        _ text: String,
        size: CGFloat,
        weight: UIFont.Weight = .regular,
        monospaced: Bool = false,
        foregroundColor: UIColor,
        lineSpacing: CGFloat = 0
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: makeUIFont(size: size, weight: weight, monospaced: monospaced),
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraphStyle,
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    public static func codeAttributedString(
        highlighted: AttributedString?,
        fallbackCode: String,
        size: CGFloat,
        weight: UIFont.Weight,
        defaultColor: UIColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        guard let highlighted else {
            return plainAttributedString(
                fallbackCode,
                size: size,
                weight: weight,
                monospaced: true,
                foregroundColor: defaultColor,
                lineSpacing: lineSpacing
            )
        }
        let result = NSMutableAttributedString()
        let font = makeUIFont(size: size, weight: weight, monospaced: true)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing

        for run in highlighted.runs {
            let text = String(highlighted.characters[run.range])
            let color = run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self]
                .map { UIColor($0) } ?? defaultColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle,
            ]
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }
}
#endif
