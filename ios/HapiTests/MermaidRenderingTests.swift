import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import HapiUI

@MainActor
final class MermaidRenderingTests: XCTestCase {
    private func testWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        return window
    }

    func testOfflineFlowchartSequenceAndCache() async throws {
        let window = try testWindow()
        defer { window.isHidden = true }
        let renderer = MermaidRenderer()
        let code = "flowchart TD\n A[手机] --> B[家庭 Gateway]\n B --> C[设备]"
        let first = try await renderer.render(code: code, dark: false)
        XCTAssertTrue(first.svg.contains("<svg"))
        XCTAssertTrue(first.svg.contains("家庭 Gateway"))
        let cg = try XCTUnwrap(first.image.cgImage)
        XCTAssertGreaterThan(cg.width, 100)
        let bytes = try XCTUnwrap(cg.dataProvider?.data)
        let pixels = CFDataGetBytePtr(bytes)!
        XCTAssertGreaterThan(pixels[0], 200, "Preview must not include a black safe-area strip")
        let unique = Set(stride(from: 0, to: CFDataGetLength(bytes), by: 19).map { pixels[$0] })
        XCTAssertGreaterThan(unique.count, 8, "Preview must contain the actual diagram, not a blank WebView")
        let cached = try await renderer.render(code: code, dark: false)
        XCTAssertTrue(first === cached)
        let dark = try await renderer.render(code: code, dark: true)
        XCTAssertFalse(first === dark)
        let sequence = try await renderer.render(code: "sequenceDiagram\n Alice->>Bob: 你好\n Bob-->>Alice: OK", dark: true)
        XCTAssertTrue(sequence.svg.contains("Alice"))
        if let directory = ProcessInfo.processInfo.environment["HAPI_MERMAID_CAPTURE"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try first.image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("flowchart.png"))
            try sequence.image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("sequence-dark.png"))
        }
    }

    func testParseFailureLimitsAndCancellationRecover() async throws {
        let window = try testWindow()
        defer { window.isHidden = true }
        let renderer = MermaidRenderer()
        do {
            _ = try await renderer.render(code: "flowchart TD\n A[unclosed", dark: false)
            XCTFail("Invalid source must fall back")
        } catch { XCTAssertFalse(error.localizedDescription.contains("timed out")) }
        do {
            _ = try await renderer.render(code: String(repeating: "x", count: 20001), dark: false)
            XCTFail("Oversized diagrams must be bounded")
        } catch { XCTAssertEqual(error.localizedDescription, String(localized: "Diagram is too large. View the source instead.")) }
        let cancelled = Task { try await renderer.render(code: "flowchart TD\n A-->Cancelled", dark: false) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled cells must not receive stale previews") }
        catch { XCTAssertTrue(error is CancellationError) }
        let recovered = try await renderer.render(code: "flowchart TD\n A-->Recovered", dark: false)
        XCTAssertTrue(recovered.svg.contains("Recovered"))
    }

    func testConcurrentReadersSurviveOneCellCancelling() async throws {
        let window = try testWindow()
        defer { window.isHidden = true }
        let renderer = MermaidRenderer()
        let code = "flowchart LR\n A-->Shared"
        let first = Task { try await renderer.render(code: code, dark: false) }
        let second = Task { try await renderer.render(code: code, dark: false) }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        let result = try await second.value
        XCTAssertTrue(result.svg.contains("Shared"))
        do { _ = try await first.value; XCTFail("Cancelled reader must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cached = try await renderer.render(code: code, dark: false)
        XCTAssertTrue(cached === result)
        XCTAssertFalse(window.subviews.contains { $0 is WKWebView }, "Completed previews must release WebKit views")
    }

    func testMarkdownPreviewKeepsItsHeightAndFullscreenSupportsZoom() async throws {
        let window = try testWindow()
        defer { window.isHidden = true }
        let code = "flowchart TD\n Phone-->Gateway\n Gateway-->Device"
        let host = UIHostingController(rootView: MarkdownView(markdown: "```mermaid\n" + code + "\n```")
            .hapiTheme(.light).hapiTypography())
        window.rootViewController = host
        window.makeKeyAndVisible()
        // Let the test window's root appearance transition finish before an
        // offscreen WebKit view joins it (production keeps the root stable).
        try await Task.sleep(for: .milliseconds(300))
        let before = host.sizeThatFits(in: CGSize(width: 350, height: 1000)).height
        let preview: MermaidPreview
        do { preview = try await MermaidRenderer.shared.render(code: code, dark: false) }
        catch {
            let error = error as NSError
            XCTFail("Preview integration: \(error.domain) / \(error.code) / \(error.userInfo)")
            throw error
        }
        try await Task.sleep(for: .milliseconds(600))
        host.view.layoutIfNeeded()
        let after = host.sizeThatFits(in: CGSize(width: 350, height: 1000)).height
        XCTAssertEqual(before, after, accuracy: 1, "Async preview must not move neighboring transcript rows")
        XCTAssertGreaterThanOrEqual(after, 284)
        if let path = ProcessInfo.processInfo.environment["HAPI_MERMAID_CAPTURE"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: URL(fileURLWithPath: path).appendingPathComponent("inline-preview.png"))
        }
        let viewer = UIHostingController(rootView: MermaidVectorView(svg: preview.svg, dark: false))
        window.rootViewController = viewer
        viewer.view.layoutIfNeeded()
        func webView(in view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { webView(in: $0) }.first
        }
        var found: WKWebView?
        for _ in 0..<100 {
            found = webView(in: viewer.view)
            if let found, !found.isLoading, found.scrollView.maximumZoomScale > 1 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let web = try XCTUnwrap(found)
        XCTAssertGreaterThan(web.scrollView.maximumZoomScale, 1)
        XCTAssertFalse(web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        web.load(URLRequest(url: URL(string: "https://example.invalid/blocked")!))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotEqual(web.url?.host, "example.invalid")
    }

    func testNavigationAndHostileLabelsStayOffline() async throws {
        XCTAssertTrue(MermaidNavigationPolicy.allows(URL(string: "about:blank"), link: false))
        for url in ["https://example.com", "file:///etc/passwd", "data:text/html,test", "javascript:alert(1)"] {
            XCTAssertFalse(MermaidNavigationPolicy.allows(URL(string: url), link: false))
        }
        XCTAssertFalse(MermaidNavigationPolicy.allows(URL(string: "about:blank"), link: true))
        let window = try testWindow()
        defer { window.isHidden = true }
        let renderer = MermaidRenderer()
        let result = try await renderer.render(code: "flowchart TD\n A[\"<img src='https://example.invalid/pixel' onerror='alert(1)'>\"]", dark: false)
        XCTAssertFalse(result.svg.contains("onerror="))
        XCTAssertFalse(result.svg.contains("<script"))
        let document = MermaidDocument.html(body: "<main></main>", dark: true)
        XCTAssertTrue(document.contains("connect-src 'none'"))
        XCTAssertTrue(document.contains("default-src 'none'"))
    }
}

