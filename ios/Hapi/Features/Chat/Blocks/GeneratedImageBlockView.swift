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
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(content.block.fileName)
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
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .task(id: loadAttempt) {
            guard let loader, content.kind == .image || loadAttempt > 0 else { return }
            await content.load(using: loader)
            if content.kind == .file, let file = content.file, loadAttempt > 0 {
                if Self.canPreview(file.url) { previewOpen = true } else { shareOpen = true }
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
            if let file = content.file { GeneratedMediaShareSheet(file: file) }
        }
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
