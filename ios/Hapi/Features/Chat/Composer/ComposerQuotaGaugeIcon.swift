import SwiftUI

/// Open-bottom 240° dual-tone progress arc gauge with a central pivot needle,
/// distinguishing quota/session controls from the leading `clock` schedule glyph.
struct ComposerQuotaGaugeIcon: View {
    let usedPercent: Double?
    let accentColor: Color

    #if targetEnvironment(macCatalyst)
    @ScaledMetric(relativeTo: .body) private var gaugeDiameter: CGFloat = 16
    private let lineWidth: CGFloat = 1.6
    #else
    @ScaledMetric(relativeTo: .body) private var gaugeDiameter: CGFloat = 22
    private let lineWidth: CGFloat = 1.95
    #endif

    var remainingFraction: Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return 1 - min(1, max(0, usedPercent / 100))
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 240.0 / 360.0)
                .stroke(
                    Color.primary.opacity(0.22),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(150))

            if let fraction = remainingFraction {
                Circle()
                    .trim(from: 0, to: (240.0 / 360.0) * fraction)
                    .stroke(
                        accentColor,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(150))

                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let scale = size.width / 19.0
                    let rad = (150.0 + fraction * 240.0) * .pi / 180.0
                    let pivotRadius = 2.1 * scale
                    let needleLength = 5.8 * scale
                    let start = CGPoint(
                        x: center.x + pivotRadius * cos(rad),
                        y: center.y + pivotRadius * sin(rad)
                    )
                    let end = CGPoint(
                        x: center.x + needleLength * cos(rad),
                        y: center.y + needleLength * sin(rad)
                    )
                    var needle = Path()
                    needle.move(to: start)
                    needle.addLine(to: end)
                    context.stroke(
                        needle,
                        with: .color(accentColor),
                        style: StrokeStyle(lineWidth: lineWidth * 0.92, lineCap: .round)
                    )
                    let pivotRect = CGRect(
                        x: center.x - pivotRadius,
                        y: center.y - pivotRadius,
                        width: pivotRadius * 2,
                        height: pivotRadius * 2
                    )
                    context.stroke(
                        Path(ellipseIn: pivotRect),
                        with: .color(accentColor),
                        lineWidth: lineWidth * 0.88
                    )
                }
            }
        }
        .frame(width: gaugeDiameter, height: gaugeDiameter)
        .offset(y: gaugeDiameter * 0.10)
    }
}
