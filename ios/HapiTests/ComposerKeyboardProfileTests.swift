import HapiClient
import HapiUI
import SwiftUI
import UIKit
import XCTest
@testable import Hapi
@testable import HapiProtocol

#if !targetEnvironment(macCatalyst)
/// Opt-in diagnostic. Simulator callbacks are not compositor-presented FPS.
@MainActor
final class ComposerKeyboardProfileTests: XCTestCase {
    struct Row: Identifiable, Equatable {
        let id: String
        let block: VisibleChatBlock
    }
    private struct Harness: View {
        let rows: [Row]
        let cache: MarkdownRenderCache
        let interactor: ChatInteractor
        var body: some View {
            AnchoredTranscriptList(items: rows, historyVersion: 0, jumpToken: 0,
                historyControlID: "history", onViewport: { _ in }, onLayout: { _, _ in }) { row in
                AnyView(ChatBlockCard(block: row.block, basePath: "/workspace/hapi")
                    .environment(\.hapiMarkdownCache, cache))
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { ChatComposerView(interactor: interactor) }
            .hapiTheme(.light).hapiTypography()
        }
    }
    func testProfileKeyboardOpening() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HAPI_KEYBOARD_PROFILE"] == "1")
        let harness = try await SessionConfigTestHarness(flavor: "codex")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let count = Int(ProcessInfo.processInfo.environment["HAPI_KEYBOARD_ROWS"] ?? "80") ?? 80
        let sources = (0..<count).map { index in
            "## 回复 \(index)\n\n" + String(repeating: "聊天记录应在唤起键盘时保持连续移动，输入框保留草稿与底栏。", count: 5) + "\n\n- 检查布局\n- 保留 **阅读位置**"
        }
        let cache = MarkdownRenderCache()
        await cache.prepare(sources)
        let rows = sources.enumerated().map { index, text in
            let id = "keyboard-\(index)"
            return Row(id: id, block: .block(.agentText(AgentTextBlock(
                id: id, localId: nil, createdAt: index, invokedAt: nil, durationMs: nil,
                usage: nil, model: nil, text: text, meta: nil))))
        }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Harness(rows: rows, cache: cache, interactor: harness.interactor))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .seconds(1))
        func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
            if let match = view as? T { return match }
            return view.subviews.lazy.compactMap { find(type, in: $0) }.first
        }
        let input = try XCTUnwrap(find(UITextView.self, in: host.view))
        let collection = try XCTUnwrap(find(UICollectionView.self, in: host.view))
        let anchor = try XCTUnwrap(find(ComposerPopupHost.AnchorView.self, in: host.view))
        var keyboardStartHeights: [CGFloat] = []
        let observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { keyboardStartHeights.append(anchor.bounds.height) }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        let delay = Double(ProcessInfo.processInfo.environment["HAPI_KEYBOARD_PROFILE_DELAY"] ?? "0") ?? 0
        print("HAPI_KEYBOARD_READY pid=\(ProcessInfo.processInfo.processIdentifier)")
        try await Task.sleep(for: .seconds(delay))
        for repetition in 0..<4 {
            if repetition == 3 {
                harness.interactor.setComposerText("已展开的输入框")
                try await Task.sleep(for: .milliseconds(350))
            }
            let initialHeight = anchor.bounds.height
            let sampler = FrameSampler(collection: collection, anchor: anchor)
            sampler.start()
            let began = CACurrentMediaTime()
            if ProcessInfo.processInfo.environment["HAPI_KEYBOARD_TAP"] == "1" {
                let editorHost = try XCTUnwrap(input.superview as? ComposerTextView.ComposerHostView)
                editorHost.touchOverlay.beginTracking(windowPoint: input.convert(.zero, to: window))
                editorHost.touchOverlay.endTracking(tapPointInTextView: .zero)
            } else {
                XCTAssertTrue(input.becomeFirstResponder())
            }
            let focusMs = (CACurrentMediaTime() - began) * 1_000
            try await Task.sleep(for: .milliseconds(850))
            sampler.stop()
            XCTAssertTrue(input.isFirstResponder)
            let samples = sampler.samples
            let gaps = zip(samples.dropFirst(), samples).map { ($0[0] - $1[0]) * 1_000 }.sorted()
            let record: [String: Any] = ["repetition": repetition, "rows": count, "focusCallMs": focusMs,
                "maxCallbackGapMs": gaps.max() ?? 0, "firstCallbackMs": (samples.first?.first ?? 0) * 1_000,
                "callbacks": samples.count, "samples": samples, "keyboardStartHeights": keyboardStartHeights,
                "settledComposerHeight": anchor.bounds.height, "initialHeight": initialHeight]
            if repetition == 1 || repetition == 2,
               ProcessInfo.processInfo.environment["HAPI_KEYBOARD_ASSERT_MORPH"] == "1" {
                XCTAssertTrue(samples.contains { $0[4] > initialHeight + 1 && $0[4] < anchor.bounds.height - 1 },
                              "The compact composer must interpolate its height during keyboard opening")
            }
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print("HAPI_KEYBOARD_PROFILE \(String(decoding: data, as: UTF8.self))")
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "keyboard-\(count)-\(repetition)"
            attachment.lifetime = .keepAlways
            add(attachment)
            input.resignFirstResponder()
            try await Task.sleep(for: .milliseconds(650))
        }
    }
    private final class FrameSampler: NSObject {
        let collection: UICollectionView
        let anchor: UIView
        var link: CADisplayLink?
        var began = CACurrentMediaTime()
        var samples: [[Double]] = []
        init(collection: UICollectionView, anchor: UIView) { self.collection = collection; self.anchor = anchor }
        func start() {
            began = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        func stop() { link?.invalidate(); link = nil }
        @objc private func tick() {
            let layer = anchor.layer.presentation() ?? anchor.layer
            let rect = layer.convert(layer.bounds, to: anchor.window?.layer.presentation() ?? anchor.window?.layer)
            samples.append([CACurrentMediaTime() - began, collection.bounds.height, collection.contentOffset.y,
                            rect.minY, rect.height])
        }
    }
}

#endif
