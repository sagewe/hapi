import HapiClient
@testable import HapiProtocol
import HapiUI
import SwiftUI
import UIKit
import XCTest
@testable import Hapi

@MainActor
final class AssistantProfileTests: XCTestCase {
    private actor HTTP: HTTPPerforming {
        var profile = #"{"clientProfile":{"mode":"assistant","appTitle":"合规调查助手","defaultAgent":"agy","defaultPermissionMode":"auto","defaultDirectory":"/test","modelPresets":[{"id":"quick","label":"快速","model":"gemini-4-hydrogen-medium","effort":"medium"},{"id":"deep","label":"深度","model":"gemini-4-neon-high","effort":"high","isDefault":true}],"quickActions":[{"id":"company","title":"企业主体与股权穿透","prompt":"请核查："}]}}"#
        func set(_ value: String) { profile = value }
        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let body = request.url!.path.hasSuffix("/v1/settings") ? profile : #"{"machines":[]}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func hub(_ url: String, http: HTTP) throws -> HubSession {
        let store = InMemoryCredentialStore()
        let payload = Data(#"{"uid":1,"exp":4102444800,"ns":"test"}"#.utf8).base64EncodedString()
        try store.store(HubCredentials(hubUrl: HubURLNormalization.normalize(url) ?? url, accessToken: "test", jwt: "e30.\(payload).test"))
        return try XCTUnwrap(HubSession(hubUrl: url, credentialStore: store, performer: http))
    }
    func testProfileCacheIsPerHubAndRefreshCanRestoreDeveloper() async throws {
        let a = "http://127.0.0.1:1/profile-a-\(UUID())"
        let b = "http://127.0.0.1:1/profile-b-\(UUID())"
        defer {
            UserDefaults.standard.removeObject(forKey: "clientProfile:\(a)")
            UserDefaults.standard.removeObject(forKey: "clientProfile:\(b)")
        }
        let http = HTTP()
        let first = try hub(a, http: http)
        await first.refreshClientProfile()
        XCTAssertTrue(first.isAssistantMode)
        let cold = try hub(a, http: http)
        let developer = try hub(b, http: http)
        XCTAssertTrue(cold.isAssistantMode, "Cold launch restores this hub before network completes")
        XCTAssertFalse(developer.isAssistantMode, "Switching hubs must never inherit the previous mode")
        await http.set("{}")
        await first.refreshClientProfile()
        XCTAssertFalse(first.isAssistantMode)
        XCTAssertNil(UserDefaults.standard.data(forKey: "clientProfile:\(a)"))
        first.shutdown(); cold.shutdown(); developer.shutdown()
    }
    func testOfflineRunnerHasBusinessErrorAndNoSession() async throws {
        let url = "http://127.0.0.1:1/profile-offline-\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: "clientProfile:\(url)") }
        let session = try hub(url, http: HTTP())
        await session.refreshClientProfile()
        do {
            _ = try await session.spawnAssistantSession(prompt: "test")
            XCTFail("No runner must not create a session")
        } catch {
            XCTAssertEqual(error.localizedDescription, "后台调查服务暂时离线，请稍后重试")
        }
        session.shutdown()
    }
    func testAssistantReasoningNeverExpandsRawEnglish() async throws {
        let block = AgentReasoningBlock(id: "reasoning-fixture", localId: nil, createdAt: 1,
            invokedAt: nil, durationMs: nil, usage: nil, model: nil,
            text: String(repeating: "The request is to investigate this company. ", count: 80), meta: nil)
        let view = VStack {
            AgentReasoningBlockView(block: block, isStreaming: true)
            AgentReasoningBlockView(block: block, isStreaming: false)
        }.environment(\.executionDetailsHidden, true).hapiTypography().hapiTheme(.light).padding()
        let host = UIHostingController(rootView: view)
        let size = host.sizeThatFits(in: CGSize(width: 390, height: 2000))
        XCTAssertLessThan(size.height, 160, "Streaming reasoning must remain a short Chinese progress row")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        if let capture = ProcessInfo.processInfo.environment["HAPI_ASSISTANT_CAPTURE"] {
            let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
            let image = renderer.image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: URL(fileURLWithPath: capture))
        }
    }
    func testAssistantSheetFitsPhoneAndLargeText() async throws {
        let url = "http://127.0.0.1:1/profile-sheet-\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: "clientProfile:\(url)") }
        let session = try hub(url, http: HTTP())
        await session.refreshClientProfile()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: AssistantNewSessionSheet(session: session, onCreated: { _ in })
            .environment(\.dynamicTypeSize, .accessibility2).hapiTheme(.light).hapiTypography())
        window.rootViewController = host; window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        XCTAssertEqual(host.view.bounds.width, 390, accuracy: 1)
        XCTAssertTrue(host.view.intrinsicContentSize.height.isFinite)
        if let capture = ProcessInfo.processInfo.environment["HAPI_ASSISTANT_CAPTURE"] {
            let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
            let image = renderer.image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let url = URL(fileURLWithPath: capture).deletingLastPathComponent().appendingPathComponent("ios-new-presets.png")
            try image.pngData()?.write(to: url)
        }
        window.isHidden = true; session.shutdown()
    }
}
