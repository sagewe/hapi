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
        let view = SelectableUITextView()
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
        view.wrapsText = wraps
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

        // Fast-path for full-width wrapping blocks (paragraphs, headings, list items):
        // Avoid calling `measureUnwrapped()` on `.infinity` or `nil` probes, which
        // mutates `textContainer.size.width` to 100,000 and invalidates TextKit layout
        // right before the real finite-width measurement.
        guard let proposedWidth = proposal.width, proposedWidth.isFinite else {
            if fillsWidth {
                let fallbackWidth = uiView.bounds.width > 1 ? uiView.bounds.width : 640
                let measured = uiView.measureWrapped(width: fallbackWidth)
                if proposal.width == .infinity {
                    return CGSize(width: 10_000, height: max(1, measured.height))
                }
                return CGSize(width: max(1, fallbackWidth), height: max(1, measured.height))
            }
            let unwrapped = uiView.measureUnwrapped()
            return CGSize(width: max(1, unwrapped.width), height: max(1, unwrapped.height))
        }

        let measured = uiView.measureWrapped(width: proposedWidth)
        let width = fillsWidth ? proposedWidth : min(proposedWidth, measured.width)
        return CGSize(width: max(1, width), height: max(1, measured.height))
    }

    public final class SelectableUITextView: UITextView {
        private struct WrappedMeasurement {
            var widthKey: Int = -1
            var size: CGSize = .zero
        }

        private let backingTextStorage: NSTextStorage
        var lastContent: Content?
        var lastLinkColor: UIColor?
        var wrapsText: Bool = true
        private var cachedUnwrappedSize: CGSize?
        private var primaryWrappedCache = WrappedMeasurement()
        private var secondaryWrappedCache = WrappedMeasurement()

        public init() {
            let storage = NSTextStorage()
            let manager = NSLayoutManager()
            storage.addLayoutManager(manager)
            let container = NSTextContainer(size: CGSize(width: 10_000, height: 100_000))
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            manager.addTextContainer(container)
            self.backingTextStorage = storage
            super.init(frame: .zero, textContainer: container)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        public override func layoutSubviews() {
            if wrapsText, bounds.width > 1, abs(textContainer.size.width - bounds.width) > 0.5 {
                textContainer.size = CGSize(width: bounds.width, height: 100_000)
            }
            super.layoutSubviews()
        }

        func clearSizeCache() {
            cachedUnwrappedSize = nil
            primaryWrappedCache = WrappedMeasurement()
            secondaryWrappedCache = WrappedMeasurement()
        }

        func measureUnwrapped() -> CGSize {
            if let cached = cachedUnwrappedSize { return cached }
            guard attributedText.length > 0 else {
                let empty = CGSize(width: 1, height: 1)
                cachedUnwrappedSize = empty
                return empty
            }
            let maxDimension: CGFloat = 100_000
            if abs(textContainer.size.width - maxDimension) > 0.5 {
                textContainer.size = CGSize(width: maxDimension, height: maxDimension)
            }
            layoutManager.ensureLayout(for: textContainer)
            let raw = layoutManager.usedRect(for: textContainer).size
            let size = CGSize(width: ceil(raw.width), height: ceil(raw.height))
            cachedUnwrappedSize = size
            return size
        }

        func measureWrapped(width: CGFloat) -> CGSize {
            let key = Int((width * 2).rounded())
            if primaryWrappedCache.widthKey == key { return primaryWrappedCache.size }
            if secondaryWrappedCache.widthKey == key { return secondaryWrappedCache.size }
            guard attributedText.length > 0 else {
                let empty = CGSize(width: 1, height: 1)
                secondaryWrappedCache = primaryWrappedCache
                primaryWrappedCache = WrappedMeasurement(widthKey: key, size: empty)
                return empty
            }
            let maxDimension: CGFloat = 100_000
            if abs(textContainer.size.width - width) > 0.5 {
                textContainer.size = CGSize(width: width, height: maxDimension)
            }
            layoutManager.ensureLayout(for: textContainer)
            let raw = layoutManager.usedRect(for: textContainer).size
            let size = CGSize(width: ceil(raw.width), height: ceil(raw.height))
            secondaryWrappedCache = primaryWrappedCache
            primaryWrappedCache = WrappedMeasurement(widthKey: key, size: size)
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
