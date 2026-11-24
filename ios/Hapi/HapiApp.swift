import HapiProtocol
import OSLog
import SwiftUI

@main
struct HapiApp: App {
    /// APNs registration callbacks + notification-center delegate install
    /// (P3) — SwiftUI lifecycle apps get them only through the adaptor.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    private let log = Logger(subsystem: "run.hapi.companion", category: "app")

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    model.session?.releaseInactiveCaches()
                }
                .onChange(of: AssistantFileInbox.shared.revision, initial: true) { _, _ in importPendingFiles() }
                .onChange(of: model.session?.isAssistantMode) { _, _ in importPendingFiles() }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.handleScenePhase(phase)
        }
        .commands {
            HapiCommands()
        }
    }

    /// `hapicompanion://bind?hub=<url>&code=<accessToken>` — parse and route
    /// through `AppModel`: unpaired → pairing confirm; already paired to that
    /// hub → switch with a notice; a different hub → add-hub confirm.
    ///
    /// Never log the URL itself: the query carries the access token.
    private func importPendingFiles() {
        guard model.session?.isAssistantMode == true else { return }
        model.pendingIncomingFiles.append(contentsOf: AssistantFileInbox.shared.drain())
    }
    private func handleIncomingURL(_ url: URL) {
        if url.isFileURL, model.session?.isAssistantMode == true {
            Task { if case .ready(let file) = await AttachmentPreparer.prepare(fileURL: url) { AssistantFileInbox.shared.receive([file]) } }
            return
        }
        guard let link = BindLink.parse(url.absoluteString) else {
            log.warning("Ignoring malformed URL (scheme: \(url.scheme ?? "none", privacy: .public))")
            return
        }
        if !model.handleBindLink(link) {
            log.warning("Bind link carried an unusable hub URL")
        }
    }
}
