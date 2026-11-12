#if !targetEnvironment(macCatalyst)
import HapiClient
import HapiUI
import SwiftUI
import UIKit

/// Full-screen Hold-to-Dictate & Focused Voice Edit overlays (iOS only),
/// unified with MyDots' lower-screen thumb layout and harmonized with `HapiTheme`.
struct WeChatVoiceOverlayHost: View {
    let controller: HoldToDictateController
    var canSendAndSteer: Bool = false
    var onSteerSend: ((String) -> Void)?

    var body: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .holding(let zone, let partialText, _):
            WeChatHoldDictationOverlay(
                zone: zone,
                partialText: partialText,
                audioLevels: controller.audioLevels,
                isFinalizing: false
            )
            .allowsHitTesting(false)
            .transition(.opacity.animation(.easeOut(duration: 0.14)))
        case .finalizing(let zone, let partialText):
            WeChatHoldDictationOverlay(
                zone: zone,
                partialText: partialText,
                audioLevels: controller.audioLevels,
                isFinalizing: true
            )
            .allowsHitTesting(false)
            .transition(.opacity.animation(.easeOut(duration: 0.14)))
        case .editing(let currentText):
            WeChatVoiceEditOverlay(
                controllerText: currentText,
                isRefining: controller.isRefiningEdit,
                canSendAndSteer: canSendAndSteer,
                onTextChanged: { controller.updateEditingText($0) },
                onCancel: { controller.dismissOverlay() },
                onSend: { text, steer in
                    if steer, let onSteerSend {
                        controller.dismissOverlay()
                        onSteerSend(text)
                    } else {
                        controller.confirmEditSend(text)
                    }
                }
            )
            .transition(.opacity.animation(.easeOut(duration: 0.16)))
        }
    }
}

// MARK: - Unified Lower-Screen Hold-to-Dictate Overlay

private struct WeChatHoldDictationOverlay: View {
    let zone: HoldActionZone
    let partialText: String
    let audioLevels: [Float]
    let isFinalizing: Bool

    @Environment(\.hapiTheme) private var theme

    private var scrimTint: Color {
        switch theme.variant {
        case .light:
            return Color(red: 0.95, green: 0.96, blue: 0.98).opacity(0.46)
        case .dark:
            return Color.black.opacity(0.54)
        case .oled:
            return Color.black.opacity(0.72)
        }
    }

    private var bubbleBackground: Color {
        switch zone {
        case .send:
            switch theme.variant {
            case .light:
                return Color(red: 0.93, green: 0.96, blue: 1.00)
            case .dark:
                return Color(red: 0.10, green: 0.15, blue: 0.24)
            case .oled:
                return Color(red: 0.07, green: 0.11, blue: 0.19)
            }
        case .cancel:
            return theme.diffRemovedBackground
        case .edit:
            return theme.surface
        }
    }

    private var bubbleStroke: Color {
        switch zone {
        case .send:
            return theme.accent.opacity(theme.isDark ? 0.44 : 0.34)
        case .cancel:
            return theme.danger.opacity(0.46)
        case .edit:
            return theme.textPrimary.opacity(0.22)
        }
    }

    private var bubbleTextColor: Color {
        zone == .cancel ? theme.danger : theme.textPrimary
    }

    private var bubblePlaceholderColor: Color {
        zone == .cancel ? theme.danger.opacity(0.82) : theme.textSecondary
    }

    private var waveformColor: Color {
        switch zone {
        case .send:
            return theme.accent
        case .cancel:
            return theme.danger.opacity(0.86)
        case .edit:
            return theme.textSecondary
        }
    }

    private var hintTitle: String {
        if isFinalizing {
            return "正在识别文字…"
        }
        switch zone {
        case .send:
            return "松手 发送"
        case .cancel:
            return "松开 取消"
        case .edit:
            return "松开 编辑文字"
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(scrimTint)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                speechBubble
                    .padding(.horizontal, 28)
                    .padding(.bottom, 48)

                actionBadgesRow
                    .padding(.horizontal, 44)
                    .padding(.bottom, 18)

                Text(hintTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(zone == .cancel ? theme.danger : theme.textSecondary)
                    .padding(.bottom, 14)

                bottomArcPad
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: zone)
        .onChange(of: zone) { _, _ in
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private var speechBubble: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isFinalizing && partialText.isEmpty {
                    Text("正在识别…")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(bubblePlaceholderColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !partialText.isEmpty {
                    Text(partialText)
                        .font(.system(size: 17.5, weight: .medium))
                        .lineSpacing(3)
                        .foregroundStyle(bubbleTextColor)
                        .lineLimit(6)
                        .truncationMode(.head)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("正在聆听…")
                        .font(.system(size: 16.5, weight: .medium))
                        .foregroundStyle(bubblePlaceholderColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isFinalizing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(waveformColor)
                }
            }

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                ForEach(Array(audioLevels.enumerated()), id: \.offset) { _, rawLevel in
                    let level = CGFloat(min(max(rawLevel, 0.10), 1.0))
                    Capsule()
                        .fill(waveformColor.opacity(isFinalizing ? 0.45 : 0.90))
                        .frame(width: 3.2, height: max(5, 24 * level))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 26)
            .animation(.easeOut(duration: 0.08), value: audioLevels)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(minHeight: 96)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(bubbleBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(bubbleStroke, lineWidth: 1.2)
        )
        .shadow(
            color: Color.black.opacity(theme.isDark ? 0.34 : 0.10),
            radius: 18,
            y: 8
        )
    }

    private var actionBadgesRow: some View {
        HStack {
            zoneBadge(
                title: "✕",
                subtitle: "取消",
                isActive: zone == .cancel,
                activeBg: theme.danger,
                activeFg: .white,
                activeSubtitleColor: theme.danger,
                angle: -10
            )
            Spacer()
            zoneBadge(
                title: "文",
                subtitle: "编辑",
                isActive: zone == .edit,
                activeBg: theme.textPrimary,
                activeFg: theme.background,
                activeSubtitleColor: theme.textPrimary,
                angle: 10
            )
        }
    }

    private func zoneBadge(
        title: String,
        subtitle: String,
        isActive: Bool,
        activeBg: Color,
        activeFg: Color,
        activeSubtitleColor: Color,
        angle: Double
    ) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isActive ? activeBg : theme.surface.opacity(0.92))
                    .frame(width: isActive ? 68 : 56, height: isActive ? 68 : 56)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                isActive ? Color.clear : theme.divider,
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: Color.black.opacity(theme.isDark ? 0.28 : 0.08),
                        radius: isActive ? 12 : 6,
                        y: 4
                    )

                Text(title)
                    .font(.system(size: isActive ? 22 : 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? activeFg : theme.textSecondary)
                    .rotationEffect(.degrees(angle))
            }

            Text(subtitle)
                .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? activeSubtitleColor : theme.textSecondary)
        }
    }

    private var bottomArcFill: Color {
        if zone == .send {
            switch theme.variant {
            case .light:
                return Color(red: 0.88, green: 0.92, blue: 0.99)
            case .dark:
                return Color(red: 0.13, green: 0.19, blue: 0.29)
            case .oled:
                return Color(red: 0.09, green: 0.14, blue: 0.22)
            }
        }
        return theme.surface.opacity(0.90)
    }

    private var bottomArcStroke: Color {
        zone == .send ? theme.accent.opacity(theme.isDark ? 0.38 : 0.28) : theme.divider
    }

    private var bottomArcPad: some View {
        ZStack {
            WeChatBottomArcShape()
                .fill(bottomArcFill)
                .overlay(
                    WeChatBottomArcTopCurve()
                        .stroke(bottomArcStroke, lineWidth: 1)
                )
                .frame(height: 112)
                .ignoresSafeArea(edges: .bottom)

            Image(systemName: "waveform")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(zone == .send ? theme.accent : theme.textHint)
                .offset(y: -6)
        }
        .frame(height: 112)
    }
}

private struct WeChatBottomArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 34))
        p.addQuadCurve(
            to: CGPoint(x: rect.width, y: 34),
            control: CGPoint(x: rect.width * 0.5, y: -18)
        )
        p.addLine(to: CGPoint(x: rect.width, y: rect.height + 50))
        p.addLine(to: CGPoint(x: 0, y: rect.height + 50))
        p.closeSubpath()
        return p
    }
}

private struct WeChatBottomArcTopCurve: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 34))
        p.addQuadCurve(
            to: CGPoint(x: rect.width, y: 34),
            control: CGPoint(x: rect.width * 0.5, y: -18)
        )
        return p
    }
}

// MARK: - Theme-Harmonious Voice Edit Overlay

private struct WeChatVoiceEditOverlay: View {
    let controllerText: String
    let isRefining: Bool
    let canSendAndSteer: Bool
    let onTextChanged: (String) -> Void
    let onCancel: () -> Void
    let onSend: (String, Bool) -> Void

    @State private var text: String
    @Environment(\.hapiTheme) private var theme

    init(
        controllerText: String,
        isRefining: Bool,
        canSendAndSteer: Bool,
        onTextChanged: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onSend: @escaping (String, Bool) -> Void
    ) {
        self.controllerText = controllerText
        self.isRefining = isRefining
        self.canSendAndSteer = canSendAndSteer
        self.onTextChanged = onTextChanged
        self.onCancel = onCancel
        self.onSend = onSend
        _text = State(initialValue: controllerText)
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()
                .onTapGesture {
                    // Keep focus in editor; only explicit ✕ cancels.
                }

            VStack(spacing: 0) {
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 42, height: 42)
                            .background(theme.surface, in: Circle())
                            .overlay(Circle().strokeBorder(theme.divider, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("取消语音编辑")

                    Spacer()

                    if isRefining {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(theme.accent)
                            Text("正在润色识别结果…")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }

                    Spacer()
                    Color.clear.frame(width: 42, height: 42)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                VoiceEditAutoFocusTextView(
                    text: Binding(
                        get: { text },
                        set: { next in
                            text = next
                            onTextChanged(next)
                        }
                    ),
                    isDark: theme.isDark,
                    textColor: UIColor(theme.textPrimary),
                    tintColor: UIColor(theme.accent),
                    onSendReturn: {
                        if canSubmit {
                            onSend(text, false)
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(theme.divider, lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.top, 14)

                HStack {
                    Spacer()
                    Button {
                        guard canSubmit else { return }
                        onSend(text, false)
                    } label: {
                        Text("发送")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 12)
                            .background(
                                Capsule()
                                    .fill(canSubmit ? theme.accent : theme.divider)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                    .accessibilityLabel("发送编辑后的文字")
                    .contextMenu {
                        if canSendAndSteer && canSubmit {
                            Button {
                                onSend(text, true)
                            } label: {
                                Label("发送并插入当前回合", systemImage: "arrow.turn.down.right")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
        .onChange(of: controllerText) { _, updated in
            if updated != text {
                text = updated
            }
        }
    }
}

private struct VoiceEditAutoFocusTextView: UIViewRepresentable {
    @Binding var text: String
    let isDark: Bool
    let textColor: UIColor
    let tintColor: UIColor
    let onSendReturn: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSendReturn: onSendReturn)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.font = .systemFont(ofSize: 19.5, weight: .medium)
        textView.returnKeyType = .send
        textView.keyboardAppearance = isDark ? .dark : .light
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.text = text
        let end = (text as NSString).length
        textView.selectedRange = NSRange(location: end, length: 0)
        DispatchQueue.main.async {
            textView.becomeFirstResponder()
        }
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onSendReturn = onSendReturn
        uiView.textColor = textColor
        uiView.tintColor = tintColor
        uiView.keyboardAppearance = isDark ? .dark : .light
        if uiView.markedTextRange == nil && uiView.text != text {
            uiView.text = text
            let end = (text as NSString).length
            uiView.selectedRange = NSRange(location: end, length: 0)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var onSendReturn: () -> Void

        init(text: Binding<String>, onSendReturn: @escaping () -> Void) {
            self.text = text
            self.onSendReturn = onSendReturn
        }

        func textViewDidChange(_ textView: UITextView) {
            if textView.markedTextRange == nil {
                text.wrappedValue = textView.text ?? ""
            }
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            if replacement == "\n" && textView.markedTextRange == nil {
                text.wrappedValue = textView.text ?? ""
                onSendReturn()
                return false
            }
            return true
        }
    }
}
#endif
