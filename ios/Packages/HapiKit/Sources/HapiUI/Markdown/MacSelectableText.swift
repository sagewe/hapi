#if canImport(UIKit)
import SwiftUI
import UIKit

private extension Notification.Name {
    static let hapiClearOtherTextSelections = Notification.Name("hapi.clearOtherTextSelections")
}

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
            selectedText = nsText.substring(with: range)
            activeView = textView
        } else if activeView === textView {
            selectedText = nil
            activeView = nil
        }
    }

    public func clear() {
        selectedText = nil
        activeView = nil
    }
}

/// Read-only selectable `UITextView` for Mac Catalyst so mouse pointer I-beam
/// drag-selection, double/triple-click selection, and ⌘C work natively inside
/// chat transcripts, code blocks, and user bubbles.
public struct MacSelectableText: UIViewRepresentable {
    public let attributedText: NSAttributedString
    public var wraps: Bool
    public var fillsWidth: Bool
    public var linkColor: UIColor?
    public var onOpenURL: ((URL) -> Void)?

    public init(
        attributedText: NSAttributedString,
        wraps: Bool = true,
        fillsWidth: Bool = true,
        linkColor: UIColor? = nil,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.attributedText = attributedText
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
        return view
    }

    public func updateUIView(_ view: SelectableUITextView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        view.textContainer.widthTracksTextView = wraps
        if !wraps {
            view.textContainer.size = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        if let linkColor {
            view.linkTextAttributes = [
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        }
        if !view.attributedText.isEqual(to: attributedText) {
            view.attributedText = attributedText
            view.invalidateIntrinsicContentSize()
        }
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: SelectableUITextView,
        context: Context
    ) -> CGSize? {
        if !wraps {
            let measured = uiView.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            )
            return CGSize(width: ceil(measured.width), height: ceil(measured.height))
        }
        let proposedWidth = proposal.width ?? .greatestFiniteMagnitude
        let targetWidth = (proposedWidth > 0 && proposedWidth.isFinite)
            ? proposedWidth
            : .greatestFiniteMagnitude
        let measured = uiView.sizeThatFits(
            CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        let width: CGFloat
        if targetWidth.isFinite {
            width = fillsWidth ? targetWidth : min(targetWidth, ceil(measured.width))
        } else {
            width = ceil(measured.width)
        }
        return CGSize(width: max(1, width), height: max(1, ceil(measured.height)))
    }

    public final class SelectableUITextView: UITextView {
        public override var canBecomeFirstResponder: Bool { true }

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleClearOtherSelections(_:)),
                name: .hapiClearOtherTextSelections,
                object: nil
            )
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func handleClearOtherSelections(_ notification: Notification) {
            guard notification.object as AnyObject !== self else { return }
            if selectedRange.length > 0 {
                selectedRange = NSRange(location: 0, length: 0)
            }
        }
    }

    public final class Coordinator: NSObject, UITextViewDelegate {
        var onOpenURL: ((URL) -> Void)?

        init(onOpenURL: ((URL) -> Void)?) {
            self.onOpenURL = onOpenURL
        }

        public func textViewDidChangeSelection(_ textView: UITextView) {
            MacTextSelectionTracker.shared.updateSelection(from: textView)
            if textView.selectedRange.length > 0 {
                if !textView.isFirstResponder {
                    textView.becomeFirstResponder()
                }
                NotificationCenter.default.post(name: .hapiClearOtherTextSelections, object: textView)
            }
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
