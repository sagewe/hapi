import AVKit
import Combine
import SwiftUI
import UIKit

struct GeneratedMediaPlayback: Identifiable {
    let id = UUID()
    let file: GeneratedMediaFile
    let player: AVPlayer
    let title: String
    let onFailure: @MainActor () -> Void
}

private struct OpenGeneratedMediaPlaybackKey: EnvironmentKey {
    static let defaultValue: ((GeneratedMediaPlayback) -> Void)? = nil
}

extension EnvironmentValues {
    var openGeneratedMediaPlayback: ((GeneratedMediaPlayback) -> Void)? {
        get { self[OpenGeneratedMediaPlaybackKey.self] }
        set { self[OpenGeneratedMediaPlaybackKey.self] = newValue }
    }
}

/// UIHostingConfiguration has no child-controller containment. Keep AVKit out
/// of recycled cells and present it from the conversation's controller hierarchy.
struct GeneratedMediaPlaybackHost: ViewModifier {
    let model: ChatModel
    let owner: String
    @State private var playback: GeneratedMediaPlayback?

    func body(content: Content) -> some View {
        content
            .environment(\.openGeneratedMediaPlayback, { request in
                model.beginContentInspection()
                model.retainSurface("media:\(owner)")
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                playback = request
            })
            .sheet(item: $playback, onDismiss: {
                model.releaseSurface("media:\(owner)")
            }) { request in
                GeneratedMediaPlaybackView(request: request)
            }
            .onChange(of: model.toolInspection.invalidation) { playback = nil }
    }
}

/// A cell may host a poster and SwiftUI button, but never VideoPlayer (which
/// embeds AVPlayerViewController and renders an unsupported-view placeholder).
struct GeneratedMediaPlaybackButton: View {
    let poster: UIImage?
    let isAudio: Bool
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            ZStack {
                Color.black
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFit()
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .frame(height: isAudio ? 100 : 220)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isAudio ? Text("Play audio") : Text("Play video"))
        .accessibilityIdentifier("generated-media-play")
    }
}

struct GeneratedMediaPlaybackView: View {
    let request: GeneratedMediaPlayback
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private var playbackStatus: AnyPublisher<AVPlayerItem.Status, Never> {
        guard let item = request.player.currentItem else { return Empty().eraseToAnyPublisher() }
        return item.publisher(for: \.status).eraseToAnyPublisher()
    }

    var body: some View {
        NavigationStack {
            GeneratedMediaPlayerController(file: request.file, player: request.player)
                .navigationTitle(request.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        .onAppear { request.player.play() }
        .onDisappear { request.player.pause() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { request.player.pause() }
        }
        .onReceive(playbackStatus) { status in
            if status == .failed { request.onFailure(); dismiss() }
        }
    }
}

private struct GeneratedMediaPlayerController: UIViewControllerRepresentable {
    let file: GeneratedMediaFile
    let player: AVPlayer

    final class Coordinator {
        // Keep the staged file alive through controller dismissal and cache eviction.
        let file: GeneratedMediaFile
        init(file: GeneratedMediaFile) { self.file = file }
    }

    func makeCoordinator() -> Coordinator { Coordinator(file: file) }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.view.accessibilityIdentifier = "generated-media-player"
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player?.pause()
        controller.player = nil
    }
}
