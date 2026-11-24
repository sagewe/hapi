import AVFAudio
import HapiClient
import HapiProtocol
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AssistantDraftComposer: View {
    @Bindable var draft: AssistantWorkbenchModel
    let send: () -> Void
    let focusChanged: (Bool) -> Void
    var attachmentRequest = false
    var focusRequest = false
    @State private var choices = false
    @State private var camera = false
    @State private var photos = false
    @State private var filePicker = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @FocusState private var focused: Bool
    @State private var holdArmed = false
    @State private var voiceFrame = CGRect.zero
    #if !targetEnvironment(macCatalyst)
    @State private var voice: HoldToDictateController
    #endif
    init(draft: AssistantWorkbenchModel, attachmentRequest: Bool, focusRequest: Bool = false, focusChanged: @escaping (Bool) -> Void = { _ in }, send: @escaping () -> Void) {
        self.draft = draft; self.attachmentRequest = attachmentRequest; self.focusRequest = focusRequest; self.send = send; self.focusChanged = focusChanged
        #if !targetEnvironment(macCatalyst)
        _voice = State(initialValue: HoldToDictateController(api: draft.session.api,
            streamer: HubStreamingAsrClient(api: draft.session.api), recorder: PCMStreamingAudioRecorder()))
        #endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let scene = draft.scene { AssistantSceneChip(scene: scene) { draft.scene = nil; focused = false }.disabled(draft.allocatedSessionID != nil) }
            if !draft.files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(draft.files, id: \.id) { (file: PreparedAttachment) in
                            AssistantLocalFileChip(file: file, remove: { draft.removeFile(file.id) })
                        }
                    }
                }
            }
            ZStack(alignment: .leading) {
                if draft.text.isEmpty {
                    Text(draft.scene?.placeholder ?? "输入线索，或添加单据…")
                        .foregroundStyle(.secondary).allowsHitTesting(false)
                }
                TextField("", text: $draft.text, axis: .vertical)
                    .lineLimit(1...6).focused($focused).accessibilityLabel("调查线索")
                    .accessibilityIdentifier("assistant.draft-input").disabled(draft.allocatedSessionID != nil)
            }.font(.body).padding(.vertical, 6)
            #if !targetEnvironment(macCatalyst)
            if !focused, voice.isAvailable, draft.allocatedSessionID == nil {
                Label("按住说话", systemImage: "mic").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
                    .background(GeometryReader { proxy in Color.clear.onAppear { voiceFrame = proxy.frame(in: .global) } })
                    .gesture(LongPressGesture(minimumDuration: 0.2).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                        .onChanged { value in
                            switch value {
                            case .first(true): holdArmed = true; beginVoice()
                            case .second(true, let drag):
                                if !holdArmed { holdArmed = true; beginVoice() }
                                if let drag { voice.updateFinger(fingerX: drag.location.x, fingerY: drag.location.y, containerWidth: UIScreen.main.bounds.width, containerHeight: UIScreen.main.bounds.height) }
                            default: break
                            }
                        }.onEnded { _ in holdArmed = false; voice.endHold() })
            }
            #endif
            HStack(spacing: 12) {
                Button { choices = true } label: { Image(systemName: "plus").font(.system(size: 20)).frame(width: 36, height: 36) }
                    .accessibilityLabel("添加图片或文件").disabled(draft.allocatedSessionID != nil)
                if draft.useCodex { Text("交叉核验").font(.caption).foregroundStyle(.secondary) }
                else { AssistantPresetCapsule(label: draft.preset?.label ?? "深度") { draft.cyclePreset() } }
                Spacer(minLength: 4)
                #if !targetEnvironment(macCatalyst)
                if voice.isRefiningSend || voice.isRefiningEdit { ProgressView().controlSize(.small) }
                #endif
                Button(action: send) {
                    Group { if draft.sending { ProgressView().tint(.white) } else { Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold)) } }
                        .frame(width: 38, height: 38).foregroundStyle(AssistantDesign.surface)
                        .background(draft.canSend ? Color.primary : Color.secondary.opacity(0.3), in: Circle())
                }.disabled(!draft.canSend || voiceBusy).accessibilityLabel("发送调查")
            }.foregroundStyle(.primary)
            if draft.pendingImports > 0 { ProgressView("正在准备资料…").font(.caption) }
            if let error = draft.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(16).assistantSurface().padding(.horizontal, 16).padding(.bottom, 10)
        .disabled(draft.sending)
        .confirmationDialog("添加资料", isPresented: $choices) {
            #if !targetEnvironment(macCatalyst)
            Button("拍照") { if CameraCaptureView.isAvailable { camera = true } else { draft.error = "当前设备无法使用相机，请选择图片或文件" } }
            #endif
            Button("相册图片") { photos = true }
            Button("选择文件（PDF / ZIP / Office）") { filePicker = true }
        }
        .photosPicker(isPresented: $photos, selection: $pickedPhotos, matching: .images)
        .onChange(of: pickedPhotos) { _, values in
            guard !values.isEmpty else { return }
            draft.pendingImports += 1
            Task {
                defer { draft.pendingImports -= 1 }
                for item in values {
                    if let bytes = try? await item.loadTransferable(type: Data.self) {
                        let name = AttachmentPreparer.photoFilename(for: item.supportedContentTypes.first)
                        draft.add(await AttachmentPreparer.prepare(data: bytes, filename: name.filename, mimeType: name.mimeType))
                    }
                }
                pickedPhotos = []; focused = true
            }
        }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                draft.pendingImports += 1
                Task { defer { draft.pendingImports -= 1 }; for url in urls { draft.add(await AttachmentPreparer.prepare(fileURL: url)) }; focused = true }
            }
        }
        #if !targetEnvironment(macCatalyst)
        .fullScreenCover(isPresented: $camera) { CameraCaptureView { data in
            draft.pendingImports += 1
            Task { defer { draft.pendingImports -= 1 }; draft.add(await AttachmentPreparer.prepare(data: data, filename: AttachmentPreparer.cameraFilename(), mimeType: "image/jpeg")); focused = true }
        } }
        .overlay { WeChatVoiceOverlayHost(controller: voice) }
        .task {
            voice.onOutcome = { outcome in
                switch outcome {
                case .finishSend(_, let text): draft.appendVoice(text)
                case .beginInlineEdit(let partial): draft.beginVoiceEdit(partial); focused = true
                case .refineInlineEdit(let text): draft.refineVoiceEdit(text)
                case .error(let message): draft.error = message
                default: break
                }
            }
            await voice.refreshAvailability()
        }
        .onDisappear { voice.cancelIfHolding() }
        #endif
        .onChange(of: focused) { _, value in focusChanged(value) }
        .onChange(of: attachmentRequest) { _, _ in choices = true }
        .onChange(of: focusRequest) { _, _ in focused = true }
    }
    private var voiceBusy: Bool {
        #if !targetEnvironment(macCatalyst)
        voice.phase.isOverlayActive || voice.isRefiningSend || voice.isRefiningEdit
        #else
        false
        #endif
    }
    #if !targetEnvironment(macCatalyst)
    private func beginVoice() {
        guard voice.phase == .idle else { return }
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            if granted && holdArmed { voice.context = VoiceRecognitionContext(draft: draft.text); voice.beginHold(fingerX: voiceFrame.midX, fingerY: voiceFrame.midY, containerWidth: UIScreen.main.bounds.width, containerHeight: UIScreen.main.bounds.height) }
            else { draft.error = "请在系统设置中允许麦克风访问" }
        }
    }
    #endif
}

private struct AssistantLocalFileChip: View {
    let file: PreparedAttachment
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            if let bytes = file.previewBytes, let image = UIImage(data: bytes) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7))
            } else { FileTypeBadge(name: file.filename) }
            Text(file.filename).font(.caption).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        }.padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
