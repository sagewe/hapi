import HapiProtocol
import SwiftUI

private struct AssistantModeKey: EnvironmentKey { static let defaultValue = false }
private struct ExecutionDetailsHiddenKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var executionDetailsHidden: Bool {
        get { self[ExecutionDetailsHiddenKey.self] }
        set { self[ExecutionDetailsHiddenKey.self] = newValue }
    }
    var isAssistantMode: Bool {
        get { self[AssistantModeKey.self] }
        set { self[AssistantModeKey.self] = newValue }
    }
}

enum AssistantSessionError: LocalizedError {
    case offline, configuration
    var errorDescription: String? {
        switch self {
        case .offline: "后台调查服务暂时离线，请稍后重试"
        case .configuration: "调查服务尚未配置完成，请联系管理员"
        }
    }
}

struct AssistantQuickActions: View {
    let actions: [ClientQuickAction]
    let select: (ClientQuickAction) -> Void
    var body: some View {
        VStack(spacing: 12) {
            ForEach(actions) { action in
                Button { select(action) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: action.icon ?? "magnifyingglass").frame(width: 26)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(action.title).font(.headline)
                            if let subtitle = action.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
            }
        }
    }
}

struct AssistantNewSessionSheet: View {
    let session: HubSession
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    @State private var advanced = false
    @State private var useCodex = false
    @State private var selectedPresetId: String
    init(session: HubSession, onCreated: @escaping (String) -> Void) {
        self.session = session
        self.onCreated = onCreated
        _selectedPresetId = State(initialValue: session.clientProfile?.defaultModelPreset?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("选择调查场景，进入后填写对象或上传资料。共用手机的语音、相机与文件入口。")
                        .foregroundStyle(.secondary)
                    if !useCodex, let presets = session.clientProfile?.modelPresets, !presets.isEmpty {
                        AssistantModelPresetPicker(presets: presets, selection: $selectedPresetId)
                    }
                    AssistantQuickActions(actions: session.clientProfile?.quickActions ?? []) { create($0.prompt) }
                    Button("直接新建空白调查", systemImage: "plus.bubble") { create(nil) }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, minHeight: 44)
                    if busy { ProgressView("正在准备调查…") }
                    if let error { Text(error).foregroundStyle(.red) }
                    DisclosureGroup("高级", isExpanded: $advanced) {
                        Toggle("使用 Codex 交叉核验", isOn: $useCodex)
                    }.font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .disabled(busy)
            .navigationTitle("新建调查")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
    private func create(_ prompt: String?) {
        busy = true; error = nil
        Task {
            do { onCreated(try await session.spawnAssistantSession(prompt: prompt, agent: useCodex ? .codex : nil,
                preset: session.clientProfile?.modelPresets?.first { $0.id == selectedPresetId })) }
            catch { self.error = (error as? AssistantSessionError)?.localizedDescription ?? "暂时无法创建调查，请稍后重试" }
            busy = false
        }
    }
}
