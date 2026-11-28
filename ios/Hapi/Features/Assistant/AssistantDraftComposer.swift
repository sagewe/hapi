import AVFAudio
import HapiClient
import HapiProtocol
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// MyDots-native Liquid Glass composer for QiqiWork workbench:
/// - Tap anywhere on the input area to focus keyboard; hold anywhere (or pull upward / hold right voice circle)
///   for full-screen WeChat/MyDots Hold-to-Dictate.
/// - Releasing on "松手 发送" immediately submits the investigation; sliding right to "文 编辑" edits inline.
/// - Single compact `✦ 深度` / `⚡ 快速` capsule lives in the bottom-left tool row.
struct AssistantDraftComposer: View {
    @Bindable var draft: AssistantWorkbenchModel
    #if !targetEnvironment(macCatalyst)
    let voice: HoldToDictateController
    #endif
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
    @State private var textFocused = false
    @State private var textSelection = NSRange(location: 0, length: 0)
    @State private var textComposing = false
    @State private var composerBounds = CGRect.zero

    #if !targetEnvironment(macCatalyst)
    init(
        draft: AssistantWorkbenchModel,
        voice: HoldToDictateController,
        attachmentRequest: Bool,
        focusRequest: Bool = false,
        onToggleCodex: @escaping () -> Void = {},
        focusChanged: @escaping (Bool) -> Void = { _ in },
        send: @escaping () -> Void
    ) {
        self.draft = draft
        self.voice = voice
        self.attachmentRequest = attachmentRequest
        self.focusRequest = focusRequest
        self.onToggleCodex = onToggleCodex
        self.send = send
        self.focusChanged = focusChanged
    }
    #else
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
    }
    #endif

    private var showsSendAction: Bool {
        draft.canSend || draft.sending
    }

    private var placeholderText: String {
        if let custom = draft.scene?.placeholder { return custom }
        #if !targetEnvironment(macCatalyst)
        if !textFocused && voice.isAvailable && draft.allocatedSessionID == nil {
            return "可按住说话，或输入线索…"
        }
        #endif
        return "输入调查线索，或添加单据…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let scene = draft.scene {
                AssistantSceneChip(scene: scene) {
                    withAnimation(.snappy(duration: 0.2)) { draft.scene = nil }
                    textFocused = false
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

            inputField
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)

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
                        .frame(height: 32)
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
                        .frame(width: 36, height: 36)
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
            AssistantComposerCardSurface(cornerRadius: 24, focused: textFocused)
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
                textFocused = true
            }
        }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                draft.pendingImports += 1
                Task {
                    defer { draft.pendingImports -= 1 }
                    for url in urls { draft.add(await AttachmentPreparer.prepare(fileURL: url)) }
                    textFocused = true
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
                    textFocused = true
                }
            }
        }
        .task(id: ObjectIdentifier(voice)) {
            voice.onOutcome = { outcome in
                switch outcome {
                case .finishSend(_, let text):
                    draft.appendVoice(text)
                    send()
                case .beginInlineEdit(let partial):
                    draft.beginVoiceEdit(partial)
                    textFocused = true
                case .refineInlineEdit(let text):
                    draft.refineVoiceEdit(text)
                case .error(let message):
                    draft.error = message
                default:
                    break
                }
            }
            await voice.refreshAvailability()
        }
        .onDisappear { voice.cancelIfHolding() }
        #endif
        .onChange(of: textFocused) { _, value in
            if value { attachPopover = false }
            focusChanged(value)
        }
        .onChange(of: attachmentRequest) { _, _ in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                attachPopover = true
            }
        }
        .onChange(of: focusRequest) { _, _ in textFocused = true }
    }

    // MARK: - MyDots Tap-or-Hold Input Field

    private var inputField: some View {
        ZStack(alignment: .topLeading) {
            if draft.text.isEmpty && !textComposing {
                Text(placeholderText)
                    .font(.system(size: 16))
                    .foregroundStyle(AssistantDesign.inkMuted)
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }
            #if targetEnvironment(macCatalyst)
            ComposerTextView(
                text: $draft.text,
                selection: $textSelection,
                isFocused: $textFocused,
                isComposing: $textComposing,
                font: .systemFont(ofSize: 16),
                accessibilityLabel: "调查线索",
                onReturn: {
                    guard draft.canSend else { return false }
                    send()
                    return true
                }
            )
            #else
            ComposerTextView(
                text: $draft.text,
                selection: $textSelection,
                isFocused: $textFocused,
                isComposing: $textComposing,
                font: .systemFont(ofSize: 16),
                accessibilityLabel: "调查线索",
                onReturn: {
                    guard draft.canSend else { return false }
                    send()
                    return true
                },
                holdToDictateEnabled: voice.isAvailable && draft.allocatedSessionID == nil,
                hitTestOutsets: UIEdgeInsets(top: 10, left: 10, bottom: 4, right: 10),
                onHoldBegan: { location, windowSize in
                    beginVoiceHold(location: location, windowSize: windowSize)
                },
                onHoldChanged: { location, windowSize in
                    updateVoiceHold(location: location, windowSize: windowSize)
                },
                onHoldEnded: {
                    voice.endHold()
                },
                onHoldCancelled: {
                    voice.cancelIfHolding()
                }
            )
            #endif
        }
        .frame(minHeight: 28)
        .disabled(draft.allocatedSessionID != nil)
        .accessibilityIdentifier("assistant.draft-input")
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
        let holding = voice.phase.isOverlayActive
        return Image(systemName: holding ? "waveform" : (compact ? "mic.fill" : "waveform"))
            .font(.system(size: compact ? 15 : 16, weight: .semibold))
            .foregroundStyle(
                holding ? .white : (compact ? AssistantDesign.inkSecondary : AssistantDesign.inkOnSolid)
            )
            .frame(width: 36, height: 36)
            .background {
                if holding {
                    Circle().fill(AssistantDesign.accentGradient)
                } else if !compact {
                    Circle().fill(AssistantDesign.ink)
                } else {
                    Circle().fill(AssistantDesign.surfaceMuted)
                }
            }
            .overlay {
                VoicePrimaryTouchSurface(
                    a11yLabel: "按住说话",
                    a11yIdentifier: "assistant.voice-button",
                    holdEnabled: voice.isAvailable && draft.allocatedSessionID == nil,
                    onTap: {
                        draft.error = "按住输入框或右侧语音键即可说话"
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            if draft.error == "按住输入框或右侧语音键即可说话" {
                                draft.error = nil
                            }
                        }
                    },
                    onHoldBegan: { location, windowSize in
                        beginVoiceHold(location: location, windowSize: windowSize)
                    },
                    onHoldChanged: { location, windowSize in
                        updateVoiceHold(location: location, windowSize: windowSize)
                    },
                    onHoldEnded: {
                        voice.endHold()
                    },
                    onHoldCancelled: {
                        voice.cancelIfHolding()
                    }
                )
            }
    }

    private func beginVoiceHold(location: CGPoint, windowSize: CGSize) {
        guard case .idle = voice.phase else { return }
        attachPopover = false
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            textFocused = false
            voice.context = VoiceRecognitionContext(draft: draft.text)
            voice.beginHold(
                fingerX: Double(location.x),
                fingerY: Double(location.y),
                containerWidth: Double(windowSize.width),
                containerHeight: Double(windowSize.height)
            )
        case .denied:
            draft.error = "请在系统设置中允许麦克风访问"
        case .undetermined:
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                if !granted {
                    draft.error = "请在系统设置中允许麦克风访问"
                }
            }
        @unknown default:
            break
        }
    }

    private func updateVoiceHold(location: CGPoint, windowSize: CGSize) {
        guard case .holding = voice.phase else { return }
        voice.updateFinger(
            fingerX: Double(location.x),
            fingerY: Double(location.y),
            containerWidth: Double(windowSize.width),
            containerHeight: Double(windowSize.height)
        )
    }
    #endif

    private var voiceBusy: Bool {
        #if !targetEnvironment(macCatalyst)
        voice.phase.isOverlayActive || voice.isRefiningSend || voice.isRefiningEdit
        #else
        false
        #endif
    }
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
