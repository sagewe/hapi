#if targetEnvironment(macCatalyst) && DEBUG
import HapiClient
import HapiProtocol
import HapiUI
import ObjectiveC.runtime
import SwiftUI
import UIKit
import XCTest
@testable import Hapi

@MainActor
private enum MenuAssignments {
    static var count = 0
    static var emptyAssignments = 0
}

extension UIBarButtonItem {
    @objc dynamic fileprivate func hapiPerformance_setMenu(_ menu: UIMenu?) {
        if menu != nil { MenuAssignments.count += 1 } else { MenuAssignments.emptyAssignments += 1 }
        hapiPerformance_setMenu(menu)
    }
}

/// Count the expensive public UIKit bridge at the real ChatView call site.
/// Changing a toast must not rebuild an unchanged native toolbar menu.
@MainActor
final class MacToolbarInvalidationTests: XCTestCase {
    func testTransientNoticesDoNotRebuildUnchangedToolbarMenus() async throws {
        let credentials = InMemoryCredentialStore()
        let hub = try XCTUnwrap(HubSession(
            hubUrl: "http://127.0.0.1:1/toolbar-\(UUID())", credentialStore: credentials,
            performer: OfflineHTTP()
        ))
        let model = ChatModel(session: hub, sessionId: "toolbar")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStack {
            ChatView(session: hub, model: model)
        }.hapiTypography().hapiTheme(.light))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; model.stop(); hub.shutdown() }
        try await Task.sleep(for: .milliseconds(500))
        // Catalyst's NSToolbar hosts this UIKit view outside host.view.
        let button = try XCTUnwrap(ChatActionsMenu.nativeMenuButton)
        let initialMenu = try XCTUnwrap(button.menu, "The real toolbar menu must be present")
        let original = try XCTUnwrap(class_getInstanceMethod(UIBarButtonItem.self, #selector(setter: UIBarButtonItem.menu)))
        let replacement = try XCTUnwrap(class_getInstanceMethod(UIBarButtonItem.self, #selector(UIBarButtonItem.hapiPerformance_setMenu(_:))))
        method_exchangeImplementations(original, replacement)
        defer { method_exchangeImplementations(original, replacement) }
        MenuAssignments.count = 0
        MenuAssignments.emptyAssignments = 0
        for index in 0..<12 {
            model.interactor.postNotice("Notice \(index)")
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(150))
        let count = MenuAssignments.count
        print("HAPI_TOOLBAR_PROFILE noticeUpdates=12 menuAssignments=\(count) emptyAssignments=\(MenuAssignments.emptyAssignments)")
        XCTAssertLessThanOrEqual(count, 1, "An unchanged menu must not be bridged again for every unrelated chat update")
        XCTAssertTrue(ChatActionsMenu.nativeMenuButton === button, "Keep the same toolbar button across chat updates")
        XCTAssertTrue(button.menu === initialMenu, "Transient notices must retain the existing native menu")
        XCTAssertEqual(model.notice, "Notice 11")

        let detail = Session(id: "toolbar", namespace: "test", seq: 1, createdAt: 1, updatedAt: 2,
            active: true, activeAt: 1,
            metadata: SessionMetadata(path: "/repo", host: "test", flavor: "codex"),
            metadataVersion: 1, agentStateVersion: 0, thinking: false, thinkingAt: 0)
        hub.sessionStore.applySessionEvent(.sessionUpdated(namespace: nil, sessionId: "toolbar", data: .session(detail)))
        try await configEventually { button.menu !== initialMenu }
        XCTAssertTrue(titles(in: try XCTUnwrap(button.menu)).contains(String(localized: "Archive")),
                      "Real session state changes must still refresh the menu's available actions")
    }

    private func titles(in menu: UIMenu) -> [String] {
        menu.children.flatMap { element in
            if let child = element as? UIMenu { return titles(in: child) }
            return [element.title]
        }
    }

    private struct OfflineHTTP: HTTPPerforming {
        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw URLError(.notConnectedToInternet)
        }
    }
}
#endif
