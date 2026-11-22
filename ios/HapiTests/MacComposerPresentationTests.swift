#if targetEnvironment(macCatalyst)
import HapiClient
import HapiUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import Hapi

@MainActor
final class MacComposerPresentationTests: XCTestCase {
    func testProductionComposerFitsNarrowWindowsWithLongConfigurationAndScratchlist() async throws {
        let harness = try await SessionConfigTestHarness(model: "a-very-long-model-name-with-a-reasoning-effort-suffix")
        harness.interactor.scratchlist = ScratchlistTestStore(entries: [])
        harness.interactor.setComposerText("草稿仍应完整保留，⌘↩ 发送。\nSecond line of the draft.")
        for width in [CGFloat(320), 400, 720] {
            for locale in ["en", "zh-Hans"] {
                let view = ChatComposerView(interactor: harness.interactor)
                    .hapiTypography()
                    .environment(\.locale, Locale(identifier: locale))
                let size = UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 600))
                XCTAssertLessThanOrEqual(size.width, width + 1, "Toolbar must fit at \(width)pt (\(locale))")
                XCTAssertLessThan(size.height, 300)
                XCTAssertGreaterThan(size.height, 60)
            }
        }
        XCTAssertEqual(harness.interactor.composerDestination, .chat)
        XCTAssertEqual(harness.interactor.composerText, "草稿仍应完整保留，⌘↩ 发送。\nSecond line of the draft.")
        let posts = await harness.http.posts
        XCTAssertTrue(posts.isEmpty)
    }

    func testSessionControlsUseCompactSymbolWhenTheSummaryCannotFit() async throws {
        let harness = try await SessionConfigTestHarness(model: String(repeating: "Long model name ", count: 8))
        for width in [CGFloat(44), 100, 240, 500] {
            let controls = MacComposerSessionControls(model: harness.model, isPresented: .constant(false))
            let size = UIHostingController(rootView: controls).sizeThatFits(in: CGSize(width: width, height: 60))
            XCTAssertLessThanOrEqual(size.width, width + 1)
            XCTAssertEqual(size.height, 32, accuracy: 1)
        }
    }

    @Observable
    fileprivate final class Presentation {
        var open = false
    }

    private struct SettingsHarness: View {
        let model: SessionConfigModel
        let presentation: Presentation
        var body: some View {
            @Bindable var presentation = presentation
            VStack {
                Spacer()
                MacComposerSessionControls(model: model, isPresented: $presentation.open)
            }
            .padding(20)
        }
    }

    func testOpeningAndClosingTheNativeSettingsPopoverIsReadOnly() async throws {
        let harness = try await SessionConfigTestHarness(model: "sonnet")
        harness.interactor.setComposerText("Keep this unsent draft")
        let presentation = Presentation()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: SettingsHarness(model: harness.model, presentation: presentation))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(250))
        presentation.open = true
        try await configEventually { host.presentedViewController != nil }
        let panel = try XCTUnwrap(host.presentedViewController)
        XCTAssertNotNil(panel.popoverPresentationController)
        presentation.open = false
        try await configEventually { host.presentedViewController == nil }
        XCTAssertEqual(harness.interactor.composerText, "Keep this unsent draft")
        XCTAssertEqual(harness.interactor.composerDestination, .chat)
        let posts = await harness.http.posts
        XCTAssertTrue(posts.isEmpty)
    }
}
#endif
