import HapiClient
import HapiProtocol
import HapiUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import Hapi

/// Real list/menu/summary components over observable, non-networked stores.
/// The test navigation shell has no pairing, push coordinator or live sessions.
@MainActor
final class HomeFilterPresentationTests: XCTestCase {
    @Observable
    fileprivate final class Navigation {
        var path: [String] = []
    }

    private struct Harness: View {
        let model: SessionListModel
        let navigation: Navigation
        var theme: HapiTheme = .light
        var size: DynamicTypeSize = .large
        var locale = Locale(identifier: "en")

        var body: some View {
            @Bindable var navigation = navigation
            NavigationStack(path: $navigation.path) {
                VStack(spacing: 0) {
                    SessionConnectionNotice(state: .connected, showsCachedSessions: false)
                    SessionListView(model: model) { navigation.path.append($0) }
                }
                .navigationTitle("Sessions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {} label: {
                            Label("Settings", systemImage: "gearshape").frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    // New Session sits beside the bottom search field, which
                    // this harness does not render.
                    if model.showsFilterMenu {
                        ToolbarItem(placement: .topBarTrailing) { SessionFilterMenu(model: model) }
                    }
                }
                .navigationDestination(for: String.self) { id in Text(verbatim: id) }
            }
            .hapiTypography()
            .hapiTheme(theme)
            .environment(\.dynamicTypeSize, size)
            .environment(\.locale, locale)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
            .preferredColorScheme(theme.isDark ? .dark : .light)
        }
    }

    func testFilteringResetsScrollButLiveUpdatesAndChatReturnPreserveIt() async throws {
        let sessions = HomeFilterTestSessions((0..<100).map {
            HomeFilterTestData.summary("session-\($0)", machine: $0.isMultiple(of: 2) ? "mac" : "debian")
        })
        let model = HomeFilterTestData.model(sessions: sessions)
        let navigation = Navigation()
        let window = try makeWindow(Harness(model: model, navigation: navigation), width: 402)
        defer { window.isHidden = true }
        try await settle()
        let list = try XCTUnwrap(findCollection(window))
        list.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
        try await settle()
        let offset = list.contentOffset.y
        sessions.sessions[99].updatedAt += 1
        try await settle()
        XCTAssertTrue(findCollection(window) === list)
        XCTAssertEqual(list.contentOffset.y, offset, accuracy: 1)
        XCTAssertEqual(sessions.refreshCount, 1)

        model.selectMachine("mac")
        try await settle()
        let filtered = try XCTUnwrap(findCollection(window))
        XCTAssertEqual(filtered.contentOffset.y, -filtered.adjustedContentInset.top, accuracy: 1)
        XCTAssertEqual(model.rows.count, 50)
        XCTAssertEqual(sessions.refreshCount, 1, "Filtering must not fetch or subscribe again")
        filtered.setContentOffset(CGPoint(x: 0, y: 450), animated: false)
        try await settle()
        let filteredOffset = filtered.contentOffset.y
        navigation.path.append("session-20")
        try await settle()
        navigation.path.removeAll()
        try await settle()
        XCTAssertEqual(model.activeMachineFilter, "mac")
        let returned = try XCTUnwrap(findCollection(window))
        XCTAssertEqual(returned.contentOffset.y, filteredOffset, accuracy: 1)

        model.clearFilters()
        try await settle()
        let all = try XCTUnwrap(findCollection(window))
        XCTAssertEqual(all.contentOffset.y, -all.adjustedContentInset.top, accuracy: 1)
        XCTAssertEqual(model.rows.count, 100)
    }

    func testSessionRemovalReconcilesSelectionWithoutResurrectingIt() async throws {
        let mac = HomeFilterTestData.summary("a", machine: "mac")
        let sessions = HomeFilterTestSessions([mac, HomeFilterTestData.summary("b", machine: "debian")])
        let model = HomeFilterTestData.model(sessions: sessions)
        let window = try makeWindow(Harness(model: model, navigation: Navigation()), width: 390)
        defer { window.isHidden = true }
        try await settle()
        model.selectMachine("mac")
        try await settle()
        sessions.sessions.removeAll { $0.id == "a" }
        try await settle()
        XCTAssertFalse(model.filters.isActive, "The view must reconcile session-store changes")
        XCTAssertFalse(model.showsMachineFilter)
        sessions.sessions.append(mac)
        try await settle()
        XCTAssertNil(model.activeMachineFilter)
        XCTAssertTrue(model.showsMachineFilter)
    }

    func testNativeListRowsKeepOnlyTitleAndProjectStatus() async throws {
        let sessions = HomeFilterTestSessions((0..<3).map { index in
            var summary = HomeFilterTestData.summary("row-\(index)", machine: nil)
            summary.metadata?.summary = .init(text: "A short preview")
            summary.pendingRequestsCount = index == 2 ? 0 : 1
            summary.pendingRequestKinds = [.input]
            summary.thinking = index == 2
            if index > 0 { summary.todoProgress = .init(completed: 3, total: 5) }
            return summary
        })
        let model = HomeFilterTestData.model(sessions: sessions)
        let window = try makeWindow(Harness(model: model, navigation: Navigation()), width: 390)
        defer { window.isHidden = true }
        try await settle()
        let list = try XCTUnwrap(findCollection(window))
        let heights = try (0..<3).map { index in
            try XCTUnwrap(list.layoutAttributesForItem(at: IndexPath(item: index, section: 0))).size.height
        }
        XCTAssertGreaterThanOrEqual(heights[0], 60)
        XCTAssertLessThanOrEqual(heights[0], 70, "Two readable lines, with breathing room")
        XCTAssertEqual(heights[0], heights[1], accuracy: 1, "Source progress must not add visible content")
        XCTAssertEqual(heights[0], heights[2], accuracy: 1, "Activity shares the same quiet secondary line")
    }

    func testNestedSubsessionRowsKeepCompactTwoLineHeight() async throws {
        var root = HomeFilterTestData.summary("h-0", machine: nil)
        root.thinking = true
        var child1 = HomeFilterTestData.summary("h-1", machine: nil)
        child1.metadata?.parentSessionId = "h-0"
        var child2 = HomeFilterTestData.summary("h-2", machine: nil)
        child2.metadata?.parentSessionId = "h-1"
        var child3 = HomeFilterTestData.summary("h-3", machine: nil)
        child3.metadata?.parentSessionId = "h-2"
        child3.pendingRequestsCount = 1
        child3.pendingRequestKinds = [.permission]

        let model = HomeFilterTestData.model(sessions: HomeFilterTestSessions([root, child1, child2, child3]))
        let window = try makeWindow(Harness(model: model, navigation: Navigation()), width: 390)
        defer { window.isHidden = true }
        try await settle()
        let list = try XCTUnwrap(findCollection(window))
        let heights = try (0..<4).map { index in
            try XCTUnwrap(list.layoutAttributesForItem(at: IndexPath(item: index, section: 0))).size.height
        }
        XCTAssertGreaterThanOrEqual(heights[0], 60)
        for height in heights.dropFirst() {
            XCTAssertGreaterThanOrEqual(height, 44, "Keep an accessible row hit target")
            XCTAssertLessThan(height, heights[0], "Children use less vertical space than the parent")
            XCTAssertEqual(height, heights[1], accuracy: 1)
        }
        try capture(window, name: "nested-sessions")
    }

    func testHomeLayoutSpecimens() async throws {
        let now = Int(Date.now.timeIntervalSince1970 * 1_000)
        let sessions = HomeFilterTestSessions((0..<6).map {
            var row = HomeFilterTestData.summary("session-\($0)", machine: $0.isMultiple(of: 2) ? "mac" : "debian")
            let sample = $0 % 6
            row.metadata?.name = ["优化 iOS 首页", "Review database migration", "确认发布方案与执行权限",
                                  "修复通知同步", "补齐离线恢复与回归测试",
                                  "排查后台任务重试问题"][sample]
            row.metadata?.flavor = sample.isMultiple(of: 2) ? "codex" : "claude"
            row.metadata?.summary = .init(text: "已补齐重连逻辑和测试 · Recovery checks are ready")
            row.updatedAt = now - [0, 59 * 60_000, 2 * 3_600_000, 4 * 3_600_000, 2 * 86_400_000, 330 * 86_400_000][sample]
            row.pendingRequestsCount = [1, 2, 7, 0, 0, 1][sample]
            row.pendingRequestKinds = sample == 1 ? [.permission] : (sample == 2 ? [.input, .permission] : [.input])
            row.backgroundTaskCount = sample == 4 ? 2 : 0
            row.thinking = sample == 0 || sample == 3
            row.active = sample != 5
            if sample == 0 || sample == 3 || sample == 4 {
                row.todoProgress = .init(completed: sample == 4 ? 5 : 3, total: 5)
            }
            return row
        })
        let machines = HomeFilterTestMachines([
            HomeFilterTestData.machine("mac", host: "MacBook Pro"),
            HomeFilterTestData.machine("debian", host: "debian"),
        ])
        let model = HomeFilterTestData.model(sessions: sessions, machines: machines)
        let cases: [(String, HapiTheme, DynamicTypeSize, CGFloat)] = [
            ("light", .light, .large, 402), ("dark", .dark, .large, 402),
            ("compact", .light, .large, 320), ("large-text", .light, .accessibility3, 390),
            ("wide", .light, .large, 768), ("oled", .oled, .large, 390),
            ("chinese", .light, .large, 390),
        ]
        for (name, theme, size, width) in cases {
            model.clearFilters()
            machines.machines[0].metadata?.displayName = name == "compact" || name == "large-text"
                ? "MacBook Pro · 上海开发环境 · very-long-machine-name.example.com" : nil
            let locale = Locale(identifier: name == "chinese" || name == "large-text" ? "zh-Hans" : "en")
            let window = try makeWindow(Harness(model: model, navigation: Navigation(), theme: theme, size: size, locale: locale), width: width)
            defer { window.isHidden = true }
            try await settle()
            // After the first-refresh baseline, mix read and unread rows.
            for index in [0, 2, 4] { sessions.sessions[index].updatedAt += 1 }
            try await settle()
            let all = try XCTUnwrap(findCollection(window))
            let allTop = try firstRowTop(all, in: window)
            try capture(window, name: "\(name)-all")
            model.selectMachine("mac")
            try await settle()
            let filtered = try XCTUnwrap(findCollection(window))
            let filteredTop = try firstRowTop(filtered, in: window)
            XCTAssertGreaterThanOrEqual(filteredTop - allTop, 43, "Applied summary has a 44pt clear target")
            XCTAssertLessThanOrEqual(filtered.frame.width, width + 1)
            XCTAssertEqual(model.rows.count, 3)
            try capture(window, name: "\(name)-filtered")
        }
    }

    func testQuietStatusComponentSpecimens() async throws {
        let sessions = HomeFilterTestSessions((0..<4).map { index in
            var row = HomeFilterTestData.summary("quiet-\(index)", machine: "mac")
            row.metadata?.name = ["对齐 HAPI Codex 与 Antigra 体验", "家庭模型网关配置", "整理家庭服务文档", "检查部署记录"][index]
            row.updatedAt = Int(Date.now.timeIntervalSince1970 * 1000) - index * 60_000
            row.pendingRequestsCount = index == 0 ? 1 : 0
            row.pendingRequestKinds = index == 0 ? [.input] : []
            row.thinking = index == 1
            row.backgroundTaskCount = index == 2 ? 2 : 0
            return row
        })
        let model = HomeFilterTestData.model(sessions: sessions)
        XCTAssertEqual(model.statusSummaryCounts, SessionStatusSummaryCounts(attention: 1, running: 1, background: 1))
        for (name, theme) in [("quiet-light", HapiTheme.light), ("quiet-dark", HapiTheme.dark)] {
            let specimen = VStack(alignment: .leading, spacing: 0) {
                SessionStatusSummaryBar(counts: model.statusSummaryCounts, activeLens: nil, onToggle: { _ in })
                ForEach(model.rows) { row in
                    SessionRowView(row: row)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    Divider().padding(.leading, 58)
                }
            }
            .frame(width: 390)
            .padding(.vertical, 8)
            .background(theme.background)
            .hapiTypography()
            .hapiTheme(theme)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
            let window = try makeWindow(
                specimen.frame(maxHeight: .infinity, alignment: .top).background(theme.background),
                width: 390, height: 420
            )
            defer { window.isHidden = true }
            try await settle()
            try capture(window, name: name)
        }
    }

    func testChatHeaderTitlesFillTheirAvailableWidth() async throws {
        XCTAssertFalse(ChatHeaderStatus.online.showsInHeader)
        XCTAssertFalse(ChatHeaderStatus.running.showsInHeader)
        XCTAssertFalse(ChatHeaderStatus.background(2).showsInHeader)
        XCTAssertFalse(ChatHeaderStatus.archived.showsInHeader)
        XCTAssertTrue(ChatHeaderStatus.offline.showsInHeader)
        XCTAssertTrue(ChatHeaderStatus.needsApproval(1).showsInHeader)
        XCTAssertTrue(ChatHeaderStatus.needsReply(1).showsInHeader)
        for (name, title, flavor, status) in [
            ("header-online", "接手胶囊 UI 改版", "codex", ChatHeaderStatus.online),
            ("header-long", "Session Hierarchical Display and Navigation", "agy", .online),
            ("header-offline", "接手胶囊 UI 改版", "codex", .offline),
            ("header-approval", "接手胶囊 UI 改版", "codex", .needsApproval(1)),
        ] {
            let header = ChatHeaderTitle(title: title, flavor: flavor, status: status, onTapAttention: {})
            let host = UIHostingController(rootView: header.hapiTheme(.light))
            let size = host.sizeThatFits(in: CGSize(width: 262, height: 100))
            XCTAssertEqual(size.width, 262, accuracy: 1, "Short titles must fill the same slot as long titles")
            XCTAssertLessThanOrEqual(size.height, 60)

            let specimen = HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                header
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 12)
            .frame(width: 390, height: 80)
            .background(.white)
            .hapiTheme(.light)
            .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: specimen)
            renderer.scale = 3
            if let directory = ProcessInfo.processInfo.environment["HAPI_HOME_CAPTURE"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(renderer.uiImage?.pngData()).write(to: url.appendingPathComponent("\(name).png"))
            }
        }
    }

    private func makeWindow<V: View>(_ view: V, width: CGFloat, height: CGFloat = 874) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func findCollection(_ view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        return view.subviews.lazy.compactMap(findCollection).first
    }

    private func firstRowTop(_ list: UICollectionView, in window: UIWindow) throws -> CGFloat {
        let row = try XCTUnwrap(list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        return list.convert(row.frame, to: window).minY
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(350))
    }

    private func capture(_ window: UIWindow, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["HAPI_HOME_CAPTURE"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
    }
}
