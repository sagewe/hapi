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
        let input = MentionTextInput(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            composing: Binding(get: { state.composing }, set: { state.composing = $0 }),
            focused: Binding(get: { state.focused }, set: { state.focused = $0 }),
            font: .systemFont(ofSize: 16))
        let coordinator = input.makeCoordinator()
        let editor = UITextView()
        editor.delegate = coordinator
        editor.text = "😀 @"
        editor.selectedRange = NSRange(location: editor.text.utf16.count, length: 0)
        coordinator.textViewDidChange(editor)
        XCTAssertEqual(state.selection.location, 4)
        XCTAssertEqual(SessionMentions.query(in: state.text, selection: state.selection)?.text, "")
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        coordinator.textViewDidChange(editor)
        XCTAssertTrue(state.composing)
        coordinator.synchronize(editor)
        XCTAssertNotNil(editor.markedTextRange, "A SwiftUI echo must not cancel IME composition")
        XCTAssertNil(SessionMentions.query(in: state.text, selection: state.selection, composing: state.composing))
        editor.unmarkText()
        coordinator.textViewDidChange(editor)
        XCTAssertFalse(state.composing)
        XCTAssertEqual(state.text, editor.text)
        editor.selectedRange = NSRange(location: 0, length: 2)
        coordinator.textViewDidChangeSelection(editor)
        XCTAssertNil(SessionMentions.query(in: state.text, selection: state.selection))
    }

    func testSuggestionListFitsShortListsAndBoundsLongLists() {
        func row(_ id: String) -> SessionSummary {
            SessionSummary(id: id, active: true, thinking: false, activeAt: 0, updatedAt: 0,
                           metadata: SessionSummaryMetadata(name: "家庭 Gateway", path: "/repo"),
                           metadataVersion: 0, agentStateVersion: 0, todosUpdatedAt: 0, pendingRequestsCount: 0)
        }
        let short = UIHostingController(rootView: SessionMentionList(sessions: [row("one")],
                        surface: .white, machineLabels: [:], select: { _ in }))
        let shortSize = short.sizeThatFits(in: CGSize(width: 350, height: 1000))
        XCTAssertGreaterThanOrEqual(shortSize.height, 44)
        XCTAssertLessThan(shortSize.height, 100)
        let long = UIHostingController(rootView: SessionMentionList(sessions: (0..<20).map { row("\($0)") },
                        surface: .black, machineLabels: [:], select: { _ in }))
        XCTAssertEqual(long.sizeThatFits(in: CGSize(width: 350, height: 1000)).height, 220, accuracy: 1)
    }

    func testProgrammaticUpdatesDoNotFeedBackIntoDrafts() {
        let state = State()
        let input = MentionTextInput(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            composing: Binding(get: { state.composing }, set: { state.composing = $0 }),
            focused: Binding(get: { state.focused }, set: { state.focused = $0 }),
            font: .systemFont(ofSize: 16))
        let coordinator = input.makeCoordinator()
        let editor = UITextView()
        coordinator.updating = true
        editor.text = "restored draft"
        coordinator.textViewDidChange(editor)
        XCTAssertEqual(state.text, "")
        coordinator.updating = false
        coordinator.textViewDidChange(editor)
        XCTAssertEqual(state.text, "restored draft")
        state.text = "[家庭](/sessions/abc) "
        state.selection = NSRange(location: state.text.utf16.count, length: 0)
        coordinator.synchronize(editor)
        XCTAssertEqual(editor.text, state.text)
        XCTAssertEqual(editor.selectedRange, state.selection)
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        state.text = ""
        state.selection = NSRange(location: 0, length: 0)
        coordinator.synchronize(editor)
        XCTAssertEqual(editor.text, "", "Send clearing must apply even with marked text")
        XCTAssertNil(editor.markedTextRange)
    }
}
