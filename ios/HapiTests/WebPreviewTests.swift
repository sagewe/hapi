import XCTest
import HapiClient
import WebKit
@testable import Hapi

@MainActor
final class WebPreviewTests: XCTestCase {
    func testOnlyLoopbackLinksAreIntercepted() {
        for url in ["http://localhost:5173/a?q=1#part", "http://127.0.0.1:3000", "http://[::1]:8000"] {
            XCTAssertTrue(WebPreviewTarget.isLocal(URL(string: url)!))
        }
        for url in ["https://example.com", "http://localhost.evil:5173", "file:///tmp/index.html", "http://user:pass@localhost:3000", "http://169.254.169.254"] {
            XCTAssertFalse(WebPreviewTarget.isLocal(URL(string: url)!))
        }
    }
    func testOptInAutomaticAuthenticationHMRAndClose() async throws {
        guard let path = ProcessInfo.processInfo.environment["HAPI_PREVIEW_NATIVE_CONFIG"] else { throw XCTSkip("Requires isolated preview integration server") }
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: String])
        let origin = try XCTUnwrap(config["origin"]), token = try XCTUnwrap(config["token"])
        let credentials = InMemoryCredentialStore()
        try credentials.store(HubCredentials(hubUrl: origin, accessToken: "unused", jwt: token, jwtObtainedAt: Int(Date().timeIntervalSince1970 * 1000)))
        let apiURL = try XCTUnwrap(URL(string: origin))
        let api = APIClient(baseURL: apiURL, authManager: AuthManager(baseURL: apiURL, credentialStore: credentials))
        let model = WebPreviewModel(api: api, sessionId: "test", target: URL(string: config["target"]!)!)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        let settings = WKWebViewConfiguration(); settings.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: settings)
        web.navigationDelegate = model; model.webView = web; window.rootViewController?.view.addSubview(web)
        defer { model.close(); window.isHidden = true }
        await model.start()
        XCTAssertNil(model.error)
        var ready = false
        for _ in 0..<120 {
            ready = (try? await web.callAsyncJavaScript("return document.querySelector('#api')?.textContent === 'API 正常'", arguments: [:], in: nil, contentWorld: .page)) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(ready, model.error ?? "Preview never loaded")
        guard ready else { return }
        _ = try await web.callAsyncJavaScript("document.querySelector('#note').value='native-kept'", arguments: [:], in: nil, contentWorld: .page)
        let revision = "native-" + UUID().uuidString
        let encoded = String(data: try JSONEncoder().encode(revision), encoding: .utf8)!
        try ("export const revision = " + encoded + "\n").write(toFile: "/Users/sage/myhome/.local/hapi-preview-poc/app/revision.js", atomically: true, encoding: .utf8)
        var updated = false
        for _ in 0..<80 {
            updated = (try? await web.callAsyncJavaScript("return document.querySelector('#revision')?.textContent === revision && document.querySelector('#note')?.value === 'native-kept'", arguments: ["revision": revision], in: nil, contentWorld: .page)) as? Bool == true
            if updated { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(updated, "HMR must preserve the input without a page reload")
        let cookie = try await web.callAsyncJavaScript("return document.querySelector('#cookie').textContent", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(cookie as? String, "Cookie 正常")
        var streaming = false
        for _ in 0..<20 {
            streaming = (try? await web.callAsyncJavaScript("return Number(document.querySelector('#sse').textContent.split('：')[1]) > 0", arguments: [:], in: nil, contentWorld: .page)) as? Bool == true
            if streaming { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(streaming, "SSE must work through automatic preview authorization")
        let picture = try await web.takeSnapshot(configuration: nil)
        try picture.pngData()?.write(to: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("native-integrated-proof.png"))
        model.close()
        try await Task.sleep(for: .milliseconds(800))
        var request = URLRequest(url: apiURL.appendingPathComponent("test/state")); request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertGreaterThan(state["closed"] ?? 0, 0)
    }

    func testUnsupportedPortFailsWithoutCreatingLease() async {
        let url = URL(string: "https://hub.example")!
        let api = APIClient(baseURL: url, authManager: AuthManager(baseURL: url, credentialStore: InMemoryCredentialStore()))
        let model = WebPreviewModel(api: api, sessionId: "s", target: URL(string: "http://localhost:22")!)
        await model.start()
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.loading)
        model.close()
    }
}
