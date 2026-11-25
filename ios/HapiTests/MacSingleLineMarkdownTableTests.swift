#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import XCTest
@testable import HapiUI

@MainActor
final class MacSingleLineMarkdownTableTests: XCTestCase {
    func testPlainTableKeepsColumnAlignmentAndAllTextOnOneSelectionSurface() throws {
        let source = """
        | Name | Count | State |
        | :--- | ---: | :---: |
        | Short | 1 | Ready |
        | 较长的中文名称 | 99999 | Done |
        """
        guard case .table(let model) = try XCTUnwrap(MarkdownBlockTree.build(from: source).first) else {
            return XCTFail("Expected a table")
        }
        for scale in [CGFloat(1), 1.8] {
            let table = try XCTUnwrap(MacSingleLineMarkdownTable.make(
                model: model, theme: .light, typography: HapiTypography(bodyScale: scale), direction: .leftToRight))
            XCTAssertEqual(table.text.string, "\tName\tCount\tState\n\tShort\t1\tReady\n\t较长的中文名称\t99999\tDone")
            let view = MacSelectableText.SelectableUITextView()
            view.textContainerInset = .zero
            view.textContainer.widthTracksTextView = false
            view.textContainer.size = CGSize(width: table.width, height: 100_000)
            view.attributedText = table.text
            view.layoutManager.ensureLayout(for: view.textContainer)
            func frame(_ value: String) throws -> CGRect {
                let range = (table.text.string as NSString).range(of: value)
                XCTAssertNotEqual(range.location, NSNotFound)
                let glyphs = view.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                return view.layoutManager.boundingRect(forGlyphRange: glyphs, in: view.textContainer)
            }
            XCTAssertEqual(try frame("Short").minX, try frame("较长的中文名称").minX, accuracy: 1)
            XCTAssertEqual(try frame("1").maxX, try frame("99999").maxX, accuracy: 1)
            XCTAssertEqual(try frame("Ready").midX, try frame("Done").midX, accuracy: 1)
            XCTAssertGreaterThan(try frame("99999").minY, try frame("1").minY)
            XCTAssertLessThanOrEqual(view.layoutManager.usedRect(for: view.textContainer).maxX, table.width + 1)
            XCTAssertEqual(view.layoutManager.usedRect(for: view.textContainer).height,
                           table.rowHeight * CGFloat(table.rowCount), accuracy: 1)
        }
    }

    func testRichAttributesArePreservedAndUnsupportedShapesUseTheirExistingRenderer() {
        var model = MarkdownTableModel(columnAlignments: [], header: [AttributedString("Name")],
                                       rows: [[AttributedString("value")]])
        func make(_ direction: LayoutDirection = .leftToRight) -> MacSingleLineMarkdownTable? {
            MacSingleLineMarkdownTable.make(model: model, theme: .dark, typography: HapiTypography(), direction: direction)
        }
        XCTAssertNotNil(make())
        XCTAssertNil(make(.rightToLeft))
        model.rows[0][0].link = URL(string: "https://example.com")
        let linked = make()
        XCTAssertEqual(linked?.text.attribute(.link, at: 7, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        model.rows = [[AttributedString("first\nsecond")]]
        XCTAssertNil(make())
        model.rows = [[AttributedString("one\ttwo")]]
        XCTAssertNil(make())
        model.rows = [[]]
        XCTAssertNil(make())
    }
}
#endif
