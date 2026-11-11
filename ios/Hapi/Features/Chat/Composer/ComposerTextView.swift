import CoreGraphics
import HapiUI
import SwiftUI
import UIKit
#if !targetEnvironment(macCatalyst)
import UIKit.UIGestureRecognizerSubclass
#endif
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
    /// iOS WeChat-style Hold-to-Dictate: tap focuses to edit, stationary long-press starts voice.
    var holdToDictateEnabled: Bool = false
    var onHoldBegan: ((CGPoint, CGSize) -> Void)? = nil
    var onHoldChanged: ((CGPoint, CGSize) -> Void)? = nil
    var onHoldEnded: (() -> Void)? = nil
    var onHoldCancelled: (() -> Void)? = nil
    #endif

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    #if targetEnvironment(macCatalyst)
    func makeUIView(context: Context) -> NativeTextView {
        makeConfiguredTextView(coordinator: context.coordinator)
    }

    func updateUIView(_ view: NativeTextView, context: Context) {
        synchronize(view, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NativeTextView, context: Context) -> CGSize? {
        measureTextView(uiView, proposal: proposal)
    }

    static func dismantleUIView(_ uiView: NativeTextView, coordinator: Coordinator) {
        uiView.wantsFocus = false
        uiView.delegate = nil
    }
    #else
    func makeUIView(context: Context) -> ComposerHostView {
        let textView = makeConfiguredTextView(coordinator: context.coordinator)
        let host = ComposerHostView(textView: textView, coordinator: context.coordinator)
        context.coordinator.hostView = host
        return host
    }

    func updateUIView(_ host: ComposerHostView, context: Context) {
        synchronize(host.textView, coordinator: context.coordinator)
        host.syncOverlayVisibility()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerHostView, context: Context) -> CGSize? {
        measureTextView(uiView.textView, proposal: proposal)
    }

    static func dismantleUIView(_ uiView: ComposerHostView, coordinator: Coordinator) {
        uiView.touchOverlay.resetTracking(notifyCancel: false)
        uiView.textView.cancelFocusedEmptyHold(notifyCancel: false)
        uiView.textView.wantsFocus = false
        uiView.textView.delegate = nil
    }
    #endif

    private func makeConfiguredTextView(coordinator: Coordinator) -> NativeTextView {
        let view = NativeTextView()
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.contentInset = .zero
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = coordinator
        view.ownerCoordinator = coordinator
        return view
    }

    private func measureTextView(_ textView: NativeTextView, proposal: ProposedViewSize) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let height = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        #if targetEnvironment(macCatalyst)
        let minimum = ceil(font.lineHeight * 1.75)
        let maximum = ceil(font.lineHeight * 12)
        textView.showsVerticalScrollIndicator = true
        #else
        let minimum = ceil(font.lineHeight)
        let maximum = ceil(font.lineHeight * 6)
        #endif
        textView.isScrollEnabled = height > maximum
        return CGSize(width: width, height: min(maximum, max(minimum, height)))
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
        #if !targetEnvironment(macCatalyst)
        coordinator.hostView?.syncOverlayVisibility()
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    /// Sibling host view on iOS so an unfocused composer intercepts raw touches
    /// on `touchOverlay` without `UITextView`'s internal `UITextInteraction`
    /// recognizers delaying stationary long-presses or cancelling drags at 0.5s.
    final class ComposerHostView: UIView {
        let textView: NativeTextView
        let touchOverlay: HoldOrTapOverlayView
        weak var coordinator: Coordinator?
        var hitTestOutsets = UIEdgeInsets(top: 12, left: 14, bottom: 4, right: 14)

        init(textView: NativeTextView, coordinator: Coordinator) {
            self.textView = textView
            self.touchOverlay = HoldOrTapOverlayView()
            self.coordinator = coordinator
            super.init(frame: .zero)
            backgroundColor = .clear
            addSubview(textView)
            addSubview(touchOverlay)
            touchOverlay.hostView = self
            syncOverlayVisibility()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            textView.frame = bounds
            touchOverlay.frame = bounds
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            let expanded = bounds.inset(by: UIEdgeInsets(
                top: -hitTestOutsets.top,
                left: -hitTestOutsets.left,
                bottom: -hitTestOutsets.bottom,
                right: -hitTestOutsets.right
            ))
            return expanded.contains(point)
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard isUserInteractionEnabled, !isHidden, alpha > 0.01,
                  self.point(inside: point, with: event) else {
                return nil
            }
            if !touchOverlay.isHidden && touchOverlay.isUserInteractionEnabled {
                return touchOverlay
            }
            return textView
        }

        func syncOverlayVisibility() {
            // Never hide `touchOverlay` mid-press, otherwise UIKit cancels the active touch.
            if touchOverlay.isTrackingTouch {
                return
            }
            let enabled = coordinator?.owner.holdToDictateEnabled == true
            touchOverlay.isHidden = !(enabled && !textView.isFirstResponder)
        }
    }

    /// Prevents ancestor pan / pop gesture recognizers from cancelling an active
    /// Hold-to-Dictate drag once the 240ms stationary hold timer has engaged.
    final class ExclusiveTouchHoldRecognizer: UIGestureRecognizer {
        private(set) var isHoldLocked = false

        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        func engageHold() {
            isHoldLocked = true
            if state == .possible {
                state = .began
            }
        }

        func moveHold() {
            if state == .began || state == .changed {
                state = .changed
            }
        }

        func endHold() {
            isHoldLocked = false
            if state == .began || state == .changed {
                state = .ended
            } else {
                state = .failed
            }
        }

        func cancelHold() {
            isHoldLocked = false
            if state == .began || state == .changed {
                state = .cancelled
            } else {
                state = .failed
            }
        }

        override func reset() {
            super.reset()
            isHoldLocked = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesMoved(touches, with: event)
            if isHoldLocked, state == .began || state == .changed {
                state = .changed
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesEnded(touches, with: event)
            endHold()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesCancelled(touches, with: event)
            cancelHold()
        }

        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
            isHoldLocked
        }

        override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }
    }

    /// Raw UIResponder touch surface for the unfocused composer box:
    /// - Short tap (`< 240ms`) focuses `NativeTextView` for keyboard editing.
    /// - Stationary hold (`>= 240ms`, zero movement required) OR early upward pull
    ///   immediately starts Hold-to-Dictate and tracks thumb movement in window space.
    final class HoldOrTapOverlayView: UIView {
        static let holdThresholdSeconds: TimeInterval = 0.24

        weak var hostView: ComposerHostView?
        private let exclusiveRecognizer = ExclusiveTouchHoldRecognizer(target: nil, action: nil)
        private weak var activeTouch: UITouch?
        private var holdTimer: DispatchWorkItem?
        private var startWindowPoint: CGPoint = .zero
        private var latestWindowPoint: CGPoint = .zero
        private(set) var isTrackingTouch = false
        private(set) var didEngageHold = false
        private var cancelledTapBySwipe = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isMultipleTouchEnabled = false
            addGestureRecognizer(exclusiveRecognizer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            let outsets = hostView?.hitTestOutsets ?? UIEdgeInsets(top: 12, left: 14, bottom: 4, right: 14)
            let expanded = bounds.inset(by: UIEdgeInsets(
                top: -outsets.top,
                left: -outsets.left,
                bottom: -outsets.bottom,
                right: -outsets.right
            ))
            return expanded.contains(point)
        }

        private var currentWindowSize: CGSize {
            if let window {
                return window.bounds.size
            }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let keyWindow = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow
                ?? scenes.first?.windows.first {
                return keyWindow.bounds.size
            }
            return CGSize(width: 393, height: 852)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard activeTouch == nil, let touch = touches.first else { return }
            beginTracking(windowPoint: touch.location(in: window), touch: touch)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let activeTouch, touches.contains(activeTouch) else { return }
            updateTracking(windowPoint: activeTouch.location(in: window))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let activeTouch, touches.contains(activeTouch) else { return }
            let localInTextView = hostView.map { activeTouch.location(in: $0.textView) }
            endTracking(tapPointInTextView: localInTextView)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let activeTouch, touches.contains(activeTouch) else { return }
            resetTracking(notifyCancel: true)
        }

        // Exposed internal helpers so XCTest can deterministically test stationary hold vs tap.
        func beginTracking(windowPoint: CGPoint, touch: UITouch? = nil) {
            holdTimer?.cancel()
            activeTouch = touch
            isTrackingTouch = true
            didEngageHold = false
            cancelledTapBySwipe = false
            startWindowPoint = windowPoint
            latestWindowPoint = windowPoint

            let item = DispatchWorkItem { [weak self] in
                self?.engageHoldNow()
            }
            holdTimer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdThresholdSeconds, execute: item)
        }

        func updateTracking(windowPoint: CGPoint) {
            guard isTrackingTouch else { return }
            latestWindowPoint = windowPoint
            if didEngageHold {
                exclusiveRecognizer.moveHold()
                hostView?.coordinator?.owner.onHoldChanged?(windowPoint, currentWindowSize)
                return
            }
            let dx = windowPoint.x - startWindowPoint.x
            let dy = windowPoint.y - startWindowPoint.y
            // Pulling upward out of the composer box before 240ms is unambiguously voice hold.
            if dy < -18 && abs(dy) > abs(dx) {
                engageHoldNow()
            } else if hypot(dx, dy) > 24 {
                holdTimer?.cancel()
                holdTimer = nil
                cancelledTapBySwipe = true
            }
        }

        func endTracking(tapPointInTextView: CGPoint?) {
            guard isTrackingTouch else { return }
            holdTimer?.cancel()
            holdTimer = nil
            let wasHolding = didEngageHold
            let wasSwipeCancelled = cancelledTapBySwipe
            activeTouch = nil
            isTrackingTouch = false
            didEngageHold = false
            cancelledTapBySwipe = false

            if wasHolding {
                exclusiveRecognizer.endHold()
                hostView?.coordinator?.owner.onHoldEnded?()
                hostView?.syncOverlayVisibility()
                return
            }
            exclusiveRecognizer.cancelHold()
            guard !wasSwipeCancelled, let host = hostView, let coordinator = host.coordinator else {
                hostView?.syncOverlayVisibility()
                return
            }
            let textView = host.textView
            if let point = tapPointInTextView, !(textView.text ?? "").isEmpty,
               let pos = textView.closestPosition(to: point) {
                let offset = textView.offset(from: textView.beginningOfDocument, to: pos)
                let clamped = min(max(0, offset), (textView.text as NSString).length)
                let range = NSRange(location: clamped, length: 0)
                textView.selectedRange = range
                coordinator.owner.selection = range
            }
            isHidden = true
            textView.wantsFocus = true
            coordinator.owner.isFocused = true
            _ = textView.becomeFirstResponder()
        }

        func resetTracking(notifyCancel: Bool) {
            holdTimer?.cancel()
            holdTimer = nil
            let wasHolding = didEngageHold
            activeTouch = nil
            isTrackingTouch = false
            didEngageHold = false
            cancelledTapBySwipe = false
            exclusiveRecognizer.cancelHold()
            if wasHolding && notifyCancel {
                hostView?.coordinator?.owner.onHoldCancelled?()
            }
            hostView?.syncOverlayVisibility()
        }

        private func engageHoldNow() {
            guard isTrackingTouch, !didEngageHold else { return }
            holdTimer?.cancel()
            holdTimer = nil
            didEngageHold = true
            exclusiveRecognizer.engageHold()
            hostView?.coordinator?.owner.onHoldBegan?(latestWindowPoint, currentWindowSize)
        }
    }
    #endif

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
        private weak var focusedHoldTouch: UITouch?
        private var focusedHoldTimer: DispatchWorkItem?
        private var focusedHoldStart: CGPoint = .zero
        private var focusedHoldLatest: CGPoint = .zero
        private var focusedHoldEngaged = false

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

        private var currentWindowSize: CGSize {
            window?.bounds.size ?? CGSize(width: 393, height: 852)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            guard focusedHoldTouch == nil,
                  let touch = touches.first,
                  ownerCoordinator?.owner.holdToDictateEnabled == true,
                  isFirstResponder,
                  (text ?? "").isEmpty,
                  markedTextRange == nil else {
                return
            }
            let pt = touch.location(in: window)
            focusedHoldTouch = touch
            focusedHoldStart = pt
            focusedHoldLatest = pt
            focusedHoldEngaged = false
            let item = DispatchWorkItem { [weak self] in
                self?.engageFocusedEmptyHold()
            }
            focusedHoldTimer = item
            DispatchQueue.main.asyncAfter(
                deadline: .now() + HoldOrTapOverlayView.holdThresholdSeconds,
                execute: item
            )
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let active = focusedHoldTouch, touches.contains(active) {
                let pt = active.location(in: window)
                focusedHoldLatest = pt
                if focusedHoldEngaged {
                    ownerCoordinator?.owner.onHoldChanged?(pt, currentWindowSize)
                    return
                }
                let dx = pt.x - focusedHoldStart.x
                let dy = pt.y - focusedHoldStart.y
                if dy < -18 && abs(dy) > abs(dx) {
                    engageFocusedEmptyHold()
                    return
                } else if hypot(dx, dy) > 24 {
                    focusedHoldTimer?.cancel()
                    focusedHoldTimer = nil
                    focusedHoldTouch = nil
                }
            }
            super.touchesMoved(touches, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let active = focusedHoldTouch, touches.contains(active) {
                focusedHoldTimer?.cancel()
                focusedHoldTimer = nil
                let wasEngaged = focusedHoldEngaged
                focusedHoldTouch = nil
                focusedHoldEngaged = false
                if wasEngaged {
                    ownerCoordinator?.owner.onHoldEnded?()
                    ownerCoordinator?.hostView?.syncOverlayVisibility()
                    return
                }
            }
            super.touchesEnded(touches, with: event)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let active = focusedHoldTouch, touches.contains(active) {
                cancelFocusedEmptyHold(notifyCancel: true)
            }
            super.touchesCancelled(touches, with: event)
        }

        private func engageFocusedEmptyHold() {
            guard focusedHoldTouch != nil, !focusedHoldEngaged else { return }
            focusedHoldTimer?.cancel()
            focusedHoldTimer = nil
            focusedHoldEngaged = true
            // Cancel UITextView's simultaneous loupe / edit-menu recognizers so
            // they cannot fire at 0.5s and cancel our ongoing voice hold.
            for recognizer in gestureRecognizers ?? [] where recognizer.isEnabled {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
            wantsFocus = false
            ownerCoordinator?.owner.isFocused = false
            resignFirstResponder()
            ownerCoordinator?.owner.onHoldBegan?(focusedHoldLatest, currentWindowSize)
        }

        func cancelFocusedEmptyHold(notifyCancel: Bool) {
            focusedHoldTimer?.cancel()
            focusedHoldTimer = nil
            let wasEngaged = focusedHoldEngaged
            focusedHoldTouch = nil
            focusedHoldEngaged = false
            if wasEngaged && notifyCancel {
                ownerCoordinator?.owner.onHoldCancelled?()
            }
            ownerCoordinator?.hostView?.syncOverlayVisibility()
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

    final class Coordinator: NSObject, UITextViewDelegate {
        var owner: ComposerTextView
        var applying = false
        var lastBoundSelection: NSRange
        #if !targetEnvironment(macCatalyst)
        weak var hostView: ComposerHostView?
        #endif

        init(_ owner: ComposerTextView) {
            self.owner = owner
            self.lastBoundSelection = owner.selection
        }

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
            #if !targetEnvironment(macCatalyst)
            hostView?.invalidateIntrinsicContentSize()
            #endif
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
            #if !targetEnvironment(macCatalyst)
            hostView?.syncOverlayVisibility()
            #endif
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if !applying { owner.isFocused = false; owner.isComposing = false }
            #if !targetEnvironment(macCatalyst)
            hostView?.syncOverlayVisibility()
            #endif
        }
    }
}
