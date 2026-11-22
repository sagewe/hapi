#if targetEnvironment(macCatalyst) && DEBUG
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import HapiUI

@MainActor
final class MacTextReuseTests: XCTestCase {
    @Observable fileprivate final class Driver {
        var generation = 0
        var longLabels = false
        var rightToLeft = false
    }

    private struct Harness: View {
        let driver: Driver
        var body: some View {
            let source = "| Name | Added | Removed |\n| --- | ---: | ---: |\n"
                + (0..<10).map { "| row-\(driver.generation)-\($0)\(driver.longLabels ? String(repeating: " long", count: 8) : "") | \($0) | 1 |" }.joined(separator: "\n")
            MarkdownView(markdown: source)
                // This is the production transcript's stable message identity
                // boundary: new/recycled rows legitimately get a new root.
                .id(driver.generation)
                .frame(width: 700)
                .hapiTypography()
                .hapiTheme(.light)
                .environment(\.layoutDirection, driver.rightToLeft ? .rightToLeft : .leftToRight)
        }
    }

    func testRecyclingTablesReusesTextViewsAndClearsThePreviousSelection() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let driver = Driver()
        let before = MacSelectableText.SelectableUITextView.allocationCount
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Harness(driver: driver))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; MacTextSelectionTracker.shared.clear() }
        try await Task.sleep(for: .milliseconds(300))
        let initial = textViews(in: host.view)
        XCTAssertGreaterThanOrEqual(initial.count, 30, "The real 10-row table must render all its selectable cells")
        let selected = try XCTUnwrap(initial.first { $0.text.hasPrefix("row-0") })
        selected.selectedRange = NSRange(location: 0, length: 5)
        MacTextSelectionTracker.shared.updateSelection(from: selected)
        XCTAssertNotNil(MacTextSelectionTracker.shared.selectedText)
        for generation in 1...6 {
            driver.generation = generation
            try await Task.sleep(for: .milliseconds(180))
        }
        let current = textViews(in: host.view)
        XCTAssertGreaterThanOrEqual(current.count, 30)
        XCTAssertTrue(current.contains { $0.text.hasPrefix("row-6") })
        XCTAssertFalse(current.contains { $0.text.hasPrefix("row-0") }, "A reused native view must show the new row")
        XCTAssertNil(MacTextSelectionTracker.shared.selectedText, "⌘C must not retain text from a recycled row")
        let header = try XCTUnwrap(current.first { $0.text == "Added" })
        let oldX = header.convert(header.bounds, to: host.view).minX
        driver.longLabels = true
        try await Task.sleep(for: .milliseconds(180))
        let widerHeader = try XCTUnwrap(textViews(in: host.view).first { $0.text == "Added" })
        XCTAssertGreaterThan(widerHeader.convert(widerHeader.bounds, to: host.view).minX, oldX + 30,
                             "Same-identity cell edits must invalidate cached column widths")
        driver.longLabels = false
        driver.rightToLeft = true
        try await Task.sleep(for: .milliseconds(180))
        let rtl = textViews(in: host.view)
        let name = try XCTUnwrap(rtl.first { $0.text == "Name" })
        let added = try XCTUnwrap(rtl.first { $0.text == "Added" })
        XCTAssertGreaterThan(name.convert(name.bounds, to: host.view).minX,
                             added.convert(added.bounds, to: host.view).minX)
        let created = MacSelectableText.SelectableUITextView.allocationCount - before
        print("HAPI_TEXT_REUSE generations=7 textViewsCreated=\(created)")
        XCTAssertLessThanOrEqual(created, 100, "Scrolling must reuse native text systems instead of allocating 33 for every table")
    }

    private func textViews(in view: UIView) -> [MacSelectableText.SelectableUITextView] {
        (view as? MacSelectableText.SelectableUITextView).map { [$0] }
            ?? view.subviews.flatMap { textViews(in: $0) }
    }
}
#endif
