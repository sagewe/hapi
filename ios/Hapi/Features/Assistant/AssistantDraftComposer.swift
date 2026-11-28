import AVFAudio
import HapiClient
import HapiProtocol
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Compact Liquid Glass composer card with always-accessible in-composer mode switching (`快速 | 深度`),
/// clean monochrome attachment cards, and MyDots hold-to-speak / send ergonomics.
struct AssistantDraftComposer: View {
    @Bindable var draft: AssistantWorkbenchModel
    let send: () -> Void
    let onToggleCodex: () -> Void
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
        onToggleCodex: @escaping () -> Void = {},
        focusChanged: @escaping (Bool) -> Void = { _ in },
        send: @escaping () -> Void
    ) {
        self.draft = draft
        self.attachmentRequest = attachmentRequest
        self.focusRequest = focusRequest
        self.onToggleCodex = onToggleCodex
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

    private var showsSendAction: Bool {
        draft.canSend || draft.sending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let scene = draft.scene {
                AssistantSceneChip(scene: scene) {
                    withAnimation(.snappy(duration: 0.2)) { draft.scene = nil }
                    focused = false
                }
                .disabled(draft.allocatedSessionID != nil)
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            }

            if !draft.files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(draft.files, id: \.id) { (file: PreparedAttachment) in
                            AssistantLocalFileChip(file: file) {
                                withAnimation(.snappy(duration: 0.2)) { draft.removeFile(file.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                }
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }

            ZStack(alignment: .leading) {
                if draft.text.isEmpty {
                    Text(draft.scene?.placeholder ?? "输入线索，或按住右侧说话…")
                        .font(.system(size: 16))
                        .foregroundStyle(AssistantDesign.inkMuted)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: $draft.text, axis: .vertical)
                    .font(.system(size: 16))
                    .foregroundStyle(AssistantDesign.ink)
                    .lineLimit(1...6)
                    .focused($focused)
                    .accessibilityLabel("调查线索")
                    .accessibilityIdentifier("assistant.draft-input")
                    .disabled(draft.allocatedSessionID != nil)
            }
            .frame(minHeight: 36)
            .padding(.horizontal, 10)
            .padding(.top, 2)

            HStack(alignment: .center, spacing: 8) {
                attachButton

                if draft.useCodex {
                    Button(action: onToggleCodex) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10, weight: .semibold))
                            Text("交叉核验")
                                .font(.caption.weight(.semibold))
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .opacity(0.65)
                        }
                        .foregroundStyle(AssistantDesign.risk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AssistantDesign.risk.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("退出交叉核验")
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
                    holdVoiceButton(compact: showsSendAction)
                }
                #endif

                if showsSendAction {
                    sendButton
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 2)

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
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background {
            AssistantComposerCardSurface(cornerRadius: 24, focused: focused)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { composerBounds = $0 }
        .overlay(alignment: .bottomLeading) {
            if attachPopover {
                attachmentPopoverCard
                    .frame(width: min(252, max(206, composerBounds.width)))
                    .offset(y: -composerBounds.height - 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: attachPopover)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: showsSendAction)
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
                .font(.system(size: attachPopover ? 14 : 18, weight: .medium))
                .foregroundStyle(attachPopover ? AssistantDesign.accent : AssistantDesign.ink)
                .frame(width: 36, height: 36)
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
            Divider()
                .overlay(AssistantDesign.border)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            popoverRow(
                draft.useCodex ? "切回标准调查" : "用 Codex 交叉核验",
                symbol: draft.useCodex ? "checkmark.shield" : "arrow.triangle.branch",
                action: onToggleCodex
            )
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
                    .foregroundStyle(AssistantDesign.inkSecondary)
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

    private var sendButton: some View {
        Button(action: send) {
            Group {
                if draft.sending {
                    ProgressView().tint(AssistantDesign.inkOnSolid)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                }
            }
            .frame(width: 36, height: 36)
            .foregroundStyle(draft.canSend ? AssistantDesign.inkOnSolid : AssistantDesign.inkMuted.opacity(0.65))
            .background {
                if draft.canSend {
                    Circle().fill(AssistantDesign.ink)
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
            .foregroundStyle(
                holdArmed ? .white : (compact ? AssistantDesign.inkSecondary : AssistantDesign.inkOnSolid)
            )
            .frame(width: 36, height: 36)
            .background {
                if holdArmed {
                    Circle().fill(AssistantDesign.accentGradient)
                } else if !compact {
                    Circle().fill(AssistantDesign.ink)
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

    private var extLabel: String {
        let ext = (file.filename as NSString).pathExtension.uppercased()
        if ext.isEmpty { return "文件" }
        return ext == "DOCX" ? "DOC" : ext == "XLSX" ? "XLS" : String(ext.prefix(4))
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(file.bytes.count), countStyle: .file)
    }

    var body: some View {
        if let bytes = file.previewBytes, let image = UIImage(data: bytes) {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(AssistantDesign.border, lineWidth: 0.5)
                    )
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color.black.opacity(0.62), in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .accessibilityLabel("移除 \(file.filename)")
            }
            .padding(.top, 4)
            .padding(.trailing, 4)
        } else {
            HStack(spacing: 9) {
                FileTypeBadge(name: file.filename, compact: true)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(file.filename)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(AssistantDesign.ink)
                        .lineLimit(1)
                    Text("\(extLabel) · \(sizeLabel)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(AssistantDesign.inkMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: 136, alignment: .leading)
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AssistantDesign.inkMuted)
                        .frame(width: 22, height: 22)
                        .background(AssistantDesign.surfaceMuted, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除 \(file.filename)")
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(height: 48)
            .background(AssistantDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(AssistantDesign.border, lineWidth: 0.5)
            )
        }
    }
}
