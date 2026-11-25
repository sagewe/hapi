#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Single-line cells share a native selection surface, retaining inline
/// styles and links. Multiline cells and RTL containers use the cell grid.
struct MacSingleLineMarkdownTable {
    let text: NSAttributedString
    let width: CGFloat
    let rowHeight: CGFloat
    let rowCount: Int

    @MainActor
    static func make(model: MarkdownTableModel, theme: HapiTheme, typography: HapiTypography,
                     direction: LayoutDirection) -> Self? {
        let rows = [model.header] + model.rows
        let columns = model.header.count
        guard direction == .leftToRight, columns > 0,
              rows.allSatisfy({ $0.count == columns }) else { return nil }
        let strings = rows.map { $0.map { String($0.characters) } }
        guard strings.flatMap({ $0 }).allSatisfy({
            $0.rangeOfCharacter(from: .newlines) == nil && !$0.contains("\t")
        }) else { return nil }

        let bodyFont = UIFont.systemFont(ofSize: typography.bodySize, weight: typography.boldText ? .semibold : .regular)
        let headerFont = UIFont.systemFont(ofSize: typography.bodySize, weight: typography.boldText ? .bold : .semibold)
        let styled = rows.enumerated().map { index, row in
            row.map { cell in
                MacSelectableText.Content.markdown(
                    cell, baseSize: typography.bodySize,
                    baseWeight: index == 0 ? (typography.boldText ? .bold : .semibold) : (typography.boldText ? .semibold : .regular),
                    lineSpacing: typography.bodyLineSpacing, theme: theme, typography: typography
                ).buildAttributedString()
            }
        }
        var widths = Array(repeating: CGFloat.zero, count: columns)
        var lineHeight: CGFloat = 0
        for row in styled {
            for (column, cell) in row.enumerated() {
                let size = cell.size()
                widths[column] = max(widths[column], ceil(size.width) + 20)
                lineHeight = max(lineHeight, ceil(size.height))
            }
        }
        let rowHeight = max(lineHeight, ceil(bodyFont.lineHeight)) + 12
        guard widths.reduce(0, +) < 95_000, CGFloat(rows.count) * rowHeight < 95_000 else { return nil }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = rowHeight
        paragraph.maximumLineHeight = rowHeight
        paragraph.baseWritingDirection = .leftToRight
        var x: CGFloat = 0
        paragraph.tabStops = widths.enumerated().map { column, width in
            defer { x += width }
            let alignment = column < model.columnAlignments.count ? model.columnAlignments[column] : nil
            switch alignment {
            case .right: return NSTextTab(textAlignment: .right, location: x + width - 10)
            case .center: return NSTextTab(textAlignment: .center, location: x + width / 2)
            default: return NSTextTab(textAlignment: .left, location: x + 10)
            }
        }
        paragraph.defaultTabInterval = widths.reduce(0, +) + 20
        let result = NSMutableAttributedString(string: "")
        for (index, row) in styled.enumerated() {
            let separatorAttributes: [NSAttributedString.Key: Any] = [
                .font: index == 0 ? headerFont : bodyFont,
                .foregroundColor: UIColor(theme.textPrimary),
            ]
            let line = NSMutableAttributedString(string: "")
            for cell in row {
                line.append(NSAttributedString(string: "\t", attributes: separatorAttributes))
                line.append(cell)
            }
            if index < styled.count - 1 {
                line.append(NSAttributedString(string: "\n", attributes: separatorAttributes))
            }
            let range = NSRange(location: 0, length: line.length)
            line.addAttribute(.paragraphStyle, value: paragraph, range: range)
            result.append(line)
        }
        return Self(text: NSAttributedString(attributedString: result), width: widths.reduce(0, +),
                    rowHeight: rowHeight, rowCount: rows.count)
    }
}

struct MacSingleLineMarkdownTableView: View {
    let table: MacSingleLineMarkdownTable
    let theme: HapiTheme
    @Environment(\.hapiOpenURL) private var openURL

    var body: some View {
        MacSelectableText(content: .attributed(table.text), wraps: false, fillsWidth: false,
                          linkColor: UIColor(theme.link), onOpenURL: { openURL($0) })
            .frame(width: table.width, alignment: .leading)
            .background {
                Canvas { context, size in
                    context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: table.rowHeight)),
                                 with: .color(theme.tableHeaderBackground))
                    var lines = Path()
                    for row in 1..<table.rowCount {
                        let y = CGFloat(row) * table.rowHeight
                        lines.move(to: CGPoint(x: 0, y: y))
                        lines.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(lines, with: .color(theme.textSecondary.opacity(0.25)), lineWidth: 0.5)
                }
                .allowsHitTesting(false)
            }
    }
}
#endif
