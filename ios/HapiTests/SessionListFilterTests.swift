import HapiClient
import Observation
import XCTest
@testable import Hapi
@testable import HapiProtocol

@MainActor
final class SessionListFilterTests: XCTestCase {
    func testSidebarAppearanceFetchesOnceButExplicitRetryStillRefreshes() async {
        let sessions = HomeFilterTestSessions()
        sessions.failRefresh = true
        let model = HomeFilterTestData.model(sessions: sessions)
        await model.refreshOnFirstAppearance()
        await model.refreshOnFirstAppearance()
        XCTAssertEqual(sessions.refreshCount, 1)
        XCTAssertTrue(model.isOffline)
        sessions.failRefresh = false
        await model.refresh()
        XCTAssertEqual(sessions.refreshCount, 2)
        XCTAssertFalse(model.isOffline)
        await model.refreshOnFirstAppearance()
        XCTAssertEqual(sessions.refreshCount, 2)
    }

    func testSidebarInitialRefreshOutlivesPresentationCancellation() async {
        let sessions = HomeFilterTestSessions()
        let model = HomeFilterTestData.model(sessions: sessions)
        let presentation = Task {
            await Task.yield()
            await model.refreshOnFirstAppearance()
        }
        presentation.cancel()
        await presentation.value
        XCTAssertEqual(sessions.refreshCount, 1)
        XCTAssertFalse(sessions.refreshWasCancelled)
        XCTAssertTrue(model.hasRefreshedOnce)
    }

    func testEmptyAndSingleMachineHaveNoMachineFilter() {
        let sessions = HomeFilterTestSessions()
        let model = HomeFilterTestData.model(sessions: sessions)
        XCTAssertFalse(model.showsFilterMenu)
        XCTAssertFalse(model.filters.isActive)
        sessions.sessions = [HomeFilterTestData.summary("a", machine: "mac")]
        model.selectMachine("mac")
        XCTAssertTrue(model.showsFilterMenu, "The unread lens applies to a single machine too")
        XCTAssertFalse(model.showsMachineFilter)
        XCTAssertNil(model.activeMachineFilter)
        XCTAssertNil(model.filterSummary)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.project, "hapi")
    }

    func testNamesCountsAndStableOrderIncludeHistoricalMachines() {
        let sessions = HomeFilterTestSessions([
            HomeFilterTestData.summary("1", machine: "mac-1111"),
            HomeFilterTestData.summary("2", machine: "mac-2222"),
            HomeFilterTestData.summary("3", machine: "debian"),
            HomeFilterTestData.summary("4", machine: "529e6566-history"),
            HomeFilterTestData.summary("5", machine: nil),
        ])
        let machines = HomeFilterTestMachines([
            HomeFilterTestData.machine("mac-1111", host: "old-host", name: " Mac "),
            HomeFilterTestData.machine("mac-2222", host: "Mac"),
            HomeFilterTestData.machine("debian", host: "debian", name: "  \n"),
            HomeFilterTestData.machine("unused", host: "No sessions"),
        ])
        let model = HomeFilterTestData.model(sessions: sessions, machines: machines)
        let options = model.machineFilters
        XCTAssertEqual(options.map(\.id), ["debian", "mac-1111", "mac-2222", "529e6566-history", unknownMachineFilterId])
        XCTAssertEqual(options.map(\.label), ["debian", "Mac · mac-1111", "Mac · mac-2222", "Machine · 529e6566", "Unknown machine"])
        sessions.sessions.reverse()
        sessions.sessions += (0..<1600).map { HomeFilterTestData.summary("extra-\($0)", machine: "mac-2222") }
        XCTAssertEqual(model.machineFilters.map(\.id), options.map(\.id))
        XCTAssertEqual(model.machineFilters.first { $0.id == "mac-2222" }?.sessionCount, 1601)
    }

    func testSingleSelectionIsIdempotentAndCountsStayUnfiltered() {
        let sessions = HomeFilterTestSessions([
            HomeFilterTestData.summary("a", machine: "mac"),
            HomeFilterTestData.summary("b", machine: "debian"),
            HomeFilterTestData.summary("c", machine: nil),
        ])
        let model = HomeFilterTestData.model(sessions: sessions)
        let options = model.machineFilters
        XCTAssertTrue(model.rows.allSatisfy { $0.project == "hapi" }, "Machines remain in filters, not every row")
        model.selectMachine("mac")
        XCTAssertTrue(model.filters.isActive)
        XCTAssertEqual(model.rows.map(\.id), ["a"])
        XCTAssertEqual(model.rows.first?.project, "hapi")
        XCTAssertEqual(model.filterSummary, "Machine: Machine · mac")
        model.selectMachine("mac")
        XCTAssertEqual(model.activeMachineFilter, "mac")
        XCTAssertEqual(model.machineFilters, options)
        model.selectMachine(unknownMachineFilterId)
        XCTAssertEqual(model.rows.map(\.id), ["c"])
        model.selectMachine(nil)
        XCTAssertNil(model.filterSummary)
        XCTAssertEqual(model.rows.count, 3)
        model.selectMachine("debian")
        model.clearFilters()
        XCTAssertEqual(model.filters, SessionListFilters())
    }

    func testMachineGoingOfflineDoesNotRemoveHistoricalFilter() {
        let sessions = HomeFilterTestSessions([
            HomeFilterTestData.summary("a", machine: "mac"),
            HomeFilterTestData.summary("b", machine: "debian"),
        ])
        let machines = HomeFilterTestMachines([HomeFilterTestData.machine("mac", host: "MacBook")])
        let model = HomeFilterTestData.model(sessions: sessions, machines: machines)
        model.selectMachine("mac")
        XCTAssertEqual(model.filterSummary, "Machine: MacBook")
        machines.machines = []
        model.reconcileFilters()
        XCTAssertEqual(model.activeMachineFilter, "mac")
        XCTAssertEqual(model.rows.map(\.id), ["a"])
        XCTAssertEqual(model.filterSummary, "Machine: Machine · mac")
    }

    func testVanishedSelectionDoesNotResurrectAndNewHomeStartsUnfiltered() {
        let a = HomeFilterTestData.summary("a", machine: "mac")
        let sessions = HomeFilterTestSessions([a, HomeFilterTestData.summary("b", machine: "debian")])
        let model = HomeFilterTestData.model(sessions: sessions)
        model.selectMachine("mac")
        XCTAssertFalse(HomeFilterTestData.model(sessions: sessions).filters.isActive)
        sessions.sessions.removeFirst()
        XCTAssertNil(model.activeMachineFilter)
        model.reconcileFilters()
        XCTAssertFalse(model.filters.isActive)
        sessions.sessions.append(a)
        XCTAssertNil(model.activeMachineFilter)
        model.selectMachine("not-a-session-group")
        XCTAssertFalse(model.filters.isActive)
        model.selectMachine("mac")
        sessions.sessions.removeAll { $0.id == "b" }
        model.reconcileFilters()
        XCTAssertFalse(model.filters.isActive, "One remaining group no longer needs a filter")
    }

    func testRefreshReadingAndExistingActionsStillUseTheSameStores() async throws {
        let sessions = HomeFilterTestSessions([
            HomeFilterTestData.summary("a", machine: "mac"),
            HomeFilterTestData.summary("b", machine: "debian"),
        ])
        let machines = HomeFilterTestMachines()
        let seen = LastSeenStore()
        let model = SessionListModel(sessionStore: sessions, machineStore: machines, lastSeenStore: seen, hubUrl: "test", preferences: UserDefaults(suiteName: UUID().uuidString)!)
        await model.refresh()
        XCTAssertEqual(sessions.refreshCount, 1)
        XCTAssertEqual(machines.refreshCount, 1)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertTrue(model.rows.allSatisfy { !$0.unread })
        sessions.sessions[0].updatedAt += 1
        model.selectedSessionId = "a"
        XCTAssertEqual(seen.lastSeenAt("a"), 0, "Navigation and metadata are not reading")
        model.setPinMode(sessionId: "b", mode: .global)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.rows.first?.id, "b")
        XCTAssertEqual(SessionListModel.pinnedCount(of: model.rows), 1)
        model.archiveSession(sessionId: "b")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.rows.map(\.id), ["a"])
        sessions.failRefresh = true
        await model.refresh()
        XCTAssertTrue(model.isOffline)
        XCTAssertEqual(model.rows.count, 1)
    }

    func testUnreadLensKeepsTheSelectedSessionAndMarkAllReadClearsIt() async throws {
        var stale = HomeFilterTestData.summary("seen", machine: "mac")
        stale.contentRevision = 10
        var fresh = HomeFilterTestData.summary("fresh", machine: "mac")
        fresh.contentRevision = 20
        let sessions = HomeFilterTestSessions([fresh, stale])
        let lastSeen = LastSeenStore()
        await lastSeen.markSeen(sessionId: "seen", revision: 10)
        let model = SessionListModel(sessionStore: sessions, machineStore: HomeFilterTestMachines(),
                                     lastSeenStore: lastSeen, hubUrl: "test", preferences: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertEqual(model.unreadCount, 1)

        model.setUnreadOnly(true)
        XCTAssertEqual(model.rows.map(\.id), ["fresh"])
        XCTAssertEqual(model.filterSummary, String(localized: "Unread only"))
        model.selectedSessionId = "seen"
        XCTAssertEqual(model.rows.map(\.id), ["fresh", "seen"])

        model.markAllRead()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.unreadCount, 0)
        XCTAssertEqual(model.rows.map(\.id), ["seen"])
        model.clearFilters()
        XCTAssertFalse(model.filters.unreadOnly)
    }

    func testSearchRanksTitlesWithinPinSections() {
        var pinned = HomeFilterTestData.summary("pinned", machine: "mac")
        pinned.pinned = true
        pinned.metadata?.name = "deploy notes"
        var exact = HomeFilterTestData.summary("exact", machine: "mac")
        exact.metadata?.name = "deploy"
        var other = HomeFilterTestData.summary("other", machine: "mac")
        other.metadata?.name = "refactor"
        let sessions = HomeFilterTestSessions(sortSessionSummaries([other, exact, pinned]))
        let model = HomeFilterTestData.model(sessions: sessions)

        model.searchQuery = "deploy"
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.rows.map(\.id), ["pinned", "exact"])
        XCTAssertEqual(SessionListModel.pinnedCount(of: model.rows), 1)
        model.searchQuery = "   "
        XCTAssertEqual(model.rows.count, 3)
    }

    func testArchivesAreHiddenButInactiveSessionsRemainAndSelectionIsKept() {
        var archived = HomeFilterTestData.summary("old", machine: "mac")
        archived.active = false
        archived.metadata?.lifecycleState = "archived"
        archived.globalPinned = true
        var offline = HomeFilterTestData.summary("offline", machine: "mac")
        offline.active = false
        let sessions = HomeFilterTestSessions([archived, offline])
        let model = HomeFilterTestData.model(sessions: sessions)
        XCTAssertEqual(model.rows.map(\.id), ["offline"])
        XCTAssertEqual(sessions.sessions.count, 2, "Filtering must not remove cached history")
        model.selectedSessionId = "old"
        XCTAssertEqual(model.rows.count, 2)
        model.selectedSessionId = nil
        model.searchQuery = "Review old"
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.hasArchivedSearchMatches)
        model.setShowArchivedSessions(true)
        XCTAssertEqual(model.rows.map(\.id), ["old"])
        XCTAssertFalse(model.hasArchivedSearchMatches)
        sessions.sessions[0].metadata?.lifecycleState = "running"
        model.setShowArchivedSessions(false)
        XCTAssertEqual(model.rows.map(\.id), ["old"], "Reopened session returns without clearing the filter")
    }

    func testArchivePreferencePersistsPerHubAndClearFiltersPreservesIt() {
        let suite = "hapi-archive-tests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        func model(_ hub: String) -> SessionListModel {
            SessionListModel(sessionStore: HomeFilterTestSessions(), machineStore: HomeFilterTestMachines(),
                lastSeenStore: LastSeenStore(), hubUrl: hub, preferences: preferences)
        }
        let first = model("first")
        XCTAssertFalse(first.showArchivedSessions)
        first.setShowArchivedSessions(true)
        first.setUnreadOnly(true)
        first.clearFilters()
        XCTAssertTrue(first.showArchivedSessions)
        XCTAssertTrue(model("first").showArchivedSessions)
        XCTAssertFalse(model("second").showArchivedSessions)
        first.setShowArchivedSessions(false)
        XCTAssertFalse(model("first").showArchivedSessions)
    }

    func testActiveOnlyPreservesSelectionAndPersistsPerHub() {
        var offline = HomeFilterTestData.summary("offline", machine: "mac")
        offline.active = false
        let sessions = HomeFilterTestSessions([HomeFilterTestData.summary("active", machine: "mac"), offline])
        let suite = "hapi-active-tests-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        func make(_ hub: String) -> SessionListModel {
            SessionListModel(sessionStore: sessions, machineStore: HomeFilterTestMachines(), lastSeenStore: LastSeenStore(), hubUrl: hub, preferences: prefs)
        }
        let model = make("first")
        model.setActiveOnly(true)
        XCTAssertEqual(model.rows.map(\.id), ["active"])
        model.selectedSessionId = "offline"
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertTrue(make("first").activeOnly)
        XCTAssertFalse(make("second").activeOnly)
        model.clearFilters()
        XCTAssertFalse(make("first").activeOnly)
        XCTAssertEqual(model.rows.count, 2)
    }

    func testDateRangeIncludesEndDayAcrossDaylightSaving() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let next = calendar.date(byAdding: .day, value: 1, to: start)!
        XCTAssertEqual(next.timeIntervalSince(start), 23 * 3600)
        let lower = Int(start.timeIntervalSince1970 * 1000)
        let upper = Int(next.timeIntervalSince1970 * 1000)
        XCTAssertFalse(SessionListModel.matchesDate(lower - 1, start: start, end: start, calendar: calendar))
        XCTAssertTrue(SessionListModel.matchesDate(lower, start: start, end: start, calendar: calendar))
        XCTAssertTrue(SessionListModel.matchesDate(upper - 1, start: start, end: start, calendar: calendar))
        XCTAssertFalse(SessionListModel.matchesDate(upper, start: start, end: start, calendar: calendar))
    }

    func testDateFilterUsesUpdatedAtAndComposesWithMachineAndSearch() {
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        var old = HomeFilterTestData.summary("old", machine: "mac")
        old.updatedAt = Int(today.timeIntervalSince1970 * 1000) - 1
        var current = HomeFilterTestData.summary("current", machine: "mac")
        current.updatedAt = Int(today.timeIntervalSince1970 * 1000)
        var other = HomeFilterTestData.summary("other", machine: "other")
        other.updatedAt = current.updatedAt
        let model = HomeFilterTestData.model(sessions: HomeFilterTestSessions([old, current, other]))
        model.setDateRange(start: tomorrow, end: today)
        XCTAssertEqual(model.filters.dateStart, today)
        XCTAssertEqual(model.rows.map(\.id), ["current", "other"])
        model.selectMachine("mac")
        model.searchQuery = "current"
        XCTAssertEqual(model.rows.map(\.id), ["current"])
        model.clearFilters()
        XCTAssertNil(model.filters.dateStart)
        XCTAssertNil(model.filters.dateEnd)
    }

    func testConnectionNoticeHasOneMessageAndHealthyStateIsEmpty() {
        XCTAssertNil(SessionConnectionNotice(state: .connected, showsCachedSessions: false).message)
        XCTAssertEqual(SessionConnectionNotice(state: .backoff(attempt: 2), showsCachedSessions: false).message, "Reconnecting…")
        XCTAssertEqual(SessionConnectionNotice(state: .backoff(attempt: 2), showsCachedSessions: true).message, "Offline — showing cached sessions")
        XCTAssertEqual(SessionConnectionNotice(state: .connected, showsCachedSessions: true).message, "Offline — showing cached sessions")
        let states: [SSEConnectionState] = [.idle, .connecting, .suspended]
        for state in states {
            XCTAssertNotNil(SessionConnectionNotice(state: state, showsCachedSessions: false).message)
        }
    }
}

/// In-memory observable stores: no networking, Keychain or disk snapshots.
@MainActor @Observable
final class HomeFilterTestSessions: SessionListStoring {
    var sessions: [SessionSummary]
    var refreshCount = 0
    var refreshWasCancelled = false
    var failRefresh = false
    init(_ sessions: [SessionSummary] = []) { self.sessions = sessions }
    func refresh() async throws {
        refreshCount += 1
        refreshWasCancelled = Task.isCancelled
        if failRefresh { throw URLError(.notConnectedToInternet) }
    }
    func scheduleRefresh() {}
    func fullResync() async throws { try await refresh() }
    func applySessionEvent(_ event: SyncEvent) {}
    func setPinMode(sessionId: String, mode: SessionPinMode) async throws {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].pinned = mode == .project
        sessions[index].globalPinned = mode == .global
        sessions = sortSessionSummaries(sessions)
    }
    func archiveSession(sessionId: String) async throws { sessions.removeAll { $0.id == sessionId } }
    func renameSession(sessionId: String, name: String) async throws {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].metadata?.name = name
    }
    /// Scripted lifecycle answers for `SessionLifecycleActionTests`.
    var deleteError: (any Error)?
    var reopenError: (any Error)?
    var reopenTarget: String?
    func deleteSession(sessionId: String) async throws {
        if let deleteError { throw deleteError }
        sessions.removeAll { $0.id == sessionId }
    }
    func reopenSession(sessionId: String) async throws -> ReopenSessionResponse {
        if let reopenError { throw reopenError }
        return ReopenSessionResponse(ok: true, sessionId: reopenTarget ?? sessionId, resumed: true)
    }
}

@MainActor @Observable
final class HomeFilterTestMachines: MachineListStoring {
    var machines: [Machine]
    var refreshCount = 0
    init(_ machines: [Machine] = []) { self.machines = machines }
    func refresh() async throws { refreshCount += 1 }
    func scheduleRefresh() {}
    func applyMachineEvent(machineId: String, data: MachineUpdatedData?) {}
}

@MainActor
enum HomeFilterTestData {
    static func model(sessions: HomeFilterTestSessions, machines: HomeFilterTestMachines = HomeFilterTestMachines()) -> SessionListModel {
        SessionListModel(sessionStore: sessions, machineStore: machines, lastSeenStore: LastSeenStore(), hubUrl: "test", preferences: UserDefaults(suiteName: UUID().uuidString)!)
    }

    static func summary(_ id: String, machine: String?) -> SessionSummary {
        SessionSummary(id: id, active: true, thinking: false, activeAt: 1000, updatedAt: 1000,
                       metadata: SessionSummaryMetadata(name: "Review \(id)", path: "/workspace/hapi", machineId: machine, flavor: "codex"),
                       metadataVersion: 1, agentStateVersion: 1, todosUpdatedAt: 0, pendingRequestsCount: 0)
    }

    static func machine(_ id: String, host: String, name: String? = nil) -> Machine {
        Machine(id: id, namespace: "test", seq: 1, createdAt: 0, updatedAt: 0, active: true, activeAt: 0,
                metadata: MachineMetadata(host: host, platform: "darwin", happyCliVersion: "test", displayName: name),
                metadataVersion: 1, runnerStateVersion: 0)
    }
}
