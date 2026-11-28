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

struct AssistantChatPresetCapsule: View {
    let session: HubSession
    let sessionId: String
    @State private var applying = false
    @State private var failed = false
    private var presets: [ClientModelPreset] { session.clientProfile?.modelPresets ?? [] }
    private var selected: ClientModelPreset? {
        let detail = session.sessionStore.detail(for: sessionId)
        return presets.first { $0.matches(model: detail?.model, effort: detail?.effort) }
    }
    var body: some View {
        AssistantPresetCapsule(
            label: selected?.label ?? "深度",
            presets: presets,
            selectedID: selected?.id,
            onSelect: { apply($0) },
            action: {
                guard !presets.isEmpty else { return }
                let index = presets.firstIndex { $0.id == selected?.id } ?? -1
                apply(presets[(index + 1) % presets.count])
            }
        )
        .disabled(applying)
        .opacity(applying ? 0.65 : 1)
        .alert("切换暂未成功，请稍后重试", isPresented: $failed) { Button("好") {} }
    }

    private func apply(_ preset: ClientModelPreset) {
        guard !applying else { return }
        applying = true
        Task {
            do { try await session.api.setModel(sessionId: sessionId, model: .id(preset.model), effort: preset.effort) }
            catch { failed = true }
            applying = false
        }
    }
}
