import HapiClient
import SwiftUI
import WebKit

struct WebPreviewTarget: Identifiable {
    let id = UUID()
    let url: URL
    static func isLocal(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }
}

@MainActor @Observable
final class WebPreviewModel: NSObject, WKNavigationDelegate {
    let target: URL
    private let api: APIClient
    private let sessionId: String
    private var lease: WebPreviewLease?
    private var generation = UUID()
    private var closed = false
    var loading = false
    var pageLoading = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    var error: String?
    var canGoBack = false
    var canGoForward = false
    @ObservationIgnored var webView: WKWebView? {
        didSet {
            observations.removeAll()
            guard let webView else { return }
            observations = [
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] web, _ in Task { @MainActor in self?.canGoBack = web.canGoBack } },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] web, _ in Task { @MainActor in self?.canGoForward = web.canGoForward } },
                webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] web, _ in Task { @MainActor in self?.pageLoading = web.isLoading } },
            ]
        }
    }
    init(api: APIClient, sessionId: String, target: URL) { self.api = api; self.sessionId = sessionId; self.target = target }
    func start() async {
        guard !loading, !closed else { return }
        loading = true; error = nil
        let identity = UUID(); generation = identity
        defer { if generation == identity { loading = false } }
        if let old = lease { lease = nil; try? await api.closeWebPreview(sessionId: sessionId, id: old.id) }
        do {
            guard WebPreviewTarget.isLocal(target), target.scheme?.lowercased() == "http", let port = target.port, (1024...65535).contains(port) else {
                throw NSError(domain: "Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Use an HTTP localhost URL with a port from 1024 to 65535")])
            }
            let host = target.host == "[::1]" ? "::1" : target.host!
            // Finish an in-flight lease request even if the sheet task is
            // canceled, so its resulting tunnel can be reclaimed below.
            let creation = Task { try await api.openWebPreview(sessionId: sessionId, host: host, port: port) }
            let result = try await creation.value
            guard !closed, generation == identity, !Task.isCancelled else { try? await api.closeWebPreview(sessionId: sessionId, id: result.id); return }
            guard var destination = URLComponents(string: result.origin), destination.scheme == "https", destination.user == nil, destination.password == nil,
                  let original = URLComponents(url: target, resolvingAgainstBaseURL: false) else {
                try? await api.closeWebPreview(sessionId: sessionId, id: result.id)
                throw URLError(.badServerResponse)
            }
            destination.percentEncodedPath = original.percentEncodedPath
            destination.percentEncodedQuery = original.percentEncodedQuery
            destination.percentEncodedFragment = original.percentEncodedFragment
            guard let url = destination.url else { throw URLError(.badURL) }
            lease = result
            webView?.load(URLRequest(url: url))
        } catch { if !closed && generation == identity { self.error = hubErrorMessage(error) ?? error.localizedDescription } }
    }
    func close() {
        closed = true; generation = UUID(); loading = false
        webView?.stopLoading(); webView?.loadHTMLString("", baseURL: nil)
        if let lease { self.lease = nil; Task { try? await api.closeWebPreview(sessionId: sessionId, id: lease.id) } }
    }
    func reload() {
        if error != nil { Task { await start() }; return }
        guard let lease, lease.expiresAt > Int(Date().timeIntervalSince1970 * 1000) else { Task { await start() }; return }
        error = nil; webView?.reload()
    }
    private func sameOrigin(_ url: URL) -> Bool {
        guard let origin = lease.flatMap({ URL(string: $0.origin) }) else { return false }
        return url.scheme == origin.scheme && url.host == origin.host && (url.port ?? 443) == (origin.port ?? 443)
    }
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic else { return (.performDefaultHandling, nil) }
        guard challenge.previousFailureCount == 0, let lease, let origin = URL(string: lease.origin),
              space.host == origin.host, space.protocol == "https", space.port == (origin.port ?? 443),
              lease.expiresAt > Int(Date().timeIntervalSince1970 * 1000) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(user: lease.username, password: lease.password, persistence: .forSession))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.absoluteString == "about:blank" { return .allow }
        // External navigations never inherit preview credentials.
        guard sameOrigin(url) else { error = String(localized: "This link leaves the preview"); return .cancel }
        return .allow
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
    }
}

private struct PreviewBrowser: UIViewRepresentable {
    let model: WebPreviewModel
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = model
        web.allowsBackForwardNavigationGestures = true
        model.webView = web
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) { uiView.stopLoading(); uiView.navigationDelegate = nil }
}

struct WebPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: WebPreviewModel
    init(api: APIClient, sessionId: String, target: URL) { _model = State(initialValue: WebPreviewModel(api: api, sessionId: sessionId, target: target)) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.loading || model.pageLoading { ProgressView("Opening preview…").padding() }
                if let error = model.error {
                    HStack { Text(error).font(.footnote); Spacer(); Button("Retry") { model.reload() } }.padding()
                }
                PreviewBrowser(model: model)
            }
            .navigationTitle("Web Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { model.close(); dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { model.webView?.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!model.canGoBack).accessibilityLabel("Back")
                    Button { model.webView?.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!model.canGoForward).accessibilityLabel("Forward")
                    Spacer()
                    Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload")
                }
            }
        }.task { await model.start() }.onDisappear { model.close() }
    }
}
