import HapiClient
import HapiProtocol
import SwiftUI

/// Assistant surfaces are deliberately independent of the developer interface.
enum AssistantDesign {
    static func age(_ epoch: Int) -> String {
        let seconds = max(0, Date().timeIntervalSince1970 - Double(epoch) / 1000)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return Date(timeIntervalSince1970: Double(epoch) / 1000).formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN")))
    }
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.065, green: 0.07, blue: 0.08, alpha: 1)
        : UIColor(red: 0.965, green: 0.971, blue: 0.978, alpha: 1) })
    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.125, green: 0.135, blue: 0.15, alpha: 1) : .white })
    static let border = Color.primary.opacity(0.085)
}
extension View {
    func assistantSurface(radius: CGFloat = 16) -> some View {
        background(AssistantDesign.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(AssistantDesign.border, lineWidth: 0.5))
    }
}
struct AssistantIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(color).frame(width: size, height: size)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }
}
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
    var icon: String { ["building.2", "person.text.rectangle", "doc.text.magnifyingglass", "shield.lefthalf.filled"][kind] }
    var color: Color { [.blue, .purple, .teal, .orange][kind] }
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
    let select: (AssistantScene) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(scenes) { scene in
                Button { select(scene) } label: {
                    VStack(alignment: .leading, spacing: 13) {
                        AssistantIcon(symbol: scene.icon, color: scene.color)
                        Text(scene.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, minHeight: 88, alignment: .leading).padding(16).assistantSurface()
                }.buttonStyle(.plain).accessibilityIdentifier("assistant.scene.\(scene.id)")
            }
        }
    }
}
struct AssistantSceneChip: View {
    let scene: AssistantScene
    let clear: () -> Void
    var body: some View {
        Button(action: clear) {
            HStack(spacing: 7) { Image(systemName: scene.icon); Text(scene.title); Image(systemName: "xmark").font(.caption2.weight(.semibold)) }
                .font(.caption.weight(.medium)).foregroundStyle(scene.color)
                .padding(.horizontal, 11).padding(.vertical, 8).background(scene.color.opacity(0.1), in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel("取消\(scene.title)")
    }
}
struct AssistantPresetCapsule: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(label, systemImage: label == "快速" ? "bolt.fill" : "sparkle")
                .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.primary.opacity(0.045), in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("assistant.mode-capsule")
    }
}

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
            HStack(spacing: 9) {
                if running { ProgressView().controlSize(.small).tint(.teal) }
                Text(running ? phase : "已完成 \(steps) 步查证")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
            }.font(.footnote).foregroundStyle(.secondary).frame(minHeight: 44).padding(.horizontal, 12).assistantSurface(radius: 12)
        }.buttonStyle(.plain).accessibilityIdentifier("assistant.phase")
    }
}

enum AssistantHistoryPresentation {
    static func status(_ summary: SessionSummary) -> String? {
        if summary.pendingRequestsCount > 0 && summary.pendingRequestKinds.contains(.input) { return "待回复" }
        if summary.active && summary.thinking { return "调查中" }
        return nil
    }
}
