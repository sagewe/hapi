import HapiClient
import HapiProtocol
import SwiftUI
import UIKit
import XCTest
@testable import Hapi

@MainActor
final class MentionTextInputTests: XCTestCase {
    final class State {
        var text = ""
        var selection = NSRange(location: 0, length: 0)
        var composing = false
        var focused = false
    }

    func testNativeDelegatePublishesCaretAndSuppressesQueriesDuringComposition() {
        let state = State()
        let input = ComposerTextView(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            isFocused: Binding(get: { state.focused }, set: { state.focused = $0 }),
            isComposing: Binding(get: { state.composing }, set: { state.composing = $0 }),
            font: .systemFont(ofSize: 16), accessibilityLabel: "Message the agent…")
        let coordinator = input.makeCoordinator()
        let editor = ComposerTextView.NativeTextView()
        editor.delegate = coordinator
        editor.text = "😀 @"
        editor.selectedRange = NSRange(location: editor.text.utf16.count, length: 0)
        coordinator.textViewDidChange(editor)
        XCTAssertEqual(state.selection.location, 4)
        XCTAssertEqual(ComposerMentionSuggestions.query(in: state.text, selection: state.selection)?.search, "")
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        coordinator.textViewDidChange(editor)
        XCTAssertTrue(state.composing)
        input.synchronize(editor, coordinator: coordinator)
        XCTAssertNotNil(editor.markedTextRange, "A SwiftUI echo must not cancel IME composition")
        editor.unmarkText()
        coordinator.textViewDidChange(editor)
        XCTAssertFalse(state.composing)
        XCTAssertEqual(state.text, editor.text)
        editor.selectedRange = NSRange(location: 0, length: 2)
        coordinator.textViewDidChangeSelection(editor)
        XCTAssertNil(ComposerMentionSuggestions.query(in: state.text, selection: state.selection))
    }

    func testSuggestionListFitsShortListsAndBoundsLongLists() {
        func row(_ id: String) -> ComposerMentionSuggestion {
            ComposerMentionSuggestion(id: id, text: "@" + id, label: "家庭 Gateway", detail: "/repo", source: .session(active: true))
        }
        let short = UIHostingController(rootView: ComposerMentionList(suggestions: [row("one")],
                        surface: .white, onSelect: { _ in }))
        let shortSize = short.sizeThatFits(in: CGSize(width: 350, height: 1000))
        XCTAssertGreaterThanOrEqual(shortSize.height, 44)
        XCTAssertLessThan(shortSize.height, 100)
        let long = UIHostingController(rootView: ComposerMentionList(suggestions: (0..<20).map { row("\($0)") },
                        surface: .black, onSelect: { _ in }))
        XCTAssertEqual(long.sizeThatFits(in: CGSize(width: 350, height: 1000)).height, 232, accuracy: 1)
    }

    func testProgrammaticUpdatesDoNotFeedBackIntoDrafts() {
        let state = State()
        let input = ComposerTextView(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            isFocused: Binding(get: { state.focused }, set: { state.focused = $0 }),
            isComposing: Binding(get: { state.composing }, set: { state.composing = $0 }),
            font: .systemFont(ofSize: 16), accessibilityLabel: "Message the agent…")
        let coordinator = input.makeCoordinator()
        let editor = ComposerTextView.NativeTextView()
        coordinator.applying = true
        editor.text = "restored draft"
        coordinator.textViewDidChange(editor)
        XCTAssertEqual(state.text, "")
        coordinator.applying = false
        coordinator.textViewDidChange(editor)
        XCTAssertEqual(state.text, "restored draft")
        state.text = "[家庭](/sessions/abc) "
        state.selection = NSRange(location: state.text.utf16.count, length: 0)
        input.synchronize(editor, coordinator: coordinator)
        XCTAssertEqual(editor.text, state.text)
        XCTAssertEqual(editor.selectedRange, state.selection)
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        state.text = ""
        state.selection = NSRange(location: 0, length: 0)
        input.synchronize(editor, coordinator: coordinator)
        XCTAssertEqual(editor.text, "", "Send clearing must apply even with marked text")
        XCTAssertNil(editor.markedTextRange)
    }

    func testMacKeyPressHandlersRouteSuggestionsAndSteerAndRespectIME() {
        let editor = ComposerTextView.NativeTextView()
        var returnCount = 0
        var steerCount = 0
        var moves: [Int] = []
        var tabCount = 0
        var escapeCount = 0

        editor.onReturn = { returnCount += 1; return true }
        editor.onSteerReturn = { steerCount += 1; return true }
        editor.onMoveSuggestion = { delta in moves.append(delta); return true }
        editor.onTab = { tabCount += 1; return true }
        editor.onEscape = { escapeCount += 1; return true }

        XCTAssertTrue(editor.handleMacKeyPress(keyCode: .keyboardReturnOrEnter, modifiers: []))
        XCTAssertTrue(editor.handleMacKeyPress(keyCode: .keyboardReturnOrEnter, modifiers: [.command]))
        XCTAssertEqual(returnCount, 2)

        XCTAssertFalse(editor.handleMacKeyPress(keyCode: .keyboardReturnOrEnter, modifiers: [.shift]))
        XCTAssertFalse(editor.handleMacKeyPress(keyCode: .keyboardReturnOrEnter, modifiers: [.alternate]))

        XCTAssertTrue(editor.handleMacKeyPress(keyCode: .keyboardReturnOrEnter, modifiers: [.command, .shift]))
        XCTAssertTrue(editor.handleMacKeyPress(keyCode: .keypadEnter, modifiers: [.command, .alternate]))
        XCTAssertEqual(steerCount, 2)

        XCTAssertTrue(editor.handleMacKeyPress(keyCode: .keyboardUpArrow, modifiers: []))
        XCTAssertTrue(editor.handleMacKeyPress(keyCode: .keyboardDownArrow, modifiers: []))
        XCTAssertEqual(moves, [-1, 1])

        XCTAssertTrue(editor.handleMacKeyPress(keyCode: .keyboardTab, modifiers: []))
        XCTAssertEqual(tabCount, 1)

        XCTAssertTrue(editor.handleMacKeyPress(keyCode: .keyboardEscape, modifiers: []))
        XCTAssertEqual(escapeCount, 1)

        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertFalse(editor.handleMacKeyPress(keyCode: .keyboardReturnOrEnter, modifiers: []))
        XCTAssertFalse(editor.handleMacKeyPress(keyCode: .keyboardUpArrow, modifiers: []))
        XCTAssertFalse(editor.handleMacKeyPress(keyCode: .keyboardTab, modifiers: []))
        XCTAssertFalse(editor.handleMacKeyPress(keyCode: .keyboardEscape, modifiers: []))
    }

    #if !targetEnvironment(macCatalyst)
    func testStationaryHoldFiresWithoutUpwardDragAndShortTapFocusesEditor() async throws {
        let state = State()
        var beganPoints: [CGPoint] = []
        var changedPoints: [CGPoint] = []
        var endedCount = 0

        let input = ComposerTextView(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            isFocused: Binding(get: { state.focused }, set: { state.focused = $0 }),
            isComposing: Binding(get: { state.composing }, set: { state.composing = $0 }),
            font: .systemFont(ofSize: 16),
            accessibilityLabel: "Hold to dictate…",
            holdToDictateEnabled: true,
            onHoldBegan: { pt, _ in beganPoints.append(pt) },
            onHoldChanged: { pt, _ in changedPoints.append(pt) },
            onHoldEnded: { endedCount += 1 }
        )
        let coordinator = input.makeCoordinator()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let textView = ComposerTextView.NativeTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
        textView.delegate = coordinator
        textView.ownerCoordinator = coordinator
        let host = ComposerTextView.ComposerHostView(textView: textView, coordinator: coordinator)
        host.frame = CGRect(x: 14, y: 780, width: 300, height: 24)
        coordinator.hostView = host
        window.addSubview(host)
        window.makeKeyAndVisible()
        host.layoutIfNeeded()
        input.synchronize(textView, coordinator: coordinator)

        // Expanded hit-test routes unfocused touches to `touchOverlay`, NOT `NativeTextView`.
        XCTAssertTrue(host.hitTest(CGPoint(x: -10, y: -8), with: nil) === host.touchOverlay)
        XCTAssertNil(host.hitTest(CGPoint(x: -20, y: -8), with: nil))

        // 1) Pure stationary press (zero movement!) must fire `onHoldBegan` after ~240ms.
        let pressPoint = CGPoint(x: 180, y: 792)
        host.touchOverlay.beginTracking(windowPoint: pressPoint)
        try await Task.sleep(nanoseconds: 310_000_000)
        XCTAssertEqual(beganPoints, [pressPoint], "Stationary hold must engage without pulling up")
        XCTAssertFalse(state.focused)

        let dragPoint = CGPoint(x: 90, y: 650)
        host.touchOverlay.updateTracking(windowPoint: dragPoint)
        XCTAssertEqual(changedPoints, [dragPoint])

        host.touchOverlay.endTracking(tapPointInTextView: CGPoint(x: 100, y: 12))
        XCTAssertEqual(endedCount, 1)
        XCTAssertFalse(state.focused)

        // 2) Short tap (< 240ms) must focus editor without engaging voice hold.
        host.touchOverlay.beginTracking(windowPoint: pressPoint)
        try await Task.sleep(nanoseconds: 40_000_000)
        host.touchOverlay.endTracking(tapPointInTextView: CGPoint(x: 100, y: 12))
        XCTAssertEqual(beganPoints.count, 1, "Short tap must not trigger voice hold")
        XCTAssertTrue(state.focused)
        XCTAssertTrue(host.touchOverlay.isHidden)
    }
    #endif
}
