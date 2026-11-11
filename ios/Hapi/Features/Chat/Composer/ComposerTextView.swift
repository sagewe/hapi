import CoreGraphics
import HapiUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A selection-aware multiline input on every supported iOS version. UIKit
/// owns selection and IME marked text while editing; SwiftUI owns the draft.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var isFocused: Bool
    @Binding var isComposing: Bool
    let font: UIFont
    let accessibilityLabel: String
    /// Mac: a bare Return or ⌘Return submits through this handler (true = consumed);
    /// Shift/Option-Return and IME commits still edit the text.
    var onReturn: (() -> Bool)? = nil
    /// Mac: ⇧⌘Return / ⌥⌘Return submits and steers into the active turn.
    var onSteerReturn: (() -> Bool)? = nil
    /// Mac: ↑ (-1) / ↓ (+1) navigates open suggestion popups (true = consumed).
    var onMoveSuggestion: ((Int) -> Bool)? = nil
    /// Mac: Tab accepts the highlighted suggestion when a popup is open.
    var onTab: (() -> Bool)? = nil
    /// Mac: Escape dismisses an open suggestion popup or unfocuses the field.
    var onEscape: (() -> Bool)? = nil
    /// Pasted images and copied files become attachments instead of text.
    var onPasteItems: (([NSItemProvider]) -> Void)? = nil
    #if !targetEnvironment(macCatalyst)
    /// iOS WeChat-style Hold-to-Dictate: tap focuses to edit, long-press starts streaming voice.
    var holdToDictateEnabled: Bool = false
    var onHoldBegan: ((CGPoint, CGSize) -> Void)? = nil
    var onHoldChanged: ((CGPoint, CGSize) -> Void)? = nil
    var onHoldEnded: (() -> Void)? = nil
    var onHoldCancelled: (() -> Void)? = nil
    #endif

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> NativeTextView {
        let view = NativeTextView()
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.contentInset = .zero
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.ownerCoordinator = context.coordinator
        #if !targetEnvironment(macCatalyst)
        let holdGesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleHoldToDictate(_:))
        )
        holdGesture.minimumPressDuration = 0.26
        holdGesture.allowableMovement = 14
        holdGesture.cancelsTouchesInView = true
        holdGesture.delegate = context.coordinator
        view.addGestureRecognizer(holdGesture)
        context.coordinator.holdToDictateGesture = holdGesture
        #endif
        return view
    }

    func updateUIView(_ view: NativeTextView, context: Context) {
        synchronize(view, coordinator: context.coordinator)
    }

    /// Shared update path for SwiftUI echoes, programmatic edits and IME regression tests.
    func synchronize(_ view: NativeTextView, coordinator: Coordinator) {
        coordinator.owner = self
        coordinator.applying = true
        defer { coordinator.applying = false }
        view.font = font
        view.textColor = .label
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityIdentifier = "composer.text"
        let changedText = view.text != text
        let changedSelection = selection != coordinator.lastBoundSelection
        // Native feedback may reach SwiftUI in the same turn as a prefill.
        // Only an offset different from the live caret is a new edit intent.
        let requestedSelection = changedSelection && selection != view.selectedRange
        coordinator.lastBoundSelection = selection
        // Never reassign ordinary keystrokes: that would discard marked text.
        if changedText { view.text = text }
        let desired = changedText && !requestedSelection
            ? NSRange(location: text.utf16.count, length: 0) : selection
        let start = min(desired.location, text.utf16.count)
        let clamped = NSRange(location: start, length: min(desired.length, text.utf16.count - start))
        if changedText || changedSelection, view.markedTextRange == nil, view.selectedRange != clamped {
            view.selectedRange = clamped
        }
        if changedText {
            // Programmatic prefill/send/mention edits can move the caret. Publish
            // only after updateUIView, and only if no newer edit has overtaken it.
            let expected = text
            DispatchQueue.main.async { [weak view, weak coordinator] in
                guard let view, let coordinator, view.text == expected,
                      coordinator.owner.text == expected else { return }
                coordinator.publishSelection(view)
            }
        }
        view.onReturn = onReturn
        view.onSteerReturn = onSteerReturn
        view.onMoveSuggestion = onMoveSuggestion
        view.onTab = onTab
        view.onEscape = onEscape
        view.onPasteItems = onPasteItems
        view.wantsFocus = isFocused
        view.updateFocus()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NativeTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        #if targetEnvironment(macCatalyst)
        let minimum = ceil(font.lineHeight * 1.75)
        let maximum = ceil(font.lineHeight * 12)
        uiView.showsVerticalScrollIndicator = true
        #else
        let minimum = ceil(font.lineHeight)
        let maximum = ceil(font.lineHeight * 6)
        #endif
        uiView.isScrollEnabled = height > maximum
        return CGSize(width: width, height: min(maximum, max(minimum, height)))
    }

    static func dismantleUIView(_ uiView: NativeTextView, coordinator: Coordinator) {
        uiView.wantsFocus = false
        uiView.delegate = nil
    }

    final class NativeTextView: UITextView {
        var wantsFocus = false
        var onReturn: (() -> Bool)?
        var onSteerReturn: (() -> Bool)?
        var onMoveSuggestion: ((Int) -> Bool)?
        var onTab: (() -> Bool)?
        var onEscape: (() -> Bool)?
        var onPasteItems: (([NSItemProvider]) -> Void)?

        /// Only image-only clipboards and copied files; anything with text
        /// keeps the normal text paste.
        private var pastesAttachments: Bool {
            guard onPasteItems != nil else { return false }
            let board = UIPasteboard.general
            return board.types.contains(UTType.fileURL.identifier) || (board.hasImages && !board.hasStrings)
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)), pastesAttachments { return true }
            if action == #selector(copy(_:)),
               selectedRange.length == 0,
               let selected = MacTextSelectionTracker.shared.selectedText,
               !selected.isEmpty {
                return true
            }
            return super.canPerformAction(action, withSender: sender)
        }

        override func copy(_ sender: Any?) {
            if selectedRange.length == 0,
               let selected = MacTextSelectionTracker.shared.selectedText,
               !selected.isEmpty {
                UIPasteboard.general.string = selected
                return
            }
            super.copy(sender)
        }

        override func paste(_ sender: Any?) {
            if pastesAttachments, let onPasteItems {
                onPasteItems(UIPasteboard.general.itemProviders)
                return
            }
            super.paste(sender)
        }

        func handleMacKeyPress(keyCode: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> Bool {
            guard markedTextRange == nil else { return false }
            let relevantModifiers = modifiers.intersection([.shift, .alternate, .command, .control])
            switch keyCode {
            case .keyboardReturnOrEnter, .keypadEnter:
                let bareReturnSends = ShortcutPrefs.shared.bareReturnSends
                if relevantModifiers == .command || (bareReturnSends && relevantModifiers.isEmpty) {
                    return onReturn?() == true
                }
                if relevantModifiers.isEmpty, onTab?() == true {
                    return true
                }
                if relevantModifiers == [.command, .shift] || relevantModifiers == [.command, .alternate] {
                    return onSteerReturn?() == true
                }
                return false
            case .keyboardUpArrow where relevantModifiers.isEmpty:
                return onMoveSuggestion?(-1) == true
            case .keyboardDownArrow where relevantModifiers.isEmpty:
                return onMoveSuggestion?(1) == true
            case .keyboardTab where relevantModifiers.isEmpty:
                return onTab?() == true
            case .keyboardEscape where relevantModifiers.isEmpty:
                return onEscape?() == true
            default:
                return false
            }
        }

        #if targetEnvironment(macCatalyst)
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if let key = presses.first?.key {
                if ownerCoordinator?.syncBeforeKeyAction(self) == true,
                   handleMacKeyPress(keyCode: key.keyCode, modifiers: key.modifierFlags) {
                    return
                }
            }
            super.pressesBegan(presses, with: event)
        }
        #endif

        weak var ownerCoordinator: Coordinator?

        #if !targetEnvironment(macCatalyst)
        var hitTestOutsets = UIEdgeInsets(top: 12, left: 14, bottom: 4, right: 14)

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            let expanded = bounds.inset(by: UIEdgeInsets(
                top: -hitTestOutsets.top,
                left: -hitTestOutsets.left,
                bottom: -hitTestOutsets.bottom,
                right: -hitTestOutsets.right
            ))
            return expanded.contains(point)
        }
        #endif

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateFocus()
        }

        func updateFocus() {
            guard wantsFocus != isFirstResponder else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if wantsFocus, window != nil, !isFirstResponder { becomeFirstResponder() }
                else if !wantsFocus, isFirstResponder { resignFirstResponder() }
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var owner: ComposerTextView
        var applying = false
        var lastBoundSelection: NSRange
        #if !targetEnvironment(macCatalyst)
        weak var holdToDictateGesture: UILongPressGestureRecognizer?
        #endif

        init(_ owner: ComposerTextView) {
            self.owner = owner
            self.lastBoundSelection = owner.selection
        }

        #if !targetEnvironment(macCatalyst)
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === holdToDictateGesture else { return true }
            guard owner.holdToDictateEnabled,
                  let textView = gestureRecognizer.view as? UITextView,
                  textView.markedTextRange == nil else {
                return false
            }
            // While actively editing non-empty text with the keyboard up, let
            // native cursor loupe / word selection take over; otherwise (unfocused
            // or empty box) long-press starts Hold-to-Dictate.
            if textView.isFirstResponder && !(textView.text ?? "").isEmpty {
                return false
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer === holdToDictateGesture || otherGestureRecognizer === holdToDictateGesture {
                return false
            }
            return false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard gestureRecognizer === holdToDictateGesture else { return false }
            // Yield UITextView's built-in loupe/selection long-press recognizers to
            // Hold-to-Dictate when eligible; normal short taps fail `holdToDictateGesture`
            // immediately on finger-up with zero added latency.
            return otherGestureRecognizer is UILongPressGestureRecognizer
        }

        @objc func handleHoldToDictate(_ gesture: UILongPressGestureRecognizer) {
            let window = gesture.view?.window
            let windowSize = window?.bounds.size ?? CGSize(width: 393, height: 852)
            let location = gesture.location(in: window)
            switch gesture.state {
            case .began:
                if let textView = gesture.view as? NativeTextView, textView.isFirstResponder {
                    textView.wantsFocus = false
                    owner.isFocused = false
                    textView.resignFirstResponder()
                }
                owner.onHoldBegan?(location, windowSize)
            case .changed:
                owner.onHoldChanged?(location, windowSize)
            case .ended:
                owner.onHoldEnded?()
            case .cancelled, .failed:
                owner.onHoldCancelled?()
            default:
                break
            }
        }
        #endif

        func syncBeforeKeyAction(_ textView: UITextView) -> Bool {
            guard textView.markedTextRange == nil else {
                if !owner.isComposing { owner.isComposing = true }
                return false
            }
            if owner.isComposing { owner.isComposing = false }
            if owner.text != textView.text {
                owner.text = textView.text
            }
            return true
        }

        #if targetEnvironment(macCatalyst)
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !applying else { return true }
            // When macOS input methods (e.g. Simplified Chinese Pinyin, Rime, WeType) are active,
            // bare Return is routed through NSTextInputClient.insertNewline instead of pressesBegan.
            if text == "\n", textView.markedTextRange == nil {
                let cgFlags = CGEventSource.flagsState(.combinedSessionState)
                var modifiers: UIKeyModifierFlags = []
                if cgFlags.contains(.maskShift) { modifiers.insert(.shift) }
                if cgFlags.contains(.maskAlternate) { modifiers.insert(.alternate) }
                if cgFlags.contains(.maskCommand) { modifiers.insert(.command) }
                if cgFlags.contains(.maskControl) { modifiers.insert(.control) }
                _ = syncBeforeKeyAction(textView)
                if let native = textView as? NativeTextView,
                   native.handleMacKeyPress(keyCode: .keyboardReturnOrEnter, modifiers: modifiers) {
                    return false
                }
            }
            return true
        }
        #endif

        func textViewDidChange(_ textView: UITextView) {
            guard !applying else { return }
            owner.text = textView.text
            publishSelection(textView)
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.selectedRange.length > 0 {
                MacTextSelectionTracker.shared.clear()
            }
            guard !applying, textView.text == owner.text else { return }
            publishSelection(textView)
        }

        func publishSelection(_ textView: UITextView) {
            if owner.selection != textView.selectedRange { owner.selection = textView.selectedRange }
            let composing = textView.markedTextRange != nil
            if owner.isComposing != composing { owner.isComposing = composing }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            MacTextSelectionTracker.shared.clear()
            if !applying { owner.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if !applying { owner.isFocused = false; owner.isComposing = false }
        }
    }
}
