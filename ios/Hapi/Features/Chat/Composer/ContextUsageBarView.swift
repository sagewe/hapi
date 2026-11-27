import HapiProtocol
import SwiftUI

/// Compact live context-window utilization bar shown above the composer once
/// assistant `meta.usage` arrives. Works across iOS, Mac Catalyst, and QiqiWork.
struct ContextUsageBarView: View {
    let usage: LatestUsage

    private var ratio: Double? {
        guard let window = usage.contextWindow, window > 0 else { return nil }
        return min(max(usage.contextSize / window, 0), 1)
    }

    private var tint: Color {
        guard let ratio else { return .secondary }
        if ratio >= 0.90 { return .red }
        if ratio >= 0.75 { return .orange }
        return .accentColor
    }

    var body: some View {
        HStack(spacing: 8) {
            if let ratio {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(tint)
                            .frame(width: max(3, proxy.size.width * ratio))
                    }
                }
                .frame(width: 52, height: 4)
            }
            Text(summaryText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(ratio.map { $0 >= 0.75 ? tint : .secondary } ?? .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryText)
    }

    private var summaryText: String {
        let used = Self.formatTokens(usage.contextSize)
        if let window = usage.contextWindow, window > 0 {
            let pct = Int((usage.contextSize / window * 100).rounded())
            return "\(used) / \(Self.formatTokens(window)) (\(pct)%)"
        }
        return "\(used) tokens"
    }

    private static func formatTokens(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", value / 1_000)
        }
        return String(Int(value.rounded()))
    }
}
