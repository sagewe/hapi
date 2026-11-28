import Foundation
import HapiClient
import HapiProtocol
import Observation

/// Local draft until send. A failed upload/send retries the same allocated session/localId.
@MainActor @Observable
final class AssistantWorkbenchModel {
    var text = ""
    var scene: AssistantScene?
    var files: [PreparedAttachment] = []
    var presetID: String
    var useCodex = false
    private(set) var sending = false
    var pendingImports = 0
    var error: String?
    private(set) var allocatedSessionID: String?
    private var uploaded: [String: AttachmentMetadata] = [:]
    private let localID = UUID().uuidString
    private var voiceBase: String?
    private var voiceExpected: String?
    let session: HubSession
    var presets: [ClientModelPreset] { session.clientProfile?.modelPresets ?? [] }
    var preset: ClientModelPreset? { presets.first { $0.id == presetID } ?? session.clientProfile?.defaultModelPreset }
    var canSend: Bool { !sending && pendingImports == 0 && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty) }
    init(session: HubSession, useCodex: Bool = false) {
        self.session = session
        self.useCodex = useCodex
        let saved = UserDefaults.standard.string(forKey: "assistant.preset:\(session.hubUrl)")
        self.presetID = session.clientProfile?.modelPresets?.first { $0.id == saved }?.id
            ?? session.clientProfile?.defaultModelPreset?.id ?? ""
    }
    func removeFile(_ id: String) { guard allocatedSessionID == nil else { return }; files.removeAll { $0.id == id } }
    func selectPreset(_ preset: ClientModelPreset) {
        guard allocatedSessionID == nil else { return }
        presetID = preset.id
        UserDefaults.standard.set(presetID, forKey: "assistant.preset:\(session.hubUrl)")
    }
    func cyclePreset() {
        guard allocatedSessionID == nil, !presets.isEmpty else { return }
        let index = presets.firstIndex { $0.id == presetID } ?? -1
        selectPreset(presets[(index + 1) % presets.count])
    }
    func add(_ result: PrepareResult) {
        switch result {
        case .ready(let file): files.append(file)
        case .tooLarge: error = "文件较大，请选择 50 MB 以内的文件"
        case .unreadable: error = "暂时无法读取这个文件，请重新选择"
        }
    }
    func appendVoice(_ value: String) {
        guard !value.isEmpty else { return }
        text += (text.isEmpty ? "" : " ") + value
    }
    func beginVoiceEdit(_ partial: String) {
        voiceBase = text
        voiceExpected = text + (text.isEmpty || partial.isEmpty ? "" : " ") + partial
        text = voiceExpected ?? text
    }
    func refineVoiceEdit(_ final: String) {
        if text == voiceExpected, let base = voiceBase {
            text = base + (base.isEmpty || final.isEmpty ? "" : " ") + final
        }
        voiceExpected = nil; voiceBase = nil
    }
    func send() async -> String? {
        guard canSend else { return nil }
        sending = true; error = nil
        defer { sending = false }
        do {
            let id: String
            if let allocatedSessionID { id = allocatedSessionID }
            else {
                id = try await session.spawnAssistantSession(agent: useCodex ? .codex : nil, preset: preset)
                allocatedSessionID = id
            }
            for file in files where uploaded[file.id] == nil {
                let result = try await session.api.uploadFile(sessionId: id, filename: file.filename, data: file.bytes, mimeType: file.mimeType)
                guard result.success, let path = result.path else { throw AssistantSessionError.offline }
                let previewUrl = file.previewBytes.map {
                    AttachmentPolicy.dataUrl(mimeType: "image/jpeg", bytes: $0)
                }
                uploaded[file.id] = AttachmentMetadata(
                    id: file.id,
                    filename: file.filename,
                    mimeType: file.mimeType,
                    size: file.bytes.count,
                    path: path,
                    previewUrl: previewUrl
                )
            }
            let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = scene?.message(input.isEmpty ? "请审核所附资料。" : input) ?? (input.isEmpty ? "请核查所附资料。" : input)
            try await session.api.sendMessage(sessionId: id, text: message, localId: localID,
                attachments: files.compactMap { uploaded[$0.id] })
            return id
        } catch {
            self.error = allocatedSessionID == nil ? "后台调查服务暂时离线，请稍后重试" : "资料暂未发送成功，重试会继续当前调查"
            return nil
        }
    }
}
