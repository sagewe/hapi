import HapiUI
import SwiftUI
import UIKit

/// ⌘K Command Palette for rapidly fuzzy-searching and switching sessions by
/// title, project path, or machine name with keyboard navigation (↑/↓/↩/Esc).
struct QuickSwitchSheet: View {
    let model: SessionListModel
    let currentSessionId: String?
    let onSelect: (String) -> Void
    var onNewSession: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hapiTheme) private var theme
    @State private var query = ""
    @State private var selectedIndex = 0

    var body: some View {
        let candidates = model.quickSwitchCandidates(query: query)
        let clampedIndex = candidates.isEmpty
            ? 0
            : min(max(0, selectedIndex), candidates.count - 1)

        VStack(spacing: 0) {
            searchBar(
                candidates: candidates,
                clampedIndex: clampedIndex
            )
            Divider()
            if candidates.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                                candidateRow(
                                    candidate,
                                    isSelected: index == clampedIndex,
                                    isCurrent: candidate.id == currentSessionId
                                ) {
                                    select(candidate.id)
                                }
                                .id(candidate.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: clampedIndex) { _, newIndex in
                        guard candidates.indices.contains(newIndex) else { return }
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(candidates[newIndex].id, anchor: .center)
                        }
                    }
                }
            }
            Divider()
            footerBar
        }
        .background(theme.background)
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
    }

    private func searchBar(
        candidates: [SessionListModel.QuickSwitchCandidate],
        clampedIndex: Int
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            QuickSwitchSearchField(
                text: $query,
                placeholder: String(localized: "Switch to session, project, or machine…"),
                onMove: { delta in
                    guard !candidates.isEmpty else { return }
                    selectedIndex = (clampedIndex + delta + candidates.count) % candidates.count
                },
                onSubmit: {
                    guard candidates.indices.contains(clampedIndex) else { return }
                    select(candidates[clampedIndex].id)
                },
                onEscape: {
                    dismiss()
                }
            )
            .frame(height: 28)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func candidateRow(
        _ candidate: SessionListModel.QuickSwitchCandidate,
        isSelected: Bool,
        isCurrent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let row = candidate.row
        return Button(action: action) {
            HStack(spacing: 10) {
                AgentFlavorIconView(flavor: row.flavor, size: 22)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: row.title)
                            .font(.body.weight(row.unread ? .semibold : .regular))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        if isCurrent {
                            Text("Current")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .foregroundStyle(Color.accentColor)
                        }
                        if candidate.isArchived {
                            Text("Archived")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if let status = row.status {
                            Text(LocalizedStringKey(status.titleKey))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(status == .running ? theme.success : theme.warning)
                        }
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(verbatim: formatRelativeAge(now: context.date, thenEpochMs: row.summary.updatedAt))
                        }
                        .font(.caption)
                        .foregroundStyle(row.unread ? theme.accent : theme.textSecondary)
                        .monospacedDigit()
                    }
                    HStack(spacing: 6) {
                        if let machine = candidate.machineLabel {
                            Text(verbatim: machine)
                                .font(.caption)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                        if let path = candidate.path {
                            Text(verbatim: path)
                                .font(.caption)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if !row.tags.isEmpty {
                            ForEach(Array(row.tags.prefix(3)), id: \.self) { tag in
                                Text(verbatim: "#\(tag)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(theme.accent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footerBar: some View {
        HStack(spacing: 16) {
            Label("↑↓ Navigate", systemImage: "arrow.up.arrow.down")
            Label("↩ Open", systemImage: "return")
            Label("esc Dismiss", systemImage: "escape")
            Spacer()
            if let onNewSession {
                Button {
                    dismiss()
                    onNewSession()
                } label: {
                    Label("New Session (⌘N)", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func select(_ sessionId: String) {
        dismiss()
        onSelect(sessionId)
    }
}

private struct QuickSwitchSearchField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> KeyHandlingTextField {
        let field = KeyHandlingTextField()
        field.placeholder = placeholder
        field.borderStyle = .none
        field.clearButtonMode = .never
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .go
        field.font = .preferredFont(forTextStyle: .body)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.onMove = onMove
        field.onSubmit = onSubmit
        field.onEscape = onEscape
        DispatchQueue.main.async {
            field.becomeFirstResponder()
        }
        return field
    }

    func updateUIView(_ uiView: KeyHandlingTextField, context: Context) {
        context.coordinator.parent = self
        uiView.onMove = onMove
        uiView.onSubmit = onSubmit
        uiView.onEscape = onEscape
        if uiView.markedTextRange == nil, uiView.text != text {
            uiView.text = text
        }
    }

    final class KeyHandlingTextField: UITextField {
        var onMove: ((Int) -> Void)?
        var onSubmit: (() -> Void)?
        var onEscape: (() -> Void)?

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard markedTextRange == nil, let key = presses.first?.key else {
                super.pressesBegan(presses, with: event)
                return
            }
            let modifiers = key.modifierFlags.intersection([.shift, .command, .alternate, .control])
            switch key.keyCode {
            case .keyboardUpArrow where modifiers.isEmpty:
                onMove?(-1)
                return
            case .keyboardDownArrow where modifiers.isEmpty:
                onMove?(1)
                return
            case .keyboardReturnOrEnter, .keypadEnter:
                if modifiers.isEmpty || modifiers == .command {
                    onSubmit?()
                    return
                }
            case .keyboardEscape where modifiers.isEmpty:
                onEscape?()
                return
            default:
                break
            }
            super.pressesBegan(presses, with: event)
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: QuickSwitchSearchField

        init(_ parent: QuickSwitchSearchField) {
            self.parent = parent
        }

        @objc func textChanged(_ sender: UITextField) {
            guard sender.markedTextRange == nil else { return }
            let next = sender.text ?? ""
            if parent.text != next {
                parent.text = next
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}
