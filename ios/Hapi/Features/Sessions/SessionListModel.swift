import Foundation
import HapiClient
import HapiProtocol
import Observation

/// Sessions whose metadata carries no machine id group under this filter id.
let unknownMachineFilterId = "__unknown__"

/// Tree connector geometry for a single child row in default relationship browse mode.
struct SessionTreeConnector: Equatable, Hashable {
    let visualDepth: Int
    let continuesAtLevel1: Bool
    let isLastChild: Bool
    let isDepthCapped: Bool
}

/// One rendered list row: the summary plus everything derived for display.
struct SessionRowUI: Identifiable, Equatable {
    let summary: SessionSummary
    /// `getSessionTitle` port: name → summary text → path tail → id prefix.
    let title: String
    /// Short project name only. Paths, machine/worktree details and the
    /// conversation summary stay out of the compact home row.
    let project: String?
    /// Raw flavor id (`claude`, `codex`, …); labels resolve via the catalog.
    let flavor: String?
    let unread: Bool
    var hierarchy: SessionTreeConnector? = nil
    var parentHint: String? = nil
    var inPinnedSection: Bool? = nil

    var id: String { summary.id }
    var status: SessionRowStatus? { SessionRowStatus(summary: summary) }
    var tags: [String] { summary.metadata?.tags ?? [] }
    var isArchived: Bool { summary.metadata?.lifecycleState == "archived" }
    var belongsToPinnedSection: Bool {
        inPinnedSection ?? (summary.globalPinned == true || summary.pinned == true)
    }
}

/// Quick status lens for the Option-B top summary bar (non-reordering).
enum SessionQuickStatusLens: String, Equatable, Hashable, CaseIterable {
    case attention
    case running
    case background

    var filterLabel: String {
        switch self {
        case .attention: return String(localized: "Status: Needs action")
        case .running: return String(localized: "Status: Running")
        case .background: return String(localized: "Status: Background")
        }
    }
}

struct SessionStatusSummaryCounts: Equatable {
    var attention: Int = 0
    var running: Int = 0
    var background: Int = 0

    var hasAny: Bool {
        attention > 0 || running > 0 || background > 0
    }

    func count(for lens: SessionQuickStatusLens) -> Int {
        switch lens {
        case .attention: return attention
        case .running: return running
        case .background: return background
        }
    }
}

/// Presentation only: request totals/kinds come from the hub, independently
/// of the capped request slice and the local read watermark.
enum SessionRowStatus: Equatable {
    case needsReply(Int)
    case needsApproval(Int)
    case needsAttention(Int)
    case running
    case background(Int)

    init?(summary: SessionSummary) {
        let count = summary.pendingRequestsCount
        if count > 0 {
            let kinds = Set(summary.pendingRequestKinds)
            if kinds == [.input] {
                self = .needsReply(count)
            } else if kinds == [.permission] {
                self = .needsApproval(count)
            } else {
                self = .needsAttention(count)
            }
        } else if summary.active && summary.thinking {
            self = .running
        } else if summary.active && summary.backgroundTaskCount > 0 {
            self = .background(summary.backgroundTaskCount)
        } else {
            return nil
        }
    }

    var isAttention: Bool {
        switch self {
        case .needsReply, .needsApproval, .needsAttention:
            return true
        case .running, .background:
            return false
        }
    }

    var quickLens: SessionQuickStatusLens {
        switch self {
        case .needsReply, .needsApproval, .needsAttention:
            return .attention
        case .running:
            return .running
        case .background:
            return .background
        }
    }

    /// Localize in the view so its locale also governs previews/specimens.
    var titleKey: String {
        switch self {
        case .needsReply: return "Needs reply"
        case .needsApproval: return "Needs approval"
        case .needsAttention: return "Needs attention"
        case .running: return "Running"
        case .background: return "Background"
        }
    }

    var count: Int? {
        switch self {
        case .needsReply(let count), .needsApproval(let count), .needsAttention(let count), .background(let count):
            return count
        case .running:
            return nil
        }
    }

    var symbolName: String? {
        switch self {
        case .needsReply: return "bubble.left.fill"
        case .needsApproval: return "hand.raised.fill"
        case .needsAttention: return "exclamationmark.bubble.fill"
        case .running: return "bolt.fill"
        case .background: return "arrow.triangle.2.circlepath"
        }
    }
}

struct MachineFilterUI: Identifiable, Equatable {
    /// Machine id or `unknownMachineFilterId`.
    let id: String
    let label: String
    let sessionCount: Int
}

struct TagFilterUI: Identifiable, Equatable {
    /// Lowercased normalized tag key.
    let id: String
    let label: String
    let sessionCount: Int
}

struct SessionTagGroup: Identifiable, Equatable {
    enum Kind: Equatable {
        case pinned
        case tag(String)
        case untagged
    }

    let id: String
    let kind: Kind
    let rows: [SessionRowUI]
}

/// Transient, per-home filters. Add future dimensions here, not to navigation.
struct SessionListFilters: Equatable, Hashable {
    var dateStart: Date?
    var dateEnd: Date?
    var machineId: String?
    var tag: String?
    /// Web "unread only" lens: hide sessions already read in this namespace.
    var unreadOnly = false
    /// Non-reordering quick status filter toggled from the top summary bar.
    var statusLens: SessionQuickStatusLens?

    var isActive: Bool { machineId != nil || tag != nil || unreadOnly || dateStart != nil || statusLens != nil }
}

/// Session-list presentation state over the `HubSession` stores — the iOS
/// counterpart of the Android reference's `SessionListViewModel`: row/filter
/// derivation, refresh + offline/loaded flags, last-seen stamping, and
/// pin/archive/rename/delete/reopen forwarding (optimism lives in the
/// store). The SSE
/// subscription itself is owned by `HubSession`, not this model.
@MainActor @Observable
final class SessionListModel {
    private let sessionStore: any SessionListStoring
    private let machineStore: any MachineListStoring
    private let lastSeenStore: LastSeenStore
    private let hubUrl: String
    private let preferences: UserDefaults
    private var archivePreferenceKey: String { "hapi.showArchivedSessions." + hubUrl }
    private var groupByTagPreferenceKey: String { "hapi.groupByTag." + hubUrl }
    private var collapsedTagGroupsPreferenceKey: String { "hapi.collapsedTagGroups." + hubUrl }
    private(set) var showArchivedSessions = false
    private(set) var activeOnly = false
    private(set) var groupByTag = false
    private(set) var collapsedTagGroups: Set<String> = []

    func setActiveOnly(_ enabled: Bool) {
        activeOnly = enabled
        preferences.set(enabled, forKey: "hapi.activeOnly." + hubUrl)
    }

    func setShowArchivedSessions(_ enabled: Bool) {
        showArchivedSessions = enabled
        preferences.set(enabled, forKey: archivePreferenceKey)
    }

    func setGroupByTag(_ enabled: Bool) {
        groupByTag = enabled
        preferences.set(enabled, forKey: groupByTagPreferenceKey)
    }

    func isTagGroupCollapsed(_ groupId: String) -> Bool {
        collapsedTagGroups.contains(groupId)
    }

    func toggleTagGroupCollapsed(_ groupId: String) {
        if collapsedTagGroups.contains(groupId) {
            collapsedTagGroups.remove(groupId)
        } else {
            collapsedTagGroups.insert(groupId)
        }
        preferences.set(Array(collapsedTagGroups), forKey: collapsedTagGroupsPreferenceKey)
    }
    /// Reopen follows a superseding id with the composer draft (web
    /// `transferComposerDraftThenNavigate`).
    private let drafts: (any ChatDrafts)?

    /// Not persisted: a new home / hub starts with all sessions.
    private(set) var filters = SessionListFilters()
    /// Text search (`.searchable`); ranks by relevance while non-blank.
    var searchQuery = ""
    /// The split detail's session stays listed under the unread lens.
    var selectedSessionId: String?
    private(set) var isRefreshing = false
    /// Last refresh failed — show the offline state over snapshot data.
    private(set) var isOffline = false
    /// Last successful list fetch, for the offline notice's "updated …".
    private(set) var lastRefreshedAt: Date?
    private(set) var hasRefreshedOnce = false
    @ObservationIgnored private var hasAttemptedRefresh = false
    /// Transient row-action failure for an alert.
    var actionError: String?

    convenience init(session: HubSession) {
        self.init(
            sessionStore: session.sessionStore, machineStore: session.machineStore,
            lastSeenStore: session.lastSeenStore, hubUrl: session.hubUrl,
            drafts: UserDefaultsChatDrafts(scope: session.hubUrl)
        )
    }

    init(
        sessionStore: any SessionListStoring,
        machineStore: any MachineListStoring,
        lastSeenStore: LastSeenStore,
        hubUrl: String,
        drafts: (any ChatDrafts)? = nil,
        preferences: UserDefaults = .standard
    ) {
        self.sessionStore = sessionStore
        self.machineStore = machineStore
        self.lastSeenStore = lastSeenStore
        self.hubUrl = hubUrl
        self.drafts = drafts
        self.preferences = preferences
        self.showArchivedSessions = preferences.bool(forKey: "hapi.showArchivedSessions." + hubUrl)
        self.activeOnly = preferences.bool(forKey: "hapi.activeOnly." + hubUrl)
        self.groupByTag = preferences.bool(forKey: "hapi.groupByTag." + hubUrl)
        let savedCollapsed = preferences.stringArray(forKey: "hapi.collapsedTagGroups." + hubUrl) ?? []
        self.collapsedTagGroups = Set(savedCollapsed)
    }

    // MARK: - Derived state

    /// True once either the snapshot or a refresh produced a list.
    var hasLoaded: Bool {
        hasRefreshedOnce || !sessionStore.sessions.isEmpty
    }

    /// All session groups, including historical / unidentified machines.
    /// The online roster is only a source of labels, never filter membership.
    var machineFilterIds: Set<String> {
        Set(sessionStore.sessions.map { $0.metadata?.machineId ?? unknownMachineFilterId })
    }

    /// Counts are pre-filter. Names, not live counts, determine menu order.
    var machineFilters: [MachineFilterUI] {
        var counts: [String: Int] = [:]
        for summary in sessionStore.sessions {
            let id = summary.metadata?.machineId ?? unknownMachineFilterId
            counts[id, default: 0] += 1
        }
        var names: [String: String] = [:]
        for machine in machineStore.machines where counts[machine.id] != nil {
            guard let metadata = machine.metadata else { continue }
            let displayName = metadata.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let host = metadata.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = displayName.isEmpty ? host : displayName
            if !name.isEmpty { names[machine.id] = name }
        }
        let nameCounts = Dictionary(grouping: names.values, by: { $0.lowercased() }).mapValues(\.count)
        return counts
            .map { entry in
                let id = entry.key
                let label: String
                if id == unknownMachineFilterId {
                    label = String(localized: "Unknown machine")
                } else if let name = names[id] {
                    label = nameCounts[name.lowercased(), default: 0] > 1
                        ? "\(name) · \(id.prefix(8))" : name
                } else {
                    label = String(format: String(localized: "Machine · %@"), String(id.prefix(8)))
                }
                return MachineFilterUI(id: id, label: label, sessionCount: entry.value)
            }
            .sorted { lhs, rhs in
                func rank(_ id: String) -> Int {
                    id == unknownMachineFilterId ? 2 : (names[id] == nil ? 1 : 0)
                }
                if rank(lhs.id) != rank(rhs.id) { return rank(lhs.id) < rank(rhs.id) }
                let order = lhs.label.localizedStandardCompare(rhs.label)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }

    /// The menu also holds the unread lens and Mark All as Read.
    var showsFilterMenu: Bool {
        !sessionStore.sessions.isEmpty || filters.isActive || activeOnly || groupByTag
    }

    var tagFilters: [TagFilterUI] {
        var counts: [String: Int] = [:]
        var displayLabels: [String: String] = [:]
        for summary in sessionStore.sessions {
            guard showArchivedSessions || summary.metadata?.lifecycleState != "archived" || summary.id == selectedSessionId else {
                continue
            }
            for rawTag in summary.metadata?.tags ?? [] {
                let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = trimmed.lowercased()
                counts[key, default: 0] += 1
                if displayLabels[key] == nil {
                    displayLabels[key] = trimmed
                }
            }
        }
        return counts.map { key, count in
            TagFilterUI(id: key, label: displayLabels[key] ?? key, sessionCount: count)
        }.sorted { lhs, rhs in
            let order = lhs.label.localizedStandardCompare(rhs.label)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    var availableTags: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for summary in sessionStore.sessions {
            for rawTag in summary.metadata?.tags ?? [] {
                let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = trimmed.lowercased()
                guard seen.insert(key).inserted else { continue }
                result.append(trimmed)
            }
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var showsTagFilter: Bool {
        !tagFilters.isEmpty
    }

    var activeTagFilter: String? {
        guard let tag = filters.tag else { return nil }
        let normalized = tag.lowercased()
        guard tagFilters.contains(where: { $0.id == normalized }) else { return nil }
        return normalized
    }

    var hasHiddenArchivedSessions: Bool {
        !showArchivedSessions && sessionStore.sessions.contains { $0.metadata?.lifecycleState == "archived" }
    }

    var showsMachineFilter: Bool {
        machineFilterIds.count >= 2
    }

    var hasActiveFilters: Bool {
        activeMachineFilter != nil || activeTagFilter != nil || filters.unreadOnly || activeOnly || filters.dateStart != nil || filters.statusLens != nil
    }

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Never render an invalid filter, even before the view reconciles it.
    var activeMachineFilter: String? {
        guard let machineId = filters.machineId else { return nil }
        let ids = machineFilterIds
        guard ids.count >= 2, ids.contains(machineId) else {
            return nil
        }
        return machineId
    }

    var filterSummary: String? {
        var parts: [String] = []
        if let start = filters.dateStart, let end = filters.dateEnd {
            parts.append(start.formatted(date: .abbreviated, time: .omitted) + " – " + end.formatted(date: .abbreviated, time: .omitted))
        }
        if let lens = filters.statusLens {
            parts.append(lens.filterLabel)
        }
        if activeOnly { parts.append(String(localized: "Active Only")) }
        if filters.unreadOnly {
            parts.append(String(localized: "Unread only"))
        }
        if let tagId = activeTagFilter,
           let tagItem = tagFilters.first(where: { $0.id == tagId }) {
            parts.append(String(format: String(localized: "Tag: #%@"), tagItem.label))
        }
        if let id = activeMachineFilter,
           let machine = machineFilters.first(where: { $0.id == id }) {
            parts.append(String(format: String(localized: "Machine: %@"), machine.label))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Counts for the Option-B quick status summary bar, scoped to the current
    /// non-status-lens session pool so tapping a status pill keeps peer counts visible.
    var statusSummaryCounts: SessionStatusSummaryCounts {
        var counts = SessionStatusSummaryCounts()
        for summary in filteredSessions(includeArchived: showArchivedSessions, applyStatusLens: false) {
            guard let status = SessionRowStatus(summary: summary) else { continue }
            switch status.quickLens {
            case .attention: counts.attention += 1
            case .running: counts.running += 1
            case .background: counts.background += 1
            }
        }
        return counts
    }

    var showsStatusSummaryBar: Bool {
        statusSummaryCounts.hasAny || filters.statusLens != nil
    }

    func setStatusLens(_ lens: SessionQuickStatusLens?) {
        filters.statusLens = lens
    }

    func toggleStatusLens(_ lens: SessionQuickStatusLens) {
        if filters.statusLens == lens {
            filters.statusLens = nil
        } else {
            filters.statusLens = lens
        }
    }

    func markUnread(_ summary: SessionSummary) {
        Task {
            await lastSeenStore.markUnread(sessionId: summary.id, serverState: summary.readState)
            if let error = lastSeenStore.persistenceError { actionError = error }
        }
    }

    func saveTitle(_ row: SessionRowUI, name: String?, locked: Bool, tags: [String]? = nil) async throws {
        try await sessionStore.updateTitle(sessionId: row.id, name: name, locked: locked, tags: tags)
    }

    func setTags(_ row: SessionRowUI, tags: [String]) {
        let store = sessionStore
        Task {
            do {
                try await store.updateTags(sessionId: row.id, tags: tags)
            } catch {
                self.actionError = String(
                    format: String(localized: "Update tags failed: %@"),
                    error.localizedDescription
                )
            }
        }
    }

    func toggleTag(_ row: SessionRowUI, tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = trimmed.lowercased()
        var updated = row.tags
        if let existingIndex = updated.firstIndex(where: { $0.lowercased() == key }) {
            updated.remove(at: existingIndex)
        } else {
            updated.append(trimmed)
        }
        setTags(row, tags: updated)
    }

    func setDateRange(start: Date?, end: Date?) {
        guard let start, let end else { filters.dateStart = nil; filters.dateEnd = nil; return }
        filters.dateStart = min(start, end)
        filters.dateEnd = max(start, end)
    }

    static func matchesDate(_ timestamp: Int, start: Date?, end: Date?, calendar: Calendar = .current) -> Bool {
        guard let start, let end,
              let upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) else { return true }
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
        return date >= calendar.startOfDay(for: start) && date < upper
    }

    func setUnreadOnly(_ enabled: Bool) {
        filters.unreadOnly = enabled
    }

    /// Content not yet read by a client in this namespace.
    var unreadCount: Int {
        let readState = lastSeenStore.state
        let followedTails = lastSeenStore.followedTails
        return sessionStore.sessions.filter {
            LastSeenStore.isUnread($0, state: readState, followedTails: followedTails)
        }.count
    }

    /// Capture the observed heads; concurrent output must remain unread.
    func markAllRead() {
        let observed = sessionStore.sessions
        Task {
            for summary in observed {
                await lastSeenStore.markSeen(sessionId: summary.id,
                    revision: summary.contentRevision ?? 0, serverState: summary.readState)
            }
            if let error = lastSeenStore.persistenceError { actionError = error }
        }
    }

    /// Swipe action: mark the observed head of one session as read.
    func markRead(sessionId: String) {
        guard let summary = sessionStore.sessions.first(where: { $0.id == sessionId }) else { return }
        Task {
            await lastSeenStore.markSeen(sessionId: summary.id,
                revision: summary.contentRevision ?? 0, serverState: summary.readState)
            if let error = lastSeenStore.persistenceError { actionError = error }
        }
    }

    func selectMachine(_ id: String?) {
        filters.machineId = id
        reconcileFilters()
    }

    func selectTag(_ tag: String?) {
        filters.tag = tag?.lowercased()
        reconcileFilters()
    }

    func clearFilters() {
        filters = SessionListFilters()
        setActiveOnly(false)
    }

    /// Clear the stored pick as well, so a vanished group cannot resurrect it.
    func reconcileFilters() {
        if filters.machineId != activeMachineFilter {
            filters.machineId = nil
        }
        if filters.tag != activeTagFilter {
            filters.tag = nil
        }
    }

    /// Machine filter → tag filter → unread lens → text search (relevance order, pin
    /// sections kept so the Pinned header still applies).
    var hasArchivedSearchMatches: Bool {
        isSearching && !showArchivedSessions
            && filteredSessions(includeArchived: true).contains {
                $0.metadata?.lifecycleState == "archived" && $0.id != selectedSessionId
            }
    }

    private func filteredSessions(includeArchived: Bool, applyStatusLens: Bool = true) -> [SessionSummary] {
        let readState = lastSeenStore.state
        let followedTails = lastSeenStore.followedTails
        let activeFilter = activeMachineFilter
        let activeTag = activeTagFilter
        var visible = sessionStore.sessions.filter { summary in
            guard Self.matchesDate(summary.updatedAt, start: filters.dateStart, end: filters.dateEnd) else { return false }
            guard !activeOnly || summary.active || summary.id == selectedSessionId else { return false }
            guard includeArchived || summary.metadata?.lifecycleState != "archived" || summary.id == selectedSessionId else { return false }
            if let activeTag {
                let tags = summary.metadata?.tags ?? []
                guard tags.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == activeTag }) else {
                    return false
                }
            }
            guard let activeFilter else { return true }
            return (summary.metadata?.machineId ?? unknownMachineFilterId) == activeFilter
        }
        if filters.unreadOnly {
            visible = visible.filter { summary in
                summary.id == selectedSessionId
                    || LastSeenStore.isUnread(summary, state: readState, followedTails: followedTails)
            }
        }
        if applyStatusLens, let statusLens = filters.statusLens {
            visible = visible.filter { summary in
                summary.id == selectedSessionId
                    || SessionRowStatus(summary: summary)?.quickLens == statusLens
            }
        }
        if isSearching {
            let labels = Dictionary(uniqueKeysWithValues: machineFilters.map { ($0.id, $0.label) })
            if let index = SessionListSearch.scoreIndex(sessions: visible, query: searchQuery, machineLabel: { id in
                labels[id ?? unknownMachineFilterId] ?? ""
            }) {
                visible = SessionListSearch.rank(visible, by: index)
            }
        }
        return visible
    }

    var rows: [SessionRowUI] {
        let readState = lastSeenStore.state
        let followedTails = lastSeenStore.followedTails
        let visible = filteredSessions(includeArchived: showArchivedSessions)
        let titleById = Dictionary(
            sessionStore.sessions.map { ($0.id, Self.sessionTitle($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        if hasActiveFilters || isSearching || groupByTag {
            return visible.map { summary in
                let parentHint = Self.rawParentSessionId(summary).map {
                    Self.resolveParentTitle($0, titleById: titleById)
                }
                return SessionRowUI(
                    summary: summary,
                    title: Self.sessionTitle(summary),
                    project: Self.projectLabel(summary),
                    flavor: summary.metadata?.flavor,
                    unread: LastSeenStore.isUnread(summary, state: readState, followedTails: followedTails),
                    parentHint: parentHint
                )
            }
        }
        return Self.buildHierarchyRows(
            from: visible,
            titleById: titleById,
            readState: readState,
            followedTails: followedTails
        )
    }

    private static func rawParentSessionId(_ summary: SessionSummary) -> String? {
        guard let raw = summary.metadata?.parentSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw != summary.id else {
            return nil
        }
        return raw
    }

    private static func resolveParentTitle(_ parentId: String, titleById: [String: String]) -> String {
        titleById[parentId] ?? String(parentId.prefix(8))
    }

    private static func pinTier(_ summary: SessionSummary) -> Int {
        if summary.globalPinned == true { return 2 }
        if summary.pinned == true { return 1 }
        return 0
    }

    private static func orderTimestamp(_ summary: SessionSummary) -> Int {
        summary.lastUserMessageAt ?? summary.createdAt ?? 0
    }

    private static func buildHierarchyRows(
        from visible: [SessionSummary],
        titleById: [String: String],
        readState: LastSeenState,
        followedTails: [String: Int]
    ) -> [SessionRowUI] {
        guard !visible.isEmpty else { return [] }

        final class Node {
            let summary: SessionSummary
            let originalIndex: Int
            var children: [Node] = []
            var subtreeOrderAt: Int

            init(summary: SessionSummary, originalIndex: Int, subtreeOrderAt: Int) {
                self.summary = summary
                self.originalIndex = originalIndex
                self.subtreeOrderAt = subtreeOrderAt
            }
        }

        var byId: [String: SessionSummary] = [:]
        var nodeById: [String: Node] = [:]
        var orderedNodes: [Node] = []
        orderedNodes.reserveCapacity(visible.count)

        for (index, summary) in visible.enumerated() where byId[summary.id] == nil {
            byId[summary.id] = summary
            let node = Node(
                summary: summary,
                originalIndex: index,
                subtreeOrderAt: orderTimestamp(summary)
            )
            nodeById[summary.id] = node
            orderedNodes.append(node)
        }

        func canAttach(child: SessionSummary, parent _: SessionSummary) -> Bool {
            pinTier(child) == 0
        }

        var candidateParentById: [String: String] = [:]
        candidateParentById.reserveCapacity(orderedNodes.count)
        for node in orderedNodes {
            let summary = node.summary
            guard let rawParentId = rawParentSessionId(summary),
                  let parent = byId[rawParentId],
                  canAttach(child: summary, parent: parent) else {
                continue
            }
            candidateParentById[summary.id] = parent.id
        }

        // 3-state iterative memoization: 1 = visiting on current path, 2 = resolved.
        var visitState: [String: UInt8] = [:]
        var reachesCycle: [String: Bool] = [:]
        visitState.reserveCapacity(orderedNodes.count)
        reachesCycle.reserveCapacity(orderedNodes.count)

        for node in orderedNodes {
            let startId = node.summary.id
            if visitState[startId] == 2 { continue }
            var chain: [String] = []
            var cursor: String? = startId
            var hitCycle = false
            while let current = cursor {
                if let state = visitState[current] {
                    if state == 1 {
                        hitCycle = true
                    } else {
                        hitCycle = reachesCycle[current] ?? false
                    }
                    break
                }
                visitState[current] = 1
                chain.append(current)
                cursor = candidateParentById[current]
            }
            for id in chain {
                visitState[id] = 2
                reachesCycle[id] = hitCycle
            }
        }

        var resolvedParentById: [String: String] = [:]
        resolvedParentById.reserveCapacity(candidateParentById.count)
        for (id, parentId) in candidateParentById where reachesCycle[id] != true {
            resolvedParentById[id] = parentId
        }

        var roots: [Node] = []
        for node in orderedNodes {
            if let parentId = resolvedParentById[node.summary.id],
               let parentNode = nodeById[parentId] {
                parentNode.children.append(node)
            } else {
                roots.append(node)
            }
        }

        func siblingPrecedes(_ lhs: Node, _ rhs: Node) -> Bool {
            if lhs.subtreeOrderAt != rhs.subtreeOrderAt {
                return lhs.subtreeOrderAt > rhs.subtreeOrderAt
            }
            let lhsCreated = lhs.summary.createdAt ?? 0
            let rhsCreated = rhs.summary.createdAt ?? 0
            if lhsCreated != rhsCreated {
                return lhsCreated > rhsCreated
            }
            return lhs.originalIndex < rhs.originalIndex
        }

        struct FinalizeFrame {
            let node: Node
            var expanded: Bool
        }
        var finalizeStack: [FinalizeFrame] = roots.reversed().map { FinalizeFrame(node: $0, expanded: false) }
        while let frame = finalizeStack.last {
            if !frame.expanded {
                finalizeStack[finalizeStack.count - 1].expanded = true
                for child in frame.node.children.reversed() {
                    finalizeStack.append(FinalizeFrame(node: child, expanded: false))
                }
            } else {
                finalizeStack.removeLast()
                let node = frame.node
                for child in node.children where child.subtreeOrderAt > node.subtreeOrderAt {
                    node.subtreeOrderAt = child.subtreeOrderAt
                }
                if node.children.count > 1 {
                    node.children.sort(by: siblingPrecedes)
                }
            }
        }

        roots.sort { lhs, rhs in
            let lhsTier = pinTier(lhs.summary)
            let rhsTier = pinTier(rhs.summary)
            if lhsTier != rhsTier {
                return lhsTier > rhsTier
            }
            return siblingPrecedes(lhs, rhs)
        }

        var result: [SessionRowUI] = []
        result.reserveCapacity(orderedNodes.count)

        func appendRow(
            _ summary: SessionSummary,
            hierarchy: SessionTreeConnector?,
            parentHint: String?,
            inPinnedSection: Bool
        ) {
            result.append(
                SessionRowUI(
                    summary: summary,
                    title: sessionTitle(summary),
                    project: projectLabel(summary),
                    flavor: summary.metadata?.flavor,
                    unread: LastSeenStore.isUnread(summary, state: readState, followedTails: followedTails),
                    hierarchy: hierarchy,
                    parentHint: parentHint,
                    inPinnedSection: inPinnedSection
                )
            )
        }

        struct WalkFrame {
            let children: [Node]
            var index: Int
            let depth: Int
            let directParentId: String
            let level1HasNextSibling: Bool
        }

        for root in roots {
            let inPinned = pinTier(root.summary) > 0
            let rootHint = rawParentSessionId(root.summary).map {
                resolveParentTitle($0, titleById: titleById)
            }
            appendRow(root.summary, hierarchy: nil, parentHint: rootHint, inPinnedSection: inPinned)
            if !root.children.isEmpty {
                var walkStack: [WalkFrame] = [
                    WalkFrame(
                        children: root.children,
                        index: 0,
                        depth: 1,
                        directParentId: root.summary.id,
                        level1HasNextSibling: false
                    ),
                ]
                while let topIndex = walkStack.indices.last {
                    let idx = walkStack[topIndex].index
                    let children = walkStack[topIndex].children
                    if idx >= children.count {
                        walkStack.removeLast()
                        continue
                    }
                    walkStack[topIndex].index = idx + 1
                    let depth = walkStack[topIndex].depth
                    let directParentId = walkStack[topIndex].directParentId
                    let level1HasNextSibling = walkStack[topIndex].level1HasNextSibling

                    let child = children[idx]
                    let isLast = idx == children.count - 1
                    let visualDepth = depth == 1 ? 1 : 2
                    let isDepthCapped = depth >= 3
                    let continuesAtLevel1 = depth >= 2 ? level1HasNextSibling : false
                    let connector = SessionTreeConnector(
                        visualDepth: visualDepth,
                        continuesAtLevel1: continuesAtLevel1,
                        isLastChild: isDepthCapped ? true : isLast,
                        isDepthCapped: isDepthCapped
                    )
                    let hint = isDepthCapped ? resolveParentTitle(directParentId, titleById: titleById) : nil
                    appendRow(
                        child.summary,
                        hierarchy: connector,
                        parentHint: hint,
                        inPinnedSection: inPinned
                    )
                    if !child.children.isEmpty {
                        let nextLevel1Sibling = depth == 1 ? !isLast : level1HasNextSibling
                        walkStack.append(
                            WalkFrame(
                                children: child.children,
                                index: 0,
                                depth: depth + 1,
                                directParentId: child.summary.id,
                                level1HasNextSibling: nextLevel1Sibling
                            )
                        )
                    }
                }
            }
        }

        return result
    }

    /// Unique session ids in current visual display order (respects `groupByTag` and collapsed tag groups).
    var displayOrderSessionIds: [String] {
        let currentRows = rows
        guard groupByTag else { return currentRows.map(\.id) }
        var seen = Set<String>()
        var ordered: [String] = []
        for group in Self.tagGroups(of: currentRows) where !isTagGroupCollapsed(group.id) {
            for row in group.rows where seen.insert(row.id).inserted {
                ordered.append(row.id)
            }
        }
        return ordered
    }

    struct QuickSwitchCandidate: Identifiable, Equatable {
        let row: SessionRowUI
        let machineLabel: String?
        let path: String?
        let isArchived: Bool
        var id: String { row.id }
    }

    /// Candidates for the ⌘K quick switcher: when query is blank, shows non-archived
    /// sessions in standard order; when query is non-blank, fuzzy-ranks all sessions
    /// (including archived ones) by title, project, path, and machine name.
    func quickSwitchCandidates(query: String) -> [QuickSwitchCandidate] {
        let readState = lastSeenStore.state
        let followedTails = lastSeenStore.followedTails
        let labels = Dictionary(uniqueKeysWithValues: machineFilters.map { ($0.id, $0.label) })
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool: [SessionSummary]
        if trimmed.isEmpty {
            pool = sessionStore.sessions.filter {
                showArchivedSessions || $0.metadata?.lifecycleState != "archived" || $0.id == selectedSessionId
            }
        } else if let index = SessionListSearch.scoreIndex(
            sessions: sessionStore.sessions,
            query: trimmed,
            machineLabel: { id in labels[id ?? unknownMachineFilterId] ?? "" }
        ) {
            pool = SessionListSearch.rank(sessionStore.sessions, by: index)
        } else {
            pool = []
        }
        return pool.prefix(50).map { summary in
            let row = SessionRowUI(
                summary: summary,
                title: Self.sessionTitle(summary),
                project: Self.projectLabel(summary),
                flavor: summary.metadata?.flavor,
                unread: LastSeenStore.isUnread(summary, state: readState, followedTails: followedTails)
            )
            let machineId = summary.metadata?.machineId
            let machine = machineId.flatMap { labels[$0] }
            let path = summary.metadata?.worktree?.basePath ?? summary.metadata?.path
            let archived = summary.metadata?.lifecycleState == "archived"
            return QuickSwitchCandidate(
                row: row,
                machineLabel: machine,
                path: path,
                isArchived: archived
            )
        }
    }

    /// The sort contract puts globalPinned/pinned root units first; this boundary
    /// index is where the pinned section ends.
    static func pinnedCount(of rows: [SessionRowUI]) -> Int {
        rows.prefix { $0.belongsToPinnedSection }.count
    }

    /// Groups rows by tag for the sidebar's "Group by Tag" mode.
    /// Pinned sessions stay in the top Pinned section, every tag gets its own
    /// alphabetically sorted section, and untagged non-pinned rows appear under Untagged.
    static func tagGroups(of rows: [SessionRowUI]) -> [SessionTagGroup] {
        guard !rows.isEmpty else { return [] }
        var groups: [SessionTagGroup] = []
        let pinnedCount = pinnedCount(of: rows)
        if pinnedCount > 0 {
            groups.append(
                SessionTagGroup(
                    id: "__pinned__",
                    kind: .pinned,
                    rows: Array(rows.prefix(pinnedCount))
                )
            )
        }

        var tagRowsByKey: [String: [SessionRowUI]] = [:]
        var tagDisplayByKey: [String: String] = [:]
        var untaggedRows: [SessionRowUI] = []

        for row in rows {
            let cleanTags = row.tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if cleanTags.isEmpty {
                let isPinned = row.summary.globalPinned == true || row.summary.pinned == true
                if !isPinned {
                    untaggedRows.append(row)
                }
            } else {
                var seenKeys = Set<String>()
                for tag in cleanTags {
                    let key = tag.lowercased()
                    guard seenKeys.insert(key).inserted else { continue }
                    if tagDisplayByKey[key] == nil {
                        tagDisplayByKey[key] = tag
                    }
                    tagRowsByKey[key, default: []].append(row)
                }
            }
        }

        let sortedKeys = tagRowsByKey.keys.sorted { lhs, rhs in
            let leftLabel = tagDisplayByKey[lhs] ?? lhs
            let rightLabel = tagDisplayByKey[rhs] ?? rhs
            let order = leftLabel.localizedStandardCompare(rightLabel)
            return order == .orderedSame ? lhs < rhs : order == .orderedAscending
        }

        for key in sortedKeys {
            guard let groupRows = tagRowsByKey[key], !groupRows.isEmpty else { continue }
            let label = tagDisplayByKey[key] ?? key
            groups.append(
                SessionTagGroup(
                    id: "tag:" + key,
                    kind: .tag(label),
                    rows: groupRows
                )
            )
        }

        if !untaggedRows.isEmpty {
            groups.append(
                SessionTagGroup(
                    id: "__untagged__",
                    kind: .untagged,
                    rows: untaggedRows
                )
            )
        }

        return groups
    }

    /// Use the worktree's owning project, not its temporary checkout name.
    /// The home needs a scan key, not a repeated path or machine inventory.
    static func projectLabel(_ summary: SessionSummary) -> String? {
        guard let path = summary.metadata?.worktree?.basePath ?? summary.metadata?.path else { return nil }
        return path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
    }

    // MARK: - Actions

    /// A split sidebar can disappear/reappear just because the window
    /// collapses. Fetch once per home, not once per layout transition;
    /// global SSE recovery and explicit pull-to-refresh still fetch normally.
    func refreshOnFirstAppearance() async {
        guard !hasAttemptedRefresh else { return }
        hasAttemptedRefresh = true
        // The sidebar's SwiftUI task is cancelled when it collapses. The
        // initial fetch belongs to the model, not that transient presentation.
        await Task { await self.refresh() }.value
    }

    /// Pull-to-refresh / initial load. Coalesces concurrent calls.
    func refresh() async {
        guard !isRefreshing else { return }
        hasAttemptedRefresh = true
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await sessionStore.refresh()
            reconcileFilters()
            isOffline = false
            lastRefreshedAt = Date()
            hasRefreshedOnce = true
            do { try await machineStore.refresh() }
            catch { actionError = error.localizedDescription }
        } catch {
            isOffline = true
        }
    }

    /// `PUT /sessions/:id/pin` with store-side optimistic re-sort; failures
    /// surface on `actionError`.
    func setPinMode(sessionId: String, mode: SessionPinMode) {
        let store = sessionStore
        Task {
            do {
                try await store.setPinMode(sessionId: sessionId, mode: mode)
            } catch {
                self.actionError = String(
                    format: String(localized: "Pin failed: %@"),
                    error.localizedDescription
                )
            }
        }
    }

    /// `POST /sessions/:id/archive` with server-confirmed list refresh;
    /// failures surface on `actionError`.
    func archiveSession(sessionId: String) {
        let store = sessionStore
        Task {
            do {
                try await store.archiveSession(sessionId: sessionId)
            } catch {
                self.actionError = String(
                    format: String(localized: "Archive failed: %@"),
                    error.localizedDescription
                )
            }
        }
    }

    /// `PATCH /sessions/:id` with a store-side optimistic name.
    func renameSession(sessionId: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let store = sessionStore
        Task {
            do {
                try await store.renameSession(sessionId: sessionId, name: trimmed)
            } catch {
                self.actionError = String(
                    format: String(localized: "Rename failed: %@"),
                    error.localizedDescription
                )
            }
        }
    }

    /// `DELETE /sessions/:id` (inactive sessions only) with store-side
    /// optimistic removal; a 409 means it became active again.
    func deleteSession(sessionId: String) {
        let store = sessionStore
        Task {
            do {
                try await store.deleteSession(sessionId: sessionId)
            } catch {
                self.actionError = isActiveSessionConflict(error)
                    ? String(localized: "Active sessions can't be deleted — archive first")
                    : String(format: String(localized: "Delete failed: %@"), error.localizedDescription)
            }
        }
    }

    /// `POST /sessions/:id/reopen`, then open the (possibly superseding)
    /// session, carrying its composer draft along.
    func reopenSession(sessionId: String, onReopened: @escaping @MainActor (String) -> Void) {
        let store = sessionStore
        Task {
            do {
                let response = try await store.reopenSession(sessionId: sessionId)
                if response.sessionId != sessionId {
                    self.drafts?.move(fromSessionId: sessionId, toSessionId: response.sessionId)
                }
                onReopened(response.sessionId)
            } catch {
                self.actionError = formatReopenError(error)
                    ?? String(localized: "Failed to reopen session")
            }
        }
    }

    // MARK: - Helpers

    /// `getSessionTitle` (`web/src/lib/sessionTitle.ts`): name → summary
    /// text → path tail → id prefix.
    static func sessionTitle(_ summary: SessionSummary) -> String {
        SessionListSearch.sessionTitle(summary)
    }
}

/// Compact relative-age label for list rows ("now", "5m", "3h", "2d").
/// Minute granularity is deliberate: it is why sub-minute `activeAt` churn
/// can be dropped as render-irrelevant (`sse.md#keep-alive-noise`). Mirrors
/// the Android reference (`formatRelativeAge`).
func formatRelativeAge(now: Date, thenEpochMs: Int) -> String {
    let delta = Int(now.timeIntervalSince1970 * 1000) - thenEpochMs
    if delta < 60_000 { return String(localized: "now") }
    let minutes = delta / 60_000
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 7 { return "\(days)d" }
    let weeks = days / 7
    if weeks < 5 { return "\(weeks)w" }
    let months = days / 30
    if months < 12 { return "\(months)mo" }
    return "\(days / 365)y"
}
