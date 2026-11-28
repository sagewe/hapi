import AVFAudio
import HapiClient
import HapiProtocol
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Two-stage Liquid Glass composer modeled on MyDots `MainChatColumnView.composerBar`:
/// - Collapsed single-row smoky glass pill (`cornerRadius: 25`) when idle & empty
/// - Expanded two-row Liquid Glass card (`cornerRadius: 24`) when focused, holding text/files/scene, or opening attachment popover
struct AssistantDraftComposer: View {
    @Bindable var draft: AssistantWorkbenchModel
    let send: () -> Void
    let focusChanged: (Bool) -> Void
    var attachmentRequest = false
    var focusRequest = false
    @State private var attachPopover = false
    @State private var camera = false
    @State private var photos = false
    @State private var filePicker = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @FocusState private var focused: Bool
    @State private var holdArmed = false
    @State private var voiceFrame = CGRect.zero
    @State private var composerBounds = CGRect.zero
    #if !targetEnvironment(macCatalyst)
    @State private var voice: HoldToDictateController
    #endif

    init(
        draft: AssistantWorkbenchModel,
        attachmentRequest: Bool,
        focusRequest: Bool = false,
        focusChanged: @escaping (Bool) -> Void = { _ in },
        send: @escaping () -> Void
    ) {
        self.draft = draft
        self.attachmentRequest = attachmentRequest
        self.focusRequest = focusRequest
        self.send = send
        self.focusChanged = focusChanged
        #if !targetEnvironment(macCatalyst)
        _voice = State(initialValue: HoldToDictateController(
            api: draft.session.api,
            streamer: HubStreamingAsrClient(api: draft.session.api),
            recorder: PCMStreamingAudioRecorder()
        ))
        #endif
    }

    private var isCollapsed: Bool {
        !focused
            && draft.text.isEmpty
            && draft.files.isEmpty
            && draft.scene == nil
            && draft.pendingImports == 0
            && draft.error == nil
            && !draft.sending
            && !holdArmed
            && !attachPopover
            && !voiceBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCollapsed ? 0 : 8) {
            if !isCollapsed, let scene = draft.scene {
                AssistantSceneChip(scene: scene) {
                    withAnimation(.snappy(duration: 0.2)) { draft.scene = nil }
                    focused = false
                }
                .disabled(draft.allocatedSessionID != nil)
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            }

            if !isCollapsed, !draft.files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(draft.files, id: \.id) { (file: PreparedAttachment) in
                            AssistantLocalFileChip(file: file) {
                                withAnimation(.snappy(duration: 0.2)) { draft.removeFile(file.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                }
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }

            HStack(alignment: .center, spacing: isCollapsed ? 6 : 0) {
                if isCollapsed {
                    attachButton
                        .transition(.opacity)
                }

                ZStack(alignment: .leading) {
                    if draft.text.isEmpty {
                        Text(draft.scene?.placeholder ?? (isCollapsed ? "输入线索，或长按右侧说话…" : "输入线索，或添加单据…"))
                            .font(.system(size: 16))
                            .foregroundStyle(AssistantDesign.inkMuted)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $draft.text, axis: .vertical)
                        .font(.system(size: 16))
                        .foregroundStyle(AssistantDesign.ink)
                        .lineLimit(isCollapsed ? 1...1 : 1...6)
                        .focused($focused)
                        .accessibilityLabel("调查线索")
                        .accessibilityIdentifier("assistant.draft-input")
                        .disabled(draft.allocatedSessionID != nil)
                }
                .frame(minHeight: 38)
                .padding(.horizontal, isCollapsed ? 2 : 10)

                if isCollapsed {
                    collapsedTrailingButton
                        .transition(.opacity)
                }
            }

            if !isCollapsed {
                HStack(alignment: .center, spacing: 8) {
                    attachButton

                    if draft.useCodex {
                        Text("交叉核验")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AssistantDesign.risk)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(AssistantDesign.risk.opacity(0.14), in: Capsule())
                    } else {
                        AssistantPresetCapsule(
                            label: draft.preset?.label ?? "深度",
                            presets: draft.presets,
                            selectedID: draft.preset?.id,
                            onSelect: { draft.selectPreset($0) },
                            action: { draft.cyclePreset() }
                        )
                        .disabled(draft.allocatedSessionID != nil)
                    }

                    Spacer(minLength: 4)

                    #if !targetEnvironment(macCatalyst)
                    if voice.isRefiningSend || voice.isRefiningEdit {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AssistantDesign.accent)
                    } else if voice.isAvailable, draft.allocatedSessionID == nil {
                        holdVoiceButton(compact: true)
                    }
                    #endif

                    sendButton
                }
                .padding(.horizontal, 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if draft.pendingImports > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(AssistantDesign.accent)
                    Text("正在准备资料…").font(.caption).foregroundStyle(AssistantDesign.inkMuted)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            }

            if let error = draft.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(AssistantDesign.report)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, isCollapsed ? 7 : 8)
        .padding(.vertical, isCollapsed ? 6 : 6)
        .background {
            AssistantComposerCardSurface(cornerRadius: isCollapsed ? 25 : 24, focused: focused)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { composerBounds = $0 }
        .overlay(alignment: .bottomLeading) {
            if attachPopover {
                attachmentPopoverCard
                    .frame(width: min(244, max(200, composerBounds.width)))
                    .offset(y: -composerBounds.height - 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: isCollapsed)
        .animation(.spring(response: 0.22, dampingFraction: 0.84), value: attachPopover)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: draft.canSend)
        .disabled(draft.sending)
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
                pickedPhotos = []
                focused = true
            }
        }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                draft.pendingImports += 1
                Task {
                    defer { draft.pendingImports -= 1 }
                    for url in urls { draft.add(await AttachmentPreparer.prepare(fileURL: url)) }
                    focused = true
                }
            }
        }
        #if !targetEnvironment(macCatalyst)
        .fullScreenCover(isPresented: $camera) {
            CameraCaptureView { data in
                draft.pendingImports += 1
                Task {
                    defer { draft.pendingImports -= 1 }
                    draft.add(await AttachmentPreparer.prepare(data: data, filename: AttachmentPreparer.cameraFilename(), mimeType: "image/jpeg"))
                    focused = true
                }
            }
        }
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
        .onChange(of: focused) { _, value in
            if value { attachPopover = false }
            focusChanged(value)
        }
        .onChange(of: attachmentRequest) { _, _ in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                attachPopover = true
            }
        }
        .onChange(of: focusRequest) { _, _ in focused = true }
    }

    // MARK: - Controls

    private var attachButton: some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                attachPopover.toggle()
            }
        } label: {
            Image(systemName: attachPopover ? "xmark" : "plus")
                .font(.system(size: attachPopover ? 14 : 19, weight: .medium))
                .foregroundStyle(attachPopover ? AssistantDesign.accent : AssistantDesign.ink)
                .frame(width: isCollapsed ? 38 : 40, height: isCollapsed ? 38 : 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("添加图片或文件")
        .disabled(draft.allocatedSessionID != nil)
    }

    private var attachmentPopoverCard: some View {
        VStack(spacing: 0) {
            #if !targetEnvironment(macCatalyst)
            popoverRow("拍照", symbol: "camera") {
                if CameraCaptureView.isAvailable { camera = true }
                else { draft.error = "当前设备无法使用相机，请选择图片或文件" }
            }
            #endif
            popoverRow("相册图片", symbol: "photo") { photos = true }
            popoverRow("选择文件（PDF / ZIP / Office）", symbol: "doc.text") { filePicker = true }
        }
        .padding(8)
        .background { AssistantComposerCardSurface(cornerRadius: 22) }
    }

    private func popoverRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            attachPopover = false
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AssistantDesign.accent)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(AssistantDesign.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var collapsedTrailingButton: some View {
        #if !targetEnvironment(macCatalyst)
        if voice.isAvailable, draft.allocatedSessionID == nil {
            holdVoiceButton(compact: false)
        } else {
            sendButton
        }
        #else
        sendButton
        #endif
    }

    private var sendButton: some View {
        Button(action: send) {
            Group {
                if draft.sending {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                }
            }
            .frame(width: 36, height: 36)
            .foregroundStyle(draft.canSend ? Color.white : AssistantDesign.inkMuted.opacity(0.65))
            .background {
                if draft.canSend {
                    Circle().fill(AssistantDesign.accentGradient)
                } else {
                    Circle().fill(AssistantDesign.surfaceMuted)
                }
            }
        }
        .buttonStyle(AssistantPressStyle(scale: 0.92))
        .disabled(!draft.canSend || voiceBusy)
        .sensoryFeedback(.impact(weight: .medium), trigger: draft.sending)
        .accessibilityLabel("发送调查")
    }

    #if !targetEnvironment(macCatalyst)
    private func holdVoiceButton(compact: Bool) -> some View {
        Image(systemName: holdArmed ? "waveform" : (compact ? "mic.fill" : "waveform"))
            .font(.system(size: compact ? 15 : 16, weight: .semibold))
            .foregroundStyle(compact ? (holdArmed ? .white : AssistantDesign.inkSecondary) : .white)
            .frame(width: 36, height: 36)
            .background {
                if !compact || holdArmed {
                    Circle().fill(AssistantDesign.accentGradient)
                } else {
                    Circle().fill(AssistantDesign.surfaceMuted)
                }
            }
            .scaleEffect(holdArmed ? 0.92 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: holdArmed)
            .contentShape(Circle())
            .background(
                GeometryReader { proxy in
                    Color.clear.onAppear { voiceFrame = proxy.frame(in: .global) }
                }
            )
            .gesture(
                LongPressGesture(minimumDuration: 0.18)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                    .onChanged { value in
                        switch value {
                        case .first(true):
                            holdArmed = true
                            beginVoice()
                        case .second(true, let drag):
                            if !holdArmed { holdArmed = true; beginVoice() }
                            if let drag {
                                voice.updateFinger(
                                    fingerX: drag.location.x,
                                    fingerY: drag.location.y,
                                    containerWidth: UIScreen.main.bounds.width,
                                    containerHeight: UIScreen.main.bounds.height
                                )
                            }
                        default:
                            break
                        }
                    }
                    .onEnded { _ in
                        holdArmed = false
                        voice.endHold()
                    }
            )
            .accessibilityLabel("按住说话")
    }
    #endif

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
            if granted && holdArmed {
                voice.context = VoiceRecognitionContext(draft: draft.text)
                voice.beginHold(
                    fingerX: voiceFrame.midX,
                    fingerY: voiceFrame.midY,
                    containerWidth: UIScreen.main.bounds.width,
                    containerHeight: UIScreen.main.bounds.height
                )
            } else {
                draft.error = "请在系统设置中允许麦克风访问"
            }
        }
    }
    #endif
}

private struct AssistantLocalFileChip: View {
    let file: PreparedAttachment
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 7) {
            if let bytes = file.previewBytes, let image = UIImage(data: bytes) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                FileTypeBadge(name: file.filename, compact: true)
            }
            Text(file.filename)
                .font(.caption.weight(.medium))
                .foregroundStyle(AssistantDesign.ink)
                .lineLimit(1)
                .frame(maxWidth: 148, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(AssistantDesign.inkMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(AssistantDesign.surfaceMuted, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
