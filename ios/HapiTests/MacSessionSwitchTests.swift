#if targetEnvironment(macCatalyst)
import HapiClient
import HapiProtocol
@testable import HapiUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import Hapi

@MainActor
final class MacSessionSwitchTests: XCTestCase {
    @Observable fileprivate final class Probe {
        var showFilesFor: String?
    }

    private struct Detail: View {
        let id: String
        let probe: Probe
        @State private var files = false
        var body: some View {
            Text(id).background(Presence(id: "switch-detail-\(id)").frame(width: 1, height: 1))
                .navigationDestination(isPresented: $files) {
                    Text("Files \(id)").background(Presence(id: "switch-files-\(id)").frame(width: 1, height: 1))
                }
                .navigationTitle(id)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Detail action") {} } }
                .onChange(of: probe.showFilesFor) { _, target in if target == id { files = true } }
        }
    }

    private struct Presence: UIViewRepresentable {
        let id: String
        func makeUIView(context: Context) -> UIView { let view = UIView(); view.accessibilityIdentifier = id; return view }
        func updateUIView(_ view: UIView, context: Context) { view.accessibilityIdentifier = id }
    }

    private struct Shell: View {
        let navigation: SessionNavigationState
        let probe: Probe
        var body: some View {
            SessionSplitView(navigation: navigation, onNewSession: {}) {
                List(selection: Binding(get: { navigation.selectedSessionId },
                    set: { if let id = $0 { navigation.open(id) } })) {
                    Text("A").tag("a")
                    Text("B").tag("b")
                }.listStyle(.sidebar)
            } detail: { id in Detail(id: id, probe: probe) }
        }
    }

    func testMacSwitchKeepsNavigationAndIsolatesDestinations() async throws {
        let navigation = SessionNavigationState()
        let probe = Probe()
        navigation.open("a")
        let (window, host) = try mount(Shell(navigation: navigation, probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await wait { self.find("switch-detail-a", in: window) != nil }
        try await Task.sleep(for: .milliseconds(350))
        weak var first: UINavigationController?
        first = try XCTUnwrap(navigations(in: host).last { self.find("switch-detail-a", in: $0.view) != nil })
        probe.showFilesFor = "a"
        try await wait { self.find("switch-files-a", in: window) != nil }
        try await Task.sleep(for: .milliseconds(350))
        navigation.open("b")
        try await wait { self.find("switch-detail-b", in: window) != nil }
        try await wait { self.find("switch-files-a", in: window) == nil }
        XCTAssertNil(find("switch-files-a", in: window), "A different session must never inherit the old file page")
        navigation.open("a")
        try await wait { self.find("switch-detail-a", in: window) != nil || self.find("switch-files-a", in: window) != nil }
        let returned = try XCTUnwrap(navigations(in: host).last {
            self.find("switch-detail-a", in: $0.view) != nil || self.find("switch-files-a", in: $0.view) != nil
        })
        XCTAssertTrue(first === returned, "Returning to a cached session must keep its native navigation controller")
    }

    private struct PlainDetail: UIViewRepresentable {
        let id: String
        func makeUIView(context: Context) -> UITextView { UITextView() }
        func updateUIView(_ view: UITextView, context: Context) { view.text = "switch:\(id):plain" }
    }

    private struct ChatShell: View {
        let navigation: SessionNavigationState
        let hub: HubSession
        let list: SessionListModel
        var body: some View {
            SessionSplitView(navigation: navigation, onNewSession: {}) {
                SessionListView(model: list, selection: Binding(
                    get: { navigation.selectedSessionId }, set: { if let id = $0 { navigation.open(id) } }
                ), onOpenSession: navigation.open)
                .toolbar { ToolbarItem(placement: .topBarLeading) { SessionFilterMenu(model: list) } }
            } detail: { id in
                if ProcessInfo.processInfo.environment["HAPI_SWITCH_SURFACE"] == "plain" {
                    PlainDetail(id: id)
                } else if ProcessInfo.processInfo.environment["HAPI_SWITCH_SURFACE"] == "transcript" {
                    let model = hub.chatModel(for: id)
                    ChatTranscriptView(model: model)
                        .onAppear { model.retainSurface("chat") }
                        .onDisappear { model.releaseSurface("chat") }
                } else {
                    ChatView(session: hub, model: hub.chatModel(for: id)).id(id)
                }
            }
            .hapiTypography().hapiTheme(.light)
        }
    }

    func testWarmDetailBudgetUsesRecencyAndRemovalPreservesOtherSelection() {
        let navigation = SessionNavigationState()
        ["a", "b", "c", "a", "d"].forEach(navigation.open)
        XCTAssertEqual(Set(navigation.recentSessionIds), ["a", "c", "d"])
        navigation.remove("c")
        XCTAssertEqual(navigation.selectedSessionId, "d")
        XCTAssertEqual(Set(navigation.recentSessionIds), ["a", "d"])
        navigation.releaseInactiveDetails()
        XCTAssertEqual(navigation.recentSessionIds, ["d"])
        navigation.remove("d")
        XCTAssertTrue(navigation.recentSessionIds.isEmpty)
        XCTAssertNil(navigation.selectedSessionId)
    }

    func testMemoryWarningDropsInactiveNativeDetail() async throws {
        let navigation = SessionNavigationState()
        let probe = Probe()
        navigation.open("a")
        let (window, _) = try mount(Shell(navigation: navigation, probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await wait { self.find("switch-detail-a", in: window) != nil }
        weak var first = find("switch-detail-a", in: window)
        navigation.open("b")
        try await wait { self.find("switch-detail-b", in: window) != nil }
        XCTAssertNotNil(first)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await wait { first == nil }
        XCTAssertEqual(navigation.recentSessionIds, ["b"])
        XCTAssertNotNil(find("switch-detail-b", in: window))
    }

    func testWarmSelectionRetainsNativeTranscriptAndReleasesHiddenChat() async throws {
        let credentials = InMemoryCredentialStore()
        let payload = Data(#"{"uid":1,"exp":4102444800,"ns":"test"}"#.utf8).base64EncodedString()
        try credentials.store(HubCredentials(hubUrl: "http://127.0.0.1:1", accessToken: "test", jwt: "e30.\(payload).test"))
        let hub = try XCTUnwrap(HubSession(hubUrl: "http://127.0.0.1:1/retained-\(UUID())", credentialStore: credentials,
                                         performer: SplitTestHTTP(sessionSwitchProfile: true)))
        let navigation = SessionNavigationState()
        let (window, _) = try mount(ChatShell(navigation: navigation, hub: hub, list: SessionListModel(session: hub)))
        defer { window.isHidden = true; window.rootViewController = nil; hub.shutdown() }
        navigation.open("a")
        try await wait { self.hasText("switch:a:", in: window) }
        weak var first = textView("switch:a:", in: window)
        let a = hub.chatModel(for: "a")
        let b = hub.chatModel(for: "b")
        XCTAssertTrue(b.visibleSurfaces.isEmpty)
        a.interactor.setComposerText("draft-a")
        b.interactor.setComposerText("draft-b")
        let selectedText = try XCTUnwrap(first)
        selectedText.selectedRange = NSRange(location: 0, length: 6)
        MacTextSelectionTracker.shared.updateSelection(from: selectedText)
        XCTAssertNotNil(MacTextSelectionTracker.shared.selectedText)
        navigation.open("b")
        try await wait { self.hasText("switch:b:", in: window) && a.visibleSurfaces.isEmpty }
        XCTAssertTrue(b.visibleSurfaces.contains("chat"))
        XCTAssertNil(MacTextSelectionTracker.shared.selectedText, "Copy in B must not copy A's hidden selection")
        XCTAssertEqual(selectedText.selectedRange.length, 0)
        XCTAssertEqual(hub.openChatSessionId, "b")
        weak var secondCollection = textView("switch:b:", in: window).flatMap { collection(containing: $0) }
        XCTAssertNotNil(secondCollection)
        XCTAssertNotNil(first, "A warm session must keep its actual native content, not just its reduced data")
        navigation.open("a")
        try await wait { self.hasText("switch:a:", in: window) && b.visibleSurfaces.isEmpty }
        XCTAssertTrue(first === textView("switch:a:", in: window))
        XCTAssertEqual(a.interactor.composerText, "draft-a")
        XCTAssertEqual(b.interactor.composerText, "draft-b")
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await wait { secondCollection == nil }
        XCTAssertEqual(navigation.recentSessionIds, ["a"])
    }

    private func collection(containing view: UIView) -> UICollectionView? {
        var parent: UIView? = view
        while let candidate = parent {
            if let result = candidate as? UICollectionView { return result }
            parent = candidate.superview
        }
        return nil
    }

    private func textView(_ marker: String, in view: UIView) -> UITextView? {
        if let text = view as? UITextView, text.text.contains(marker) { return text }
        return view.subviews.lazy.compactMap { self.textView(marker, in: $0) }.first
    }

    func testProfileColdAndWarmSelectionToReadableContent() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HAPI_SWITCH_PROFILE"] == "1")
        let credentials = InMemoryCredentialStore()
        let url = "http://127.0.0.1:1/switch-\(UUID())"
        let payload = Data(#"{"uid":1,"exp":4102444800,"ns":"test"}"#.utf8).base64EncodedString()
        try credentials.store(HubCredentials(hubUrl: "http://127.0.0.1:1", accessToken: "test", jwt: "e30.\(payload).test"))
        let hub = try XCTUnwrap(HubSession(hubUrl: url, credentialStore: credentials,
                                         performer: SplitTestHTTP(sessionSwitchProfile: true)))
        let navigation = SessionNavigationState()
        let (window, _) = try mount(ChatShell(navigation: navigation, hub: hub, list: SessionListModel(session: hub)))
        defer { window.isHidden = true; window.rootViewController = nil; hub.shutdown() }
        var samples: [[String: Any]] = []
        print("HAPI_SWITCH_READY pid=\(ProcessInfo.processInfo.processIdentifier)")
        let count = Int(ProcessInfo.processInfo.environment["HAPI_SWITCH_COUNT"] ?? "8") ?? 8
        for index in 0..<count {
            let id = index.isMultiple(of: 2) ? "a" : "b"
            let began = CACurrentMediaTime()
            navigation.open(id)
            try await wait(seconds: 8) { self.hasText("switch:\(id):", in: window, minimumAlpha: -1) }
            let mounted = (CACurrentMediaTime() - began) * 1_000
            try await wait(seconds: 8) { self.hasText("switch:\(id):", in: window) }
            let elapsed = (CACurrentMediaTime() - began) * 1_000
            samples.append(["session": id, "kind": index < 2 ? "cold" : "warm", "milliseconds": elapsed, "mountedMs": mounted])
            try await Task.sleep(for: .milliseconds(250))
        }
        print("HAPI_SWITCH_PROFILE \(String(decoding: try JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys]), as: UTF8.self))")
    }

    private func mount<V: View>(_ view: V) throws -> (UIWindow, UIHostingController<V>) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        host.traitOverrides.horizontalSizeClass = .regular
        window.frame = CGRect(x: 0, y: 0, width: 1200, height: 850)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        return (window, host)
    }

    private func wait(seconds: Double = 3, _ condition: () -> Bool) async throws {
        let until = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < until {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Session switch did not show the requested content")
        throw SwitchTimeout()
    }

    private struct SwitchTimeout: Error {}

    private func find(_ id: String, in view: UIView) -> UIView? {
        guard !view.isHidden, view.alpha > 0.98, !view.accessibilityElementsHidden else { return nil }
        if view.accessibilityIdentifier == id {
            guard let window = view.window, view.convert(view.bounds, to: window).intersects(window.bounds) else { return nil }
            return view
        }
        return view.subviews.lazy.compactMap { self.find(id, in: $0) }.first
    }

    private func navigations(in controller: UIViewController) -> [UINavigationController] {
        ((controller as? UINavigationController).map { [$0] } ?? []) + controller.children.flatMap { navigations(in: $0) }
    }

    private func hasText(_ marker: String, in view: UIView, minimumAlpha: CGFloat = 0.98) -> Bool {
        guard !view.isHidden, view.alpha > minimumAlpha else { return false }
        if let text = view as? UITextView, text.text.contains(marker),
           text.convert(text.bounds, to: view.window).intersects(view.window?.bounds ?? .zero) { return true }
        return view.subviews.contains { hasText(marker, in: $0, minimumAlpha: minimumAlpha) }
    }
}
#endif
