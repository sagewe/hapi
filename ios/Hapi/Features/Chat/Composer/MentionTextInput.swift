import SwiftUI
import UIKit
import HapiClient
import HapiProtocol

/// A narrow UIKit bridge: SwiftUI's iOS 17 multiline TextField does not expose
/// caret/marked-text state. Keep the keyboard and IME's text storage intact.
struct MentionTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var composing: Bool
    @Binding var focused: Bool
    var font: UIFont

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "composer.text-input"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.synchronize(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(max(font.lineHeight, height), font.lineHeight * 6))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MentionTextInput
        var updating = false
        init(_ parent: MentionTextInput) { self.parent = parent }
        func synchronize(_ view: UITextView) {
            updating = true
            defer { updating = false }
            view.font = parent.font
            view.textColor = .label
            // Delegate echoes leave marked text untouched. A genuinely external
            // edit (send clearing, draft restore, dictation) must still apply.
            if view.text != parent.text {
                view.unmarkText()
                view.text = parent.text
            }
            if view.markedTextRange == nil {
                let length = (view.text as NSString).length
                let start = min(parent.selection.location, length)
                let safe = NSRange(location: start, length: min(parent.selection.length, length - start))
                if view.selectedRange != safe { view.selectedRange = safe }
            }
            if parent.focused && !view.isFirstResponder { view.becomeFirstResponder() }
            if !parent.focused && view.isFirstResponder { view.resignFirstResponder() }
        }

        func textViewDidChange(_ view: UITextView) {
            guard !updating else { return }
            parent.composing = view.markedTextRange != nil
            parent.selection = view.selectedRange
            parent.text = view.text
            view.invalidateIntrinsicContentSize()
        }
        func textViewDidChangeSelection(_ view: UITextView) {
            guard !updating else { return }
            parent.composing = view.markedTextRange != nil
            parent.selection = view.selectedRange
        }
        func textViewDidBeginEditing(_ view: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ view: UITextView) {
            parent.composing = false
            parent.focused = false
        }
    }
}

struct SessionMentionList: View {
    let sessions: [HapiProtocol.SessionSummary]
    let surface: Color
    let machineLabels: [String: String]
    let select: (HapiProtocol.SessionSummary) -> Void

    var body: some View {
        Group {
            if sessions.count > 4 {
                ScrollView { rows }.frame(height: 220)
            } else {
                rows
            }
        }
        .background(surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("composer.session-mentions")
    }

    private var rows: some View {
            VStack(spacing: 0) {
                ForEach(sessions, id: \.id) { session in
                    Button { select(session) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("@" + HapiClient.SessionListSearch.sessionTitle(session))
                                .lineLimit(1)
                            HStack {
                                Text(String(session.id.prefix(8)))
                                if session.active { Text("Active") }
                                if let id = session.metadata?.machineId {
                                    Text(machineLabels[id] ?? String(id.prefix(8))).lineLimit(1)
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("composer.session-mention.\(session.id)")
                }
            }
    }
}
