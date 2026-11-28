import HapiClient
import HapiProtocol
import SwiftUI

/// Design system for standalone 「琪琪工作」 / assistant mode.
/// Shares MyDots's warm paper-and-ink palette, Liquid Glass floating chrome,
/// and calm thumb-zone hierarchy, accented with QiqiWork's Emerald Jade.
enum AssistantDesign {
    // MARK: - Brand Accent (Emerald Jade from QiqiWork icon)

    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.173, green: 0.773, blue: 0.639, alpha: 1) // #2CC5A3
            : UIColor(red: 0.059, green: 0.561, blue: 0.463, alpha: 1) // #0F8F76
    })

    /// Deeper emerald fill that maintains >= 4.5:1 contrast with white foreground text/icons in both light & dark modes.
    static let accentSolidFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.098, green: 0.565, blue: 0.463, alpha: 1) // #199076
            : UIColor(red: 0.059, green: 0.561, blue: 0.463, alpha: 1) // #0F8F76
    })

    static let accentSoft = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.090, green: 0.200, blue: 0.176, alpha: 1)
            : UIColor(red: 0.906, green: 0.961, blue: 0.945, alpha: 1)
    })

    static let accentBorder = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.173, green: 0.773, blue: 0.639, alpha: 0.34)
            : UIColor(red: 0.059, green: 0.561, blue: 0.463, alpha: 0.26)
    })

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(uiColor: UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? UIColor(red: 0.118, green: 0.659, blue: 0.537, alpha: 1)
                        : UIColor(red: 0.067, green: 0.592, blue: 0.486, alpha: 1)
                }),
                Color(uiColor: UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? UIColor(red: 0.078, green: 0.518, blue: 0.424, alpha: 1)
                        : UIColor(red: 0.043, green: 0.455, blue: 0.376, alpha: 1)
                }),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Warm Paper & Ink Neutrals (aligned with MyDots `DotsTheme`)

    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1) // #111214
            : UIColor(red: 0.965, green: 0.965, blue: 0.957, alpha: 1) // #F6F6F4
    })

    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.110, green: 0.114, blue: 0.122, alpha: 1) // #1C1D1F
            : .white
    })

    static let surfaceMuted = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.149, green: 0.153, blue: 0.165, alpha: 1) // #26272A
            : UIColor(red: 0.945, green: 0.945, blue: 0.933, alpha: 1) // #F1F1EE
    })

    static let surfaceElevated = surface

    static let subtleFill = surfaceMuted

    static let border = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.196, green: 0.200, blue: 0.212, alpha: 1) // #323336
            : UIColor(red: 0.898, green: 0.894, blue: 0.878, alpha: 1) // #E5E4E0
    })

    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.953, green: 0.953, blue: 0.945, alpha: 1) // #F3F3F1
            : UIColor(red: 0.110, green: 0.110, blue: 0.102, alpha: 1) // #1C1C1A
    })

    static let inkSecondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.690, green: 0.686, blue: 0.659, alpha: 1)
            : UIColor(red: 0.294, green: 0.290, blue: 0.271, alpha: 1)
    })

    static let inkMuted = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.510, green: 0.514, blue: 0.529, alpha: 1)
            : UIColor(red: 0.518, green: 0.514, blue: 0.490, alpha: 1)
    })

    static let shadow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.32)
            : UIColor.black.withAlphaComponent(0.055)
    })

    // MARK: - Semantic Accents (aligned with MyDots palette)

    static let risk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.984, green: 0.749, blue: 0.141, alpha: 1) // amber dark
            : UIColor(red: 0.851, green: 0.467, blue: 0.024, alpha: 1) // amber light
    })

    static let report = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.984, green: 0.443, blue: 0.522, alpha: 1) // rose dark
            : UIColor(red: 0.820, green: 0.200, blue: 0.310, alpha: 1) // refined crimson-rose
    })

    static let slateBlue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.376, green: 0.647, blue: 0.980, alpha: 1)
            : UIColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1)
    })

    static let teal = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.176, green: 0.831, blue: 0.749, alpha: 1)
            : UIColor(red: 0.051, green: 0.580, blue: 0.533, alpha: 1)
    })

    // MARK: - Formatting & Time Helpers

    static var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<11: "早上好"
        case 11..<14: "中午好"
        case 14..<18: "下午好"
        case 18..<23: "晚上好"
        default: "夜深了"
        }
    }

    static var calmDateCaption: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 · EEEE"
        return f.string(from: .now).replacingOccurrences(of: "星期", with: "周")
    }

    static func age(_ epoch: Int) -> String {
        let seconds = max(0, Date().timeIntervalSince1970 - Double(epoch) / 1000)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return Date(timeIntervalSince1970: Double(epoch) / 1000)
            .formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN")))
    }

    static func dayBucket(_ epoch: Int, now: Date = Date()) -> Int {
        let date = Date(timeIntervalSince1970: Double(epoch) / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(date) { return 0 }
        if cal.isDateInYesterday(date) { return 1 }
        if let weekAgo = cal.date(byAdding: .day, value: -7, to: now), date >= weekAgo { return 2 }
        return 3
    }

    static func dayBucketTitle(_ bucket: Int) -> String {
        switch bucket {
        case 0: "今天"
        case 1: "昨天"
        case 2: "近 7 天"
        default: "更早"
        }
    }
}

// MARK: - Surfaces, Liquid Glass & Signature MyDots Primitives

extension View {
    /// Clean flat warm-paper card surface with crisp hairline border (matching MyDots `dotsCardSurface`).
    func assistantSurface(radius: CGFloat = 16, elevated: Bool = false, selected: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(
                selected ? AssistantDesign.accentSoft : AssistantDesign.surface,
                in: shape
            )
            .overlay(
                shape.strokeBorder(
                    selected ? AssistantDesign.accentBorder : AssistantDesign.border,
                    lineWidth: selected ? 1.0 : 0.5
                )
            )
            .shadow(
                color: elevated ? AssistantDesign.shadow : .clear,
                radius: elevated ? 14 : 0,
                y: elevated ? 5 : 0
            )
    }

    /// Floating iOS 26+ Liquid Glass surface with graceful `.regularMaterial` fallback (MyDots `dotsGlass`).
    @ViewBuilder func assistantGlass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(AssistantDesign.border, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        }
    }
}

/// Two-stage smoky frosted Liquid Glass surface for the floating composer & popovers (MyDots `DotsComposerCardSurface`).
struct AssistantComposerCardSurface: View {
    let cornerRadius: CGFloat
    var focused: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let smokyTint = colorScheme == .dark
            ? Color(red: 0.14, green: 0.15, blue: 0.17).opacity(0.66)
            : Color(red: 0.24, green: 0.25, blue: 0.28).opacity(0.055)
        let borderTint = focused
            ? AssistantDesign.accentBorder
            : (colorScheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.08))

        if #available(iOS 26.0, *) {
            Color.clear
                .background(smokyTint, in: shape)
                .glassEffect(.regular.interactive(), in: shape)
                .overlay(shape.strokeBorder(focused ? AssistantDesign.accentBorder : .clear, lineWidth: 0.9))
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.34 : 0.08),
                    radius: 16,
                    x: 0,
                    y: 6
                )
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(smokyTint))
                .overlay(shape.strokeBorder(borderTint, lineWidth: focused ? 1.0 : 0.7))
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.36 : 0.08),
                    radius: 16,
                    x: 0,
                    y: 6
                )
        }
    }
}

/// MyDots signature asymmetric two-capsule drawer icon (16pt top bar, 10.5pt bottom bar).
struct AssistantMenuIcon: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5.5) {
            Capsule()
                .fill(AssistantDesign.ink)
                .frame(width: 16, height: 2)
            Capsule()
                .fill(AssistantDesign.ink)
                .frame(width: 10.5, height: 2)
        }
    }
}

/// MyDots signature orbiting ring indicator for active header / running status.
struct AssistantHeaderOrbitingRing: View {
    var color: Color = AssistantDesign.accent
    var lineWidth: CGFloat = 1.5
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.24), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.62)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.95).repeatForever(autoreverses: false), value: spinning)
        }
        .onAppear { spinning = true }
    }
}

/// Tactile press scale for cards, pills, and action buttons.
struct AssistantPressStyle: ButtonStyle {
    var scale: CGFloat = 0.975
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

struct AssistantPulseDot: View {
    var color: Color = AssistantDesign.accent
    var size: CGFloat = 7
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.28))
                .frame(width: size * 2.1, height: size * 2.1)
                .scaleEffect(pulse ? 1.15 : 0.75)
                .opacity(pulse ? 0.2 : 0.75)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2.1, height: size * 2.1)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct AssistantIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: max(9, size * 0.28), style: .continuous))
    }
}

// MARK: - Investigation Scenarios (MyDots `HomeThumbActionCard` proportions)

struct AssistantScene: Equatable, Identifiable {
    let action: ClientQuickAction
    var id: String { action.id }
    var kind: Int {
        let value = action.id.lowercased() + action.title
        if value.contains("document") || value.contains("单据") { return 2 }
        if value.contains("individual") || value.contains("自然人") { return 1 }
        if value.contains("sanction") || value.contains("制裁") { return 3 }
        return 0
    }
    var title: String { ["企业股权穿透", "自然人核查", "单据审核", "制裁与风险"][kind] }
    var icon: String { ["building.2.fill", "person.text.rectangle.fill", "doc.text.magnifyingglass", "shield.lefthalf.filled"][kind] }
    var color: Color { [AssistantDesign.accent, AssistantDesign.slateBlue, AssistantDesign.teal, AssistantDesign.risk][kind] }
    var placeholder: String { ["输入公司名称、税号或注册号…", "输入姓名、国籍或关联企业…", "添加单据，或补充需要核对的内容…", "输入主体、国家或交易线索…"][kind] }
    static func visibleText(_ text: String) -> String {
        guard text.hasPrefix("【调查场景："), let marker = text.range(of: "\n\n<investigation-instructions>") else { return text }
        return String(text[..<marker.lowerBound])
    }
    func message(_ text: String) -> String {
        "【调查场景：\(title)】\n\n\(text)\n\n<investigation-instructions>\n\(action.prompt)\n</investigation-instructions>"
    }
}

struct AssistantScenarioGrid: View {
    let scenes: [AssistantScene]
    var selectedScene: AssistantScene? = nil
    let select: (AssistantScene) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(scenes) { scene in
                let isSelected = selectedScene?.id == scene.id
                Button { select(scene) } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center) {
                            AssistantIcon(symbol: scene.icon, color: scene.color, size: 30)
                            Spacer(minLength: 4)
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(scene.color)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(AssistantDesign.inkMuted)
                            }
                        }
                        Text(scene.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AssistantDesign.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        isSelected ? scene.color.opacity(0.09) : AssistantDesign.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(isSelected ? scene.color.opacity(0.45) : AssistantDesign.border, lineWidth: isSelected ? 1.1 : 0.5)
                    )
                }
                .buttonStyle(AssistantPressStyle())
                .sensoryFeedback(.selection, trigger: isSelected)
                .accessibilityIdentifier("assistant.scene.\(scene.id)")
            }
        }
    }
}

struct AssistantSceneChip: View {
    let scene: AssistantScene
    let clear: () -> Void
    var body: some View {
        Button(action: clear) {
            HStack(spacing: 5.5) {
                Image(systemName: scene.icon).font(.system(size: 11, weight: .semibold))
                Text(scene.title).font(.caption.weight(.semibold))
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).opacity(0.75)
            }
            .foregroundStyle(scene.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .background(scene.color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(AssistantPressStyle(scale: 0.95))
        .accessibilityLabel("取消\(scene.title)")
    }
}

/// Compact inline segmented toggle for 快速 / 深度 (falls back to single capsule when custom).
struct AssistantPresetCapsule: View {
    let label: String
    var presets: [ClientModelPreset] = []
    var selectedID: String? = nil
    var onSelect: ((ClientModelPreset) -> Void)? = nil
    let action: () -> Void
    @Namespace private var thumb

    private var showsSegmented: Bool {
        presets.count == 2 && onSelect != nil
    }

    var body: some View {
        if showsSegmented {
            HStack(spacing: 2) {
                ForEach(presets) { preset in
                    let active = preset.id == selectedID || (selectedID == nil && preset.label == label)
                    Button {
                        guard !active else { return }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            onSelect?(preset)
                        }
                    } label: {
                        HStack(spacing: 3.5) {
                            Image(systemName: preset.label == "快速" ? "bolt.fill" : "sparkle")
                                .font(.system(size: 10, weight: .semibold))
                            Text(preset.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(active ? AssistantDesign.accent : AssistantDesign.inkMuted)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background {
                            if active {
                                Capsule()
                                    .fill(AssistantDesign.surface)
                                    .overlay(Capsule().strokeBorder(AssistantDesign.border, lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "preset-thumb", in: thumb)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(3)
            .background(AssistantDesign.surfaceMuted, in: Capsule())
            .sensoryFeedback(.selection, trigger: selectedID ?? label)
            .accessibilityIdentifier("assistant.mode-capsule")
        } else {
            Button(action: action) {
                Label(label, systemImage: label == "快速" ? "bolt.fill" : "sparkle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AssistantDesign.accent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6.5)
                    .background(AssistantDesign.accentSoft, in: Capsule())
            }
            .buttonStyle(AssistantPressStyle(scale: 0.96))
            .sensoryFeedback(.selection, trigger: label)
            .accessibilityIdentifier("assistant.mode-capsule")
        }
    }
}

// MARK: - Investigation Phase & History Presentation

enum AssistantInvestigationPhase {
    static func title(name: String, input: String = "") -> String {
        let value = (name + " " + input).lowercased()
        if value.contains("render_pdf") || value.contains("print-to-pdf") || value.contains("report-packaging") || value.contains("zip ") || value.contains("zipfile") || value.contains("make_archive") { return "正在排版生成中文 PDF 报告…" }
        if value.contains("browser") || value.contains("navigate") || value.contains("web") || value.contains("fetch") || value.contains("curl") { return "正在访问官网核验原始页面…" }
        if value.contains("image") || value.contains("read") || value.contains("document") || value.contains("pdf") || value.contains("ocr") { return "正在解析上传单据内容…" }
        return "正在检索公开登记与制裁线索…"
    }
}

struct AssistantPhaseCard: View {
    let phase: String
    let steps: Int
    let running: Bool
    var expanded = false
    var toggle: () -> Void = {}

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                if running {
                    AssistantHeaderOrbitingRing(color: AssistantDesign.accent, lineWidth: 1.7)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AssistantDesign.accent)
                }
                Text(running ? phase : "已完成 \(steps) 步查证")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(running ? AssistantDesign.ink : AssistantDesign.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if running, steps > 0 {
                    Text("\(steps) 步")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(AssistantDesign.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(AssistantDesign.accentSoft, in: Capsule())
                }
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AssistantDesign.inkMuted)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .assistantSurface(radius: 14, selected: running)
        }
        .buttonStyle(AssistantPressStyle(scale: 0.985))
        .accessibilityIdentifier("assistant.phase")
    }
}

enum AssistantHistoryPresentation {
    static func status(_ summary: SessionSummary) -> String? {
        if summary.pendingRequestsCount > 0 && summary.pendingRequestKinds.contains(.input) { return "待回复" }
        if summary.active && summary.thinking { return "调查中" }
        return nil
    }
}
