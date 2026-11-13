import HapiClient
import HapiUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import Hapi
@testable import HapiProtocol

@MainActor
final class VoiceParticlePresentationTests: XCTestCase {
    @Observable final class Driver {
        var text = "明天早上久点出发，帮我记一下，去会州。"
    }

    private struct Harness: View {
        let driver: Driver
        let interactor: ChatInteractor
        let theme: HapiTheme
        var body: some View {
            UserTextBlockView(block: UserTextBlock(id: "voice-message", localId: "voice-message",
                createdAt: 0, invokedAt: nil, text: driver.text, attachments: nil,
                status: nil, originalText: nil, meta: nil))
                .environment(\.chatInteractions, interactor)
                .hapiTypography()
                .hapiTheme(theme)
                .padding(24)
                .frame(width: 393, height: 240)
                .background(theme.background)
        }
    }

    private func interactor() -> ChatInteractor {
        let url = URL(string: "http://127.0.0.1:1")!
        let performer = VoicePresentationHTTP()
        let auth = AuthManager(baseURL: url, credentialStore: InMemoryCredentialStore(), performer: performer)
        let api = APIClient(baseURL: url, authManager: auth, performer: performer)
        return ChatInteractor(sessionId: "voice-specimen", api: api,
            sessionStore: SessionListStore(api: api), windows: MessageWindowControllers(provider: api),
            makeLocalId: { "voice-message" })
    }

    private func canvas(in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == "voice-particle-canvas" { return view }
        return view.subviews.lazy.compactMap { self.canvas(in: $0) }.first
    }

    func testMotionPolicySkipsUnchangedReducedAndLongText() {
        XCTAssertNil(VoiceParticleText.animationSource(from: "旧文本", to: "新文本", reduceMotion: true))
        XCTAssertNil(VoiceParticleText.animationSource(from: "不变", to: "不变", reduceMotion: false))
        XCTAssertNil(VoiceParticleText.animationSource(from: "", to: "初稿", reduceMotion: false))
        XCTAssertNil(VoiceParticleText.animationSource(from: "旧文本", to: String(repeating: "长", count: 4001), reduceMotion: false))
        XCTAssertEqual(VoiceParticleText.animationSource(from: "旧文本", to: "新文本", reduceMotion: false), "旧文本")
    }

    func testParticleTransitionFinishesInLightAndDark() async throws {
        for theme: HapiTheme in [.light, .dark] {
            let driver = Driver()
            let interactions = interactor()
            XCTAssertTrue(interactions.beginVoiceSend(id: "take", partialText: driver.text))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 240)
            let host = UIHostingController(rootView: Harness(driver: driver, interactor: interactions, theme: theme))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            defer { window.isHidden = true; interactions.cancelVoiceSend() }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertNil(canvas(in: host.view), "Initial text must not animate")
            func captureStill(_ name: String) throws {
                guard let path = ProcessInfo.processInfo.environment["HAPI_VOICE_PARTICLE_CAPTURE"] else { return }
                let directory = URL(fileURLWithPath: path).appendingPathComponent(theme.isDark ? "dark" : "light")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                let image = UIGraphicsImageRenderer(size: CGSize(width: 393, height: 240), format: format).image { _ in
                    host.view.drawHierarchy(in: CGRect(x: 0, y: 0, width: 393, height: 240), afterScreenUpdates: true)
                }
                try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
            }
            try captureStill("initial")
            driver.text = "明天早上九点出发，帮我记一下，去惠州。"
            interactions.finishVoiceSend(id: "take", finalText: driver.text)
            try await Task.sleep(for: .milliseconds(120))
            do {
                let active = try XCTUnwrap(canvas(in: host.view))
                XCTAssertFalse(active.isUserInteractionEnabled)
                XCTAssertGreaterThan(active.bounds.width, 0)
                if let path = ProcessInfo.processInfo.environment["HAPI_VOICE_PARTICLE_CAPTURE"] {
                    let directory = URL(fileURLWithPath: path).appendingPathComponent(theme.isDark ? "dark" : "light")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    // Synthetic fixture only; no microphone, credentials or live conversation.
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 2
                    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 393, height: 240), format: format)
                    for frame in 0..<20 {
                        let png = renderer.image { _ in
                            host.view.drawHierarchy(in: CGRect(x: 0, y: 0, width: 393, height: 240), afterScreenUpdates: true)
                        }.pngData()
                        try XCTUnwrap(png).write(to: directory.appendingPathComponent(String(format: "frame-%03d.png", frame)))
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(950))
            XCTAssertNil(canvas(in: host.view), "Transient canvas must clean itself up")
            try captureStill("final")
        }
    }
}

private actor VoicePresentationHTTP: HTTPPerforming {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
