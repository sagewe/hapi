import AVKit
import Combine
import HapiProtocol
import HapiUI
import QuickLook
import SwiftUI
import UIKit

/// The wire kind stays `generated-image` for all media. MIME, not the tool
/// name or filename, selects the renderer. Reset card state on row reuse.
struct GeneratedImageBlockView: View {
    let block: GeneratedImageBlock
    @Environment(\.chatMedia) private var media

    var body: some View {
        GeneratedMediaCard(block: block, loader: media)
            .id(block.imageId)
    }
}

private struct GeneratedMediaCard: View {
    let loader: GeneratedMediaLoader?
    @Environment(\.isAssistantMode) private var isAssistantMode
    @Environment(\.caseFileAccess) private var caseFileAccess
    @State private var wantsShare = false
    @State private var imageShareFile: GeneratedMediaFile?
    @State private var content: GeneratedMediaPresentation
    @State private var loadAttempt = 0
    @State private var imageOpen = false
    @State private var previewOpen = false
    @State private var shareOpen = false
    @Environment(\.openGeneratedMediaPlayback) private var openPlayback

    init(block: GeneratedImageBlock, loader: GeneratedMediaLoader?) {
        self.loader = loader
        _content = State(initialValue: GeneratedMediaPresentation(block: block))
    }

    var body: some View {
        Group {
            if isAssistantMode && content.kind == .file { assistantFileCard }
            else { regularCard }
        }
        .task(id: loadAttempt) {
            guard let loader, content.kind == .image || loadAttempt > 0 else { return }
            await content.load(using: loader)
            if content.kind == .file, let file = content.file, loadAttempt > 0 {
                if wantsShare || !Self.canPreview(file.url) { shareOpen = true } else { previewOpen = true }
            }
        }
        .fullScreenCover(isPresented: $imageOpen) {
            ImageViewer(image: content.image, title: content.block.fileName,
                        imageId: content.block.imageId, loader: loader)
        }
        .sheet(isPresented: $previewOpen) {
            if let file = content.file {
                NavigationStack {
                    GeneratedMediaPreview(file: file)
                        .navigationTitle(content.block.fileName)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Close") { previewOpen = false }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $shareOpen) {
            if let file = content.file ?? imageShareFile { GeneratedMediaShareSheet(file: file) }
        }
    }

    private var regularCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(verbatim: content.block.fileName)
                    .lineLimit(2)
            } icon: {
                Image(systemName: content.kind.icon)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let image = content.image {
                Button { imageOpen = true } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: isAssistantMode ? 16 : 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AssistantDesign.border, lineWidth: isAssistantMode ? 0.5 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(content.block.fileName)
                if isAssistantMode {
                    Button("转发或保存", systemImage: "square.and.arrow.up") {
                        guard let imageData = image.jpegData(compressionQuality: 0.95) else { return }
                        imageShareFile = try? GeneratedMediaFile(data: imageData, fileName: "证据截图.jpg", mimeType: "image/jpeg")
                        shareOpen = imageShareFile != nil
                    }.font(.caption).frame(minHeight: 36)
                }
            } else if let file = content.file {
                loadedFile(file)
            } else if content.loadFailed {
                Text("Couldn't load media.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry", systemImage: "arrow.clockwise") { loadAttempt += 1 }
            } else if loader != nil && (content.kind == .image || content.isLoading) {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if content.kind != .image {
                loadButton
                    .disabled(loader == nil)
            }
        }
        .padding(12)
        .background(isAssistantMode ? AssistantDesign.surface : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: isAssistantMode ? 16 : 12))
    }

    private var assistantFileCard: some View {
        let pdf = content.block.fileName.lowercased().hasSuffix(".pdf")
        let zip = content.block.fileName.lowercased().hasSuffix(".zip")
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: pdf ? "doc.richtext.fill" : zip ? "archivebox.fill" : "doc.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(pdf ? AssistantDesign.accent : AssistantDesign.inkSecondary)
                    .frame(width: 42, height: 42)
                    .background(
                        pdf ? AssistantDesign.accentSoft : AssistantDesign.surfaceMuted,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(content.block.fileName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(pdf ? "尽调 PDF 报告" : zip ? "证据资料包" : "交付文件")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AssistantDesign.inkMuted)
                        if content.isLoading {
                            ProgressView().controlSize(.mini).tint(AssistantDesign.accent)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button { openFile(share: false) } label: {
                    Label(pdf ? "预览报告" : "预览", systemImage: "doc.text.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(AssistantDesign.accentGradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .shadow(color: AssistantDesign.accent.opacity(0.22), radius: 6, y: 2)
                }
                .buttonStyle(AssistantPressStyle(scale: 0.97))

                Button { openFile(share: true) } label: {
                    Label("转发", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 42)
                        .background(AssistantDesign.subtleFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(AssistantDesign.border, lineWidth: 0.6))
                }
                .buttonStyle(AssistantPressStyle(scale: 0.96))
            }
            .disabled(loader == nil || content.isLoading)

            if pdf, let access = caseFileAccess, access.mainReportID == content.block.imageId, access.count > 1 {
                Divider().overlay(AssistantDesign.border)
                Button(action: access.open) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.caption)
                            .foregroundStyle(AssistantDesign.inkMuted)
                        Text("附 \(access.count - 1) 项核验图与资料")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AssistantDesign.inkSecondary)
                        Spacer()
                        Text("查看 ›")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AssistantDesign.inkSecondary)
                    }
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if content.loadFailed {
                Text("文件暂不可用，请重试")
                    .font(.caption)
                    .foregroundStyle(AssistantDesign.report)
            }
        }
        .padding(16)
        .assistantSurface(radius: 16)
        .accessibilityIdentifier("assistant.report-card")
    }
    private func openFile(share: Bool) {
        wantsShare = share
        if let file = content.file {
            if share || !Self.canPreview(file.url) { shareOpen = true } else { previewOpen = true }
        } else { loadAttempt += 1 }
    }

    @ViewBuilder
    private var loadButton: some View {
        switch content.kind {
        case .video:
            Button("Load video", systemImage: "play.circle") { loadAttempt += 1 }
        case .audio:
            Button("Load audio", systemImage: "play.circle") { loadAttempt += 1 }
        case .file:
            Button("预览", systemImage: "doc.text.magnifyingglass") { loadAttempt += 1 }
        case .image:
            EmptyView()
        }
    }

    @ViewBuilder
    private func loadedFile(_ file: GeneratedMediaFile) -> some View {
        if let player = content.player {
            GeneratedMediaPlaybackButton(poster: content.poster, isAudio: content.kind == .audio) {
                openPlayback?(GeneratedMediaPlayback(file: file, player: player, title: content.block.fileName,
                    onFailure: { content.playbackFailed() }))
            }
            .disabled(openPlayback == nil)
        }
        if content.playbackUnavailable {
            Text("This media cannot be played on this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { fileActions(file) }
            VStack(alignment: .leading, spacing: 12) { fileActions(file) }
        }
    }

    @ViewBuilder
    private func fileActions(_ file: GeneratedMediaFile) -> some View {
        if content.kind == .file, Self.canPreview(file.url) {
            Button("Preview", systemImage: "doc.text.magnifyingglass") { previewOpen = true }
        }
        Button("Save or share", systemImage: "square.and.arrow.up") { shareOpen = true }
    }

    private static func canPreview(_ url: URL) -> Bool {
        #if targetEnvironment(macCatalyst)
        // `canPreview` is unavailable in Mac Catalyst; Quick Look on macOS
        // shows a generic file preview for anything it cannot render.
        true
        #else
        QLPreviewController.canPreview(url as NSURL)
        #endif
    }
}

private struct GeneratedMediaShareSheet: UIViewControllerRepresentable {
    let file: GeneratedMediaFile

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        // Supply an anchor when UIKit presents the activity UI as an iPad popover.
        controller.popoverPresentationController?.sourceView = controller.view
        // The activity controller may outlive the transcript row/cache entry.
        controller.completionWithItemsHandler = { [file] _, _, _, _ in _ = file }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct GeneratedMediaPreview: UIViewControllerRepresentable {
    let file: GeneratedMediaFile

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let file: GeneratedMediaFile
        init(file: GeneratedMediaFile) { self.file = file }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            file.url as NSURL
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(file: file) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
}

/// Full-screen zoomable image viewer: pinch/double-tap to zoom and pan;
/// single tap at 1× or close button dismisses.
private struct ImageViewer: View {
    let image: UIImage?
    let title: String
    let imageId: String
    let loader: GeneratedMediaLoader?
    @State private var original: UIImage?
    @State private var failed = false
    @State private var attempt = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image = original ?? image {
                ZoomableImageView(image: image) {
                    dismiss()
                }
                .ignoresSafeArea()
            } else {
                Text(verbatim: title)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(16)
            }
            .accessibilityLabel("Close")
            if failed {
                Button("Retry loading original") { attempt += 1 }
                    .foregroundStyle(.white)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding()
            }
        }
        .task(id: attempt) {
            guard let loader else { return }
            failed = false
            do {
                let loaded = try await loader.originalImage(for: imageId)
                try Task.checkCancellation()
                original = loaded
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}
