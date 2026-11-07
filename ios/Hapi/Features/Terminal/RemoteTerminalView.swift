import Foundation
import HapiClient
import HapiUI
import SwiftUI
import WebKit

@MainActor @Observable
final class RemoteTerminalModel: NSObject, WKNavigationDelegate {
    var state = "connecting"
    var error: String?
    var direct = false
    var command = ""
    var commandSending = false
    private let api: APIClient
    private let sessionID: String
    private var terminalID = UUID().uuidString
    @ObservationIgnored private var web: WKWebView?
    @ObservationIgnored private var credentialsTask: Task<Void, Never>?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var active = true
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var authRetries = 0

    init(api: APIClient, sessionID: String) { self.api = api; self.sessionID = sessionID }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(TerminalMessages(self), name: "terminal")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.isOpaque = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        web = view
        do { view.loadHTMLString(try TerminalAssets.html(hub: api.baseURL), baseURL: api.baseURL) }
        catch { self.error = error.localizedDescription; state = "error" }
        return view
    }

    func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        if type == "loaded" { loaded = true; if active { connect() }; return }
        guard active else { return }
        switch type {
        case "credentials": connect(unauthorized: message["unauthorized"] as? Bool == true)
        case "status":
            state = message["state"] as? String ?? "error"
            error = state == "error" ? message["message"] as? String : nil
            if state == "connected" { authRetries = 0 }
        default: break
        }
    }

    func connect(unauthorized: Bool = false) {
        guard active, loaded else { return }
        credentialsTask?.cancel()
        state = "connecting"; error = nil
        credentialsTask = Task { [weak self] in
            guard let self else { return }
            do {
                if unauthorized {
                    guard authRetries == 0 else { throw URLError(.userAuthenticationRequired) }
                    authRetries += 1
                    token = try await api.authManager.refreshAfterUnauthorized(failedToken: token)
                } else { token = try await api.authManager.validToken() }
                try Task.checkCancellation()
                guard active, let token else { return }
                _ = try await web?.callAsyncJavaScript("window.HapiTerminal.start(options); window.HapiTerminal.mode(direct)", arguments: ["direct": direct, "options": ["baseURL": api.baseURL.absoluteString, "token": token, "sessionId": sessionID, "terminalId": terminalID]], in: nil, contentWorld: .page)
            } catch is CancellationError {} catch { self.error = error.localizedDescription; state = "error" }
        }
    }

    func retry() {
        if state == "exited" { terminalID = UUID().uuidString }
        authRetries = 0
        connect()
    }
    func setDirect(_ value: Bool) {
        direct = value
        Task { _ = try? await web?.callAsyncJavaScript("window.HapiTerminal.mode(value)", arguments: ["value": value], in: nil, contentWorld: .page) }
    }
    @discardableResult func send(_ value: String) async -> Bool {
        guard active, state == "connected" else { return false }
        return (try? await web?.callAsyncJavaScript("return window.HapiTerminal.send(value)", arguments: ["value": value], in: nil, contentWorld: .page)) as? Bool == true
    }
    static func commandSequence(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        return normalized.hasSuffix("\r") ? normalized : normalized + "\r"
    }
    func sendCommand() {
        let snapshot = command
        guard !snapshot.isEmpty, !commandSending, state == "connected" else { return }
        commandSending = true
        Task {
            defer { commandSending = false }
            if await send(Self.commandSequence(snapshot)), command == snapshot { command = "" }
        }
    }
    func copySelection() {
        Task {
            if let selected = try? await web?.callAsyncJavaScript("return window.HapiTerminal.selection()", arguments: [:], in: nil, contentWorld: .page) as? String, !selected.isEmpty {
                UIPasteboard.general.string = selected
            }
        }
    }
    func setActive(_ value: Bool) {
        active = value
        if value { if loaded { connect() } }
        else { credentialsTask?.cancel(); web?.evaluateJavaScript("window.HapiTerminal?.suspend()", completionHandler: nil); state = "idle" }
    }
    func tearDown() {
        setActive(false)
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
        web?.navigationDelegate = nil
        web = nil
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false; state = "error"; error = String(localized: "Terminal renderer stopped")
        do { webView.loadHTMLString(try TerminalAssets.html(hub: api.baseURL), baseURL: api.baseURL) } catch { self.error = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        let initialOrigin = url?.scheme == api.baseURL.scheme && url?.host == api.baseURL.host && url?.port == api.baseURL.port && ["", "/"].contains(url?.path ?? "")
        return !loaded && navigationAction.navigationType == .other && (url?.absoluteString == "about:blank" || initialOrigin) ? .allow : .cancel
    }
}

private final class TerminalMessages: NSObject, WKScriptMessageHandler {
    weak var model: RemoteTerminalModel?
    init(_ model: RemoteTerminalModel) { self.model = model }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        model?.receive(message.body)
    }
}

private struct TerminalSurface: UIViewRepresentable {
    let model: RemoteTerminalModel
    func makeUIView(context: Context) -> WKWebView { model.makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        uiView.evaluateJavaScript("window.HapiTerminal?.suspend()", completionHandler: nil)
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
    }
}

struct RemoteTerminalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: RemoteTerminalModel
    init(api: APIClient, sessionID: String) { _model = State(initialValue: RemoteTerminalModel(api: api, sessionID: sessionID)) }
    private let keys: [(String, String)] = [("Esc", "\u{1b}"), ("Tab", "\t"), ("Ctrl+C", "\u{03}"), ("Ctrl+D", "\u{04}"), ("Ctrl+Z", "\u{1a}"), ("Ctrl+L", "\u{0c}"), ("Ctrl+X", "\u{18}"), ("Ctrl+S", "\u{13}"), ("Home", "\u{1b}[H"), ("End", "\u{1b}[F"), ("↑", "\u{1b}[A"), ("↓", "\u{1b}[B"), ("←", "\u{1b}[D"), ("→", "\u{1b}[C"), ("Enter", "\r")]
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.state == "connecting" { ProgressView().padding(8) }
                if model.state == "error" || model.state == "exited" {
                    HStack {
                        Text(model.error ?? String(localized: "Terminal exited")).font(.footnote)
                        Spacer()
                        Button("Reconnect") { model.retry() }
                    }.padding(10)
                }
                TerminalSurface(model: model)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(keys, id: \.0) { key in Button(key.0) { Task { await model.send(key.1) } }.frame(minWidth: 44, minHeight: 44) } }
                }.disabled(model.state != "connected")
                Picker("Input Mode", selection: Binding(get: { model.direct }, set: { model.setDirect($0) })) {
                    Text("Command").tag(false)
                    Text("Direct Input").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal, 8)
                if !model.direct {
                    HStack {
                        TextField("Command", text: $model.command, axis: .vertical).lineLimit(1...4).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { model.sendCommand() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                            .accessibilityLabel("Send Command").disabled(model.state != "connected" || model.command.isEmpty || model.commandSending)
                    }.padding(12)
                }
            }
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { model.setActive(false); dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .help("Close (Esc)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.copySelection() } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("Copy Selection")
                        .help("Copy Selection")
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in model.setActive(phase == .active) }
        .onDisappear { model.tearDown() }
    }
}
