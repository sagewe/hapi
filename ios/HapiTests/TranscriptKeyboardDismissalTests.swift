import SwiftUI
import UIKit
import XCTest
@testable import HapiUI

@MainActor
final class TranscriptKeyboardDismissalTests: XCTestCase {
    private struct Row: Identifiable, Equatable { let id: String }

    private struct ReadOnlyBody: UIViewRepresentable {
        func makeUIView(context: Context) -> UITextView {
            let view = UITextView()
            view.isEditable = false
            view.isSelectable = true
            view.text = "A normal assistant reply, with selectable text."
            return view
        }
        func updateUIView(_ view: UITextView, context: Context) {}
    }

    private func window() throws -> (UIWindow, UIViewController, UITextField) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let field = UITextField(frame: CGRect(x: 16, y: 700, width: 320, height: 44))
        field.text = "Composer draft stays here"
        host.view.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder())
        return (window, host, field)
    }

    func testTapPolicyPreservesInputsSelectionsAndControlsButAcceptsOrdinaryReadOnlyBody() throws {
        let (window, host, field) = try window()
        defer { window.isHidden = true }
        let policy = TranscriptKeyboardDismissal(isProtected: { false }, dismiss: { window.endEditing(false) })
        XCTAssertFalse(policy.tap.cancelsTouchesInView)
        XCTAssertTrue(policy.gestureRecognizer(policy.tap, shouldRecognizeSimultaneouslyWith: UILongPressGestureRecognizer()))
        XCTAssertFalse(policy.allowsTouch(in: field))
        let editable = UITextView()
        XCTAssertFalse(policy.allowsTouch(in: editable))
        let button = UIButton()
        let nestedButtonLabel = UILabel()
        button.addSubview(nestedButtonLabel)
        XCTAssertFalse(policy.allowsTouch(in: nestedButtonLabel))
        let link = UIView()
        link.accessibilityTraits = .link
        XCTAssertFalse(policy.allowsTouch(in: link))
        XCTAssertTrue(field.isFirstResponder)

        let body = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        body.isEditable = false
        body.isSelectable = true
        body.text = "Selectable assistant reply"
        host.view.addSubview(body)
        body.selectedRange = NSRange(location: 0, length: 10)
        XCTAssertFalse(policy.allowsTouch(in: body), "A selection must retain its handles/menu")
        XCTAssertTrue(field.isFirstResponder)
        body.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertTrue(policy.receiveTouch(in: body), "An ordinary read-only reply tap must still dismiss")
        body.selectedRange = NSRange(location: 0, length: 10)
        policy.dismissAfterTap()
        XCTAssertTrue(field.isFirstResponder, "A selection established after touch-down must still be protected")
        body.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertTrue(policy.receiveTouch(in: body))
        policy.dismissAfterTap()
        XCTAssertFalse(field.isFirstResponder)
        XCTAssertEqual(field.text, "Composer draft stays here")
    }

    func testOnlyOneDirectDownwardDismissalPerDragAndNoMomentumOrProgrammaticDismissal() throws {
        var dismissals = 0
        let policy = TranscriptKeyboardDismissal(isProtected: { false }, dismiss: { dismissals += 1 })
        policy.beginDragging()
        for translation in [CGPoint(x: 0, y: 31), CGPoint(x: 0, y: -120), CGPoint(x: 100, y: 40)] {
            policy.updateDrag(isDragging: true, translation: translation)
        }
        policy.updateDrag(isDragging: false, translation: CGPoint(x: 0, y: 120))
        XCTAssertEqual(dismissals, 0)
        policy.updateDrag(isDragging: true, translation: CGPoint(x: 3, y: 32))
        policy.updateDrag(isDragging: true, translation: CGPoint(x: 2, y: 90))
        XCTAssertEqual(dismissals, 1)
        policy.beginDragging()
        policy.updateDrag(isDragging: true, translation: CGPoint(x: 0, y: 40))
        XCTAssertEqual(dismissals, 2)
        let editable = UITextView()
        XCTAssertFalse(policy.receiveTouch(in: editable))
        policy.beginDragging()
        policy.updateDrag(isDragging: true, translation: CGPoint(x: 0, y: 80))
        XCTAssertEqual(dismissals, 2, "Dragging a text-input selection must not dismiss")
    }

    func testInspectionOrDisabledProtectionIsCheckedAgainWhenAnInteractionFinishes() throws {
        let (window, _, field) = try window()
        defer { window.isHidden = true }
        var protected = false
        let policy = TranscriptKeyboardDismissal(isProtected: { protected }, dismiss: { window.endEditing(false) })
        XCTAssertTrue(policy.allowsTouch(in: UIView()))
        protected = true
        policy.dismissAfterTap()
        policy.beginDragging()
        policy.updateDrag(isDragging: true, translation: CGPoint(x: 0, y: 80))
        XCTAssertFalse(policy.allowsTouch(in: UIView()))
        XCTAssertTrue(field.isFirstResponder)
        protected = false
        policy.dismissAfterTap()
        XCTAssertFalse(field.isFirstResponder)
    }

    func testInstalledDismissalResignsComposerWithoutMovingHistoryOrLosingDraft() async throws {
        let (window, host, field) = try window()
        defer { window.isHidden = true }
        let controller = TranscriptCollectionController<Row>()
        host.addChild(controller)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        let collection = try XCTUnwrap(controller.view as? UICollectionView)
        let configuration = AnchoredTranscriptList(
            items: (0..<40).map { Row(id: String($0)) }, historyVersion: 1, jumpToken: 0,
            historyControlID: "history", onViewport: { _ in }, onLayout: { _, _ in }
        ) { _ in AnyView(ReadOnlyBody().frame(height: 100)) }
        controller.update(configuration)
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            if collection.contentSize.height > 1000 { break }
        }
        collection.layoutIfNeeded()
        #if targetEnvironment(macCatalyst)
        XCTAssertFalse((collection.gestureRecognizers ?? []).contains { $0.name == "hapi.transcript.keyboard-dismiss" })
        #else
        let tap = try XCTUnwrap(collection.gestureRecognizers?.first { $0.name == "hapi.transcript.keyboard-dismiss" })
        let policy = try XCTUnwrap(tap.delegate as? TranscriptKeyboardDismissal)
        controller.scrollViewWillBeginDragging(collection)
        collection.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        controller.scrollViewDidEndDragging(collection, willDecelerate: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(field.isFirstResponder, "Programmatic scrolls must not dismiss")
        let offset = collection.contentOffset
        let bodies = collection.visibleCells.flatMap { textViews(in: $0) }
        let body = try XCTUnwrap(bodies.first)
        body.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertTrue(policy.allowsTouch(in: body))
        policy.dismissAfterTap()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(field.isFirstResponder)
        XCTAssertEqual(field.text, "Composer draft stays here")
        XCTAssertEqual(collection.contentOffset.y, offset.y, accuracy: 1)
        #endif
    }

    private func textViews(in view: UIView) -> [UITextView] {
        if let text = view as? UITextView { return [text] }
        return view.subviews.flatMap(textViews)
    }
}
