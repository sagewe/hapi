import XCTest
import WebKit
import HapiUI
import HapiClient
@testable import Hapi

@MainActor
final class RemoteTerminalTests: XCTestCase {
    final class Messages: NSObject, WKScriptMessageHandler {
        let loaded: XCTestExpectation
        init(_ loaded: XCTestExpectation) { self.loaded = loaded }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if (message.body as? [String: Any])?["type"] as? String == "loaded" { loaded.fulfill() }
        }
    }
    func testOfflineTerminalLoadsAndDoesNotBufferDisconnectedInput() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let loaded = expectation(description: "xterm loaded")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(Messages(loaded), name: "terminal")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 500), configuration: configuration)
        window.rootViewController?.view.addSubview(web)
        let origin = URL(string: "https://example.invalid")!
        let html = try TerminalAssets.html(hub: origin)
        XCTAssertTrue(html.contains("connect-src https://example.invalid wss://example.invalid"))
        XCTAssertFalse(html.contains("<script src="))
        web.loadHTMLString(html, baseURL: origin)
        await fulfillment(of: [loaded], timeout: 15)
        let rows = try await web.callAsyncJavaScript("return document.querySelectorAll('.xterm-screen').length", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(rows as? Int, 1)
        let sent = try await web.callAsyncJavaScript("return window.HapiTerminal.send(value)", arguments: ["value": "echo '中文'\n"], in: nil, contentWorld: .page)
        XCTAssertEqual(sent as? Bool, false)
        _ = try await web.callAsyncJavaScript("window.HapiTerminal.mode(true); window.HapiTerminal.mode(false); window.HapiTerminal.suspend()", arguments: [:], in: nil, contentWorld: .page)
        configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
    }
    func testOptInLiveHubCommandAndReconnect() async throws {
        guard let path = ProcessInfo.processInfo.environment["HAPI_TERMINAL_SMOKE_CONFIG"] else { throw XCTSkip("Requires an explicitly provided local smoke configuration") }
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: String])
        let origin = try XCTUnwrap(config["origin"])
        let url = try XCTUnwrap(URL(string: origin))
        let credentials = InMemoryCredentialStore()
        try credentials.store(HubCredentials(hubUrl: origin, accessToken: "unused-in-smoke-test", jwt: try XCTUnwrap(config["token"]), jwtObtainedAt: Int(Date().timeIntervalSince1970 * 1000)))
        let api = APIClient(baseURL: url, authManager: AuthManager(baseURL: url, credentialStore: credentials))
        let model = RemoteTerminalModel(api: api, sessionID: try XCTUnwrap(config["sessionID"]))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        let web = model.makeWebView()
        web.frame = CGRect(x: 0, y: 0, width: 390, height: 450)
        window.rootViewController?.view.addSubview(web)
        defer { web.evaluateJavaScript("window.HapiTerminal?.close()", completionHandler: nil); model.tearDown(); window.isHidden = true }
        for _ in 0..<150 where model.state != "connected" { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(model.state, "connected", model.error ?? "")
        try await Task.sleep(for: .seconds(1))
        let accepted = await model.send("printf 'HAPI_%s_验证\\n' 'TERMINAL_OK'\r")
        XCTAssertTrue(accepted)
        var found = false
        for _ in 0..<50 {
            found = (try await web.callAsyncJavaScript("return window.HapiTerminal.snapshot().includes('HAPI_TERMINAL_OK_验证')", arguments: [:], in: nil, contentWorld: .page)) as? Bool == true
            if found { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(found, "Shell output including Chinese text must reach WebKit")
        model.setActive(false)
        let dropped = await model.send("must-not-run")
        XCTAssertFalse(dropped)
        try await Task.sleep(for: .milliseconds(250))
        model.setActive(true)
        for _ in 0..<150 where model.state != "connected" { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(model.state, "connected", model.error ?? "")
        try await Task.sleep(for: .milliseconds(250))
        let occurrences = try await web.callAsyncJavaScript("return window.HapiTerminal.snapshot().split('HAPI_TERMINAL_OK_验证').length - 1", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(occurrences as? Int, 1, "Reconnection must replay history without duplicating it")
        web.frame.size.width = 600
        try await Task.sleep(for: .milliseconds(250))
        let exited = await model.send("exit\r")
        XCTAssertTrue(exited)
        for _ in 0..<50 where model.state != "exited" { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(model.state, "exited")
    }

    func testCommandModeMatchesWebNewlineRules() {
        XCTAssertEqual(RemoteTerminalModel.commandSequence("printf '你好'\nls"), "printf '你好'\rls\r")
        XCTAssertEqual(RemoteTerminalModel.commandSequence("pwd\r\n"), "pwd\r")
    }
    func testAssetsRejectNonHTTPOrigin() {
        XCTAssertThrowsError(try TerminalAssets.html(hub: URL(string: "file:///tmp/a")!))
    }
}
