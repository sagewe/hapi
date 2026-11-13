import HapiUI
import SwiftUI
import UIKit

/// A snapshot outside recycled transcript rows, with continuous native selection.
struct MessageTextSelectionView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hapiPasteboard) private var pasteboard

    var body: some View {
        NavigationStack {
            MessageSelectionTextView(text: text)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Copy full content", systemImage: "doc.on.doc") { pasteboard.copy(text) }
                            .accessibilityIdentifier("message-selection-copy-full")
                    }
                }
        }
        .hapiTypography()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

struct MessageSelectionTextView: UIViewRepresentable {
    let text: String
    @Environment(\.hapiTypography) private var typography
    @Environment(\.hapiTheme) private var theme

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 20, bottom: 24, right: 20)
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityIdentifier = "message-selection-text"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = typography.bodyLineSpacing
        let content = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: typography.bodySize, weight: typography.boldText ? .semibold : .regular),
            .foregroundColor: UIColor(theme.textPrimary),
            .paragraphStyle: paragraph,
        ])
        // Repeated SwiftUI updates must not reset handles or scroll position.
        guard !view.attributedText.isEqual(to: content) else { return }
        let selection = view.selectedRange
        let offset = view.contentOffset
        view.attributedText = content
        if NSMaxRange(selection) <= content.length { view.selectedRange = selection }
        view.setContentOffset(offset, animated: false)
    }
}
