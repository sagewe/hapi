import HapiClient
import SwiftUI
import UIKit
import XCTest
@testable import Hapi

@MainActor
final class ConnectionDiagnosticsPresentationTests: XCTestCase {
    func testCapsuleUsesActualRouteAndRejectsStaleOrFailedLatency() throws {
        let now = Date()
        let direct = HubEndpointMeasurement(url: URL(string: "https://private.example.test")!, checkedAt: now, milliseconds: 28, outcome: .reachable)
        let relay = HubEndpointMeasurement(url: URL(string: "https://public.example.test")!, checkedAt: now, milliseconds: 96, outcome: .reachable)
        let switching = HubConnectionDiagnostics(mode: .automatic, isPrivate: true, reason: .privateVerified,
            privateMeasurement: direct, publicMeasurement: relay, activeEventIsPrivate: false)
        let label = ConnectionCapsuleLabel(snapshot: switching, referenceDate: now)
        XCTAssertEqual(label.latencyTitle, "96 ms")
        XCTAssertEqual(label.routeTitle, String(localized: "Public relay"))
        XCTAssertEqual(ConnectionCapsuleLabel(snapshot: switching, referenceDate: now.addingTimeInterval(61)).latencyTitle, "—")
        let timeout = HubEndpointMeasurement(url: direct.url, checkedAt: now, milliseconds: 3000, outcome: .timeout)
        let failed = HubConnectionDiagnostics(mode: .automatic, isPrivate: true, reason: .privateUnavailable,
            privateMeasurement: timeout, activeEventIsPrivate: true)
        XCTAssertEqual(ConnectionCapsuleLabel(snapshot: failed, referenceDate: now).latencyTitle, "—")
        let slower = HubConnectionDiagnostics(mode: .automatic, isPrivate: false, reason: .privateSlowerThanPublic,
            privateMeasurement: direct, publicMeasurement: relay, activeEventIsPrivate: false)
        XCTAssertEqual(ConnectionCapsuleLabel(snapshot: slower, referenceDate: now).latencyTitle, "96 ms")
        XCTAssertEqual(ConnectionCapsuleLabel(snapshot: nil, referenceDate: now).latencyTitle, "—")
    }

    func testConnectionPanelRendersHomePublicAndLargeText() async throws {
        let router = HubConnectionRouter(canonicalURL: URL(string: "https://public.example.test")!, persistent: false)
        let sample = HubConnectionDiagnostics(mode: .automatic, isPrivate: true, reason: .lanVerified,
            activeEventIsPrivate: true, selectedRoute: .lan, activeRoute: .lan, hasLAN: true, hasTailscale: true)
        for (name, size) in [("normal", DynamicTypeSize.large), ("large", DynamicTypeSize.accessibility2)] {
            let content = NavigationStack {
                ConnectionSelectionContent(router: router, snapshot: sample) { _ in }
            }
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .environment(\.dynamicTypeSize, size)
            .preferredColorScheme(.light)
            let host = UIHostingController(rootView: content)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 650)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let data = try XCTUnwrap(image.pngData()); XCTAssertGreaterThan(data.count, 1000)
            if let directory = ProcessInfo.processInfo.environment["HAPI_CONNECTION_CAPTURE"] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HAPI_CONNECTION_CAPTURE"] {
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try data.write(to: root.appendingPathComponent("connection-panel-\(name).png"))
            }
        }
    }

    func testCapsuleRenderingHasNoSeparatorAndSupportsLightAndDark() throws {
        let now = Date()
        let direct = HubEndpointMeasurement(url: URL(string: "https://private.example.test")!, checkedAt: now, milliseconds: 28, outcome: .reachable)
        let relay = HubEndpointMeasurement(url: URL(string: "https://public.example.test")!, checkedAt: now, milliseconds: 96, outcome: .reachable)
        let privateSnapshot = HubConnectionDiagnostics(mode: .automatic, isPrivate: true, reason: .privateVerified,
            privateMeasurement: direct, publicMeasurement: relay, activeEventIsPrivate: true)
        let publicSnapshot = HubConnectionDiagnostics(mode: .automatic, isPrivate: false, reason: .privateUnavailable,
            privateMeasurement: direct, publicMeasurement: relay, activeEventIsPrivate: false)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let root = VStack(alignment: .leading, spacing: 20) {
                ConnectionCapsuleLabel(snapshot: privateSnapshot, referenceDate: now)
                ConnectionCapsuleLabel(snapshot: publicSnapshot, referenceDate: now)
                ConnectionCapsuleLabel(snapshot: nil, referenceDate: now)
            }
            .padding(32).frame(width: 330, height: 220, alignment: .leading)
            .background(scheme == .light ? Color.white : Color.black)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: root); renderer.scale = 2
            let data = try XCTUnwrap(renderer.uiImage?.pngData())
            XCTAssertGreaterThan(data.count, 1000)
            if let directory = ProcessInfo.processInfo.environment["HAPI_CONNECTION_CAPTURE"] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HAPI_CONNECTION_CAPTURE"] {
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try data.write(to: root.appendingPathComponent("connection-\(name).png"))
            }
        }
        XCTAssertFalse(ConnectionCapsuleLabel(snapshot: privateSnapshot).latencyTitle.contains("·"))
    }
}
