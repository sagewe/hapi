import HapiProtocol
import SwiftUI

struct AssistantModelPresetPicker: View {
    let presets: [ClientModelPreset]
    @Binding var selection: String
    var disabled = false
    var body: some View {
        Picker("调查模式", selection: $selection) {
            ForEach(presets) { preset in Text(preset.label).tag(preset.id) }
        }
        .pickerStyle(.segmented)
        .disabled(disabled)
        .accessibilityIdentifier("assistant.model-preset")
    }
}

struct AssistantChatModelPicker: View {
    let session: HubSession
    let sessionId: String
    @State private var applying = false
    @State private var failed = false
    private var presets: [ClientModelPreset] { session.clientProfile?.modelPresets ?? [] }
    private var current: String {
        let detail = session.sessionStore.detail(for: sessionId)
        return presets.first { $0.matches(model: detail?.model, effort: detail?.effort) }?.id ?? ""
    }
    var body: some View {
        AssistantModelPresetPicker(presets: presets, selection: Binding(get: { current }, set: { id in
            guard let preset = presets.first(where: { $0.id == id }), !applying else { return }
            applying = true
            Task {
                do {
                    try await session.api.setModel(sessionId: sessionId, model: .id(preset.model), effort: preset.effort)
                } catch { failed = true }
                applying = false
            }
        }), disabled: applying)
        .frame(width: 136)
        .alert("切换暂未成功，请稍后重试", isPresented: $failed) { Button("好") {} }
    }
}
