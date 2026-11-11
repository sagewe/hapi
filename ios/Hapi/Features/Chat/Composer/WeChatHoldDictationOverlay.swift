#if !targetEnvironment(macCatalyst)
import HapiClient
import SwiftUI
import UIKit

/// Full-screen WeChat-style Hold-to-Dictate & Focused Voice Edit overlays (iOS only).
struct WeChatVoiceOverlayHost: View {
    let controller: HoldToDictateController
    var canSendAndSteer: Bool = false
    var onSteerSend: ((String) -> Void)?

    var body: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .holding(let zone, let partialText, let audioLevel):
            WeChatHoldDictationOverlay(
                zone: zone,
                partialText: partialText,
                audioLevel: audioLevel,
                isFinalizing: false
            )
            .allowsHitTesting(false)
            .transition(.opacity.animation(.easeOut(duration: 0.14)))
        case .finalizing(let zone, let partialText):
            WeChatHoldDictationOverlay(
                zone: zone,
                partialText: partialText,
                audioLevel: 0.2,
                isFinalizing: true
            )
            .allowsHitTesting(false)
            .transition(.opacity.animation(.easeOut(duration: 0.14)))
        case .editing(let initialText):
            WeChatVoiceEditOverlay(
                initialText: initialText,
                canSendAndSteer: canSendAndSteer,
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

// MARK: - Hold Overlay (Screenshots 2 & 3)

private struct WeChatHoldDictationOverlay: View {
    let zone: HoldActionZone
    let partialText: String
    let audioLevel: Float
    let isFinalizing: Bool

    private var bubbleBackground: Color {
        switch zone {
        case .send:
            return Color(red: 0.27, green: 0.76, blue: 0.43)
        case .edit:
            return Color(white: 0.22)
        case .cancel:
            return Color(red: 0.80, green: 0.27, blue: 0.27)
        }
    }

    private var bubbleForeground: Color {
        switch zone {
        case .send:
            return Color.black.opacity(0.88)
        case .edit, .cancel:
            return Color.white.opacity(0.94)
        }
    }

    private var hintTitle: String {
        if isFinalizing {
            return "正在转文字…"
        }
        switch zone {
        case .send:
            return "松手 发送"
        case .cancel:
            return "松手 取消"
        case .edit:
            return "松手 编辑"
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.76)
                    .ignoresSafeArea()

                // Center speech bubble + action hint
                VStack(spacing: 14) {
                    speechBubble(maxWidth: min(width - 56, 320))
                    Text(hintTitle)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.46))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .offset(y: -36)

                // Tilted Cancel & Edit pills + bottom convex send dome
                VStack(spacing: 22) {
                    HStack {
                        tiltedActionPill(
                            title: "取消",
                            angle: -10,
                            active: zone == .cancel
                        )
                        Spacer(minLength: 24)
                        tiltedActionPill(
                            title: "编辑",
                            angle: 10,
                            active: zone == .edit
                        )
                    }
                    .padding(.horizontal, 14)

                    bottomThumbDome(width: width)
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: zone) { _, _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    @ViewBuilder
    private func speechBubble(maxWidth: CGFloat) -> some View {
        ZStack {
            if partialText.isEmpty {
                HStack(spacing: 6) {
                    if isFinalizing {
                        ProgressView()
                            .tint(bubbleForeground)
                    } else {
                        VoiceWaveBarsView(level: audioLevel, foreground: bubbleForeground)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(partialText)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(bubbleForeground)
                        .multilineTextAlignment(.leading)
                        .lineLimit(6)
                        .truncationMode(.head)
                    if isFinalizing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(bubbleForeground)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 24)
            }
        }
        .frame(minWidth: 188, maxWidth: maxWidth, minHeight: 84)
        .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
        .animation(.easeOut(duration: 0.14), value: zone)
    }

    private func tiltedActionPill(title: String, angle: Double, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 17, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? Color.black.opacity(0.88) : Color.white.opacity(0.88))
            .frame(width: 152, height: 66)
            .background(
                active ? Color(white: 0.90) : Color(white: 0.19),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .scaleEffect(active ? 1.07 : 1.0)
            .rotationEffect(.degrees(angle))
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: active)
    }

    private func bottomThumbDome(width: CGFloat) -> some View {
        let isSendActive = zone == .send
        return Ellipse()
            .fill(isSendActive ? Color(white: 0.55) : Color(white: 0.17))
            .frame(width: width * 1.48, height: 240)
            .frame(width: width, height: 122, alignment: .top)
            .clipped()
            .animation(.easeOut(duration: 0.15), value: isSendActive)
    }
}

private struct VoiceWaveBarsView: View {
    let level: Float
    let foreground: Color

    private let weights: [CGFloat] = [0.42, 0.75, 1.0, 0.65, 0.88, 0.50]

    var body: some View {
        let clamped = CGFloat(min(1.0, max(0.08, level)))
        HStack(spacing: 5) {
            ForEach(Array(weights.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(foreground.opacity(0.85))
                    .frame(width: 4, height: 10 + 22 * clamped * weight)
            }
        }
        .frame(height: 34)
        .animation(.easeOut(duration: 0.09), value: level)
    }
}

// MARK: - Focused Voice Edit Overlay (Screenshot 1)

private struct WeChatVoiceEditOverlay: View {
    @State private var text: String
    let canSendAndSteer: Bool
    let onCancel: () -> Void
    let onSend: (String, Bool) -> Void

    init(
        initialText: String,
        canSendAndSteer: Bool,
        onCancel: @escaping () -> Void,
        onSend: @escaping (String, Bool) -> Void
    ) {
        _text = State(initialValue: initialText)
        self.canSendAndSteer = canSendAndSteer
        self.onCancel = onCancel
        self.onSend = onSend
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Color(white: 0.04)
                .ignoresSafeArea()
                .onTapGesture {
                    // Keep focus in editor; only explicit ✕ cancels.
                }

            VStack(spacing: 0) {
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("取消语音编辑")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)

                Spacer(minLength: 16)

                VoiceEditAutoFocusTextView(
                    text: $text,
                    onSendReturn: {
                        if canSubmit {
                            onSend(text, false)
                        }
                    }
                )
                .frame(minHeight: 88, maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 16)

                HStack {
                    Spacer()
                    Button {
                        guard canSubmit else { return }
                        onSend(text, false)
                    } label: {
                        Text("发送")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white.opacity(canSubmit ? 1.0 : 0.45))
                            .frame(width: 116, height: 44)
                            .background(
                                Color(red: 0.08, green: 0.75, blue: 0.38).opacity(canSubmit ? 1.0 : 0.35),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
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
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 14)
            }
        }
    }
}

private struct VoiceEditAutoFocusTextView: UIViewRepresentable {
    @Binding var text: String
    let onSendReturn: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSendReturn: onSendReturn)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.textColor = UIColor(white: 0.94, alpha: 1.0)
        textView.tintColor = UIColor(red: 0.16, green: 0.78, blue: 0.40, alpha: 1.0)
        textView.font = .systemFont(ofSize: 21, weight: .regular)
        textView.returnKeyType = .send
        textView.keyboardAppearance = .dark
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
