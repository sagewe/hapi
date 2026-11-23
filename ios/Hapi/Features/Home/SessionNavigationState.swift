import Observation
import SwiftUI

/// In-memory navigation for one hub's iPad workspace. Window geometry never
/// owns selection: filtering, collapsing and reopening the sidebar must not
/// discard the selected chat or its nested file/process navigation.
@MainActor @Observable
final class SessionNavigationState {
    private(set) var selectedSessionId: String?
    #if targetEnvironment(macCatalyst)
    /// Keep native chat hierarchies warm without retaining every opened session.
    private(set) var recentSessionIds: [String] = []
    @ObservationIgnored private var detailAccessOrder: [String] = []
    #endif
    var detailPath = NavigationPath()
    var columnVisibility: NavigationSplitViewVisibility = .all
    var preferredCompactColumn: NavigationSplitViewColumn = .sidebar

    func open(_ sessionId: String) {
        if selectedSessionId != sessionId {
            detailPath = NavigationPath()
            #if targetEnvironment(macCatalyst)
            detailAccessOrder.removeAll { $0 == sessionId }
            detailAccessOrder.append(sessionId)
            if !recentSessionIds.contains(sessionId) { recentSessionIds.append(sessionId) }
            while detailAccessOrder.count > 3 {
                let evicted = detailAccessOrder.removeFirst()
                recentSessionIds.removeAll { $0 == evicted }
            }
            #endif
            selectedSessionId = sessionId
        }
        // Also works for notifications/new sessions not yet in the list.
        preferredCompactColumn = .detail
    }

    func supersede(_ sessionId: String, with replacement: String) {
        guard selectedSessionId == sessionId else { return }
        open(replacement)
    }

    #if targetEnvironment(macCatalyst)
    func releaseInactiveDetails() {
        recentSessionIds.removeAll { $0 != selectedSessionId }
        detailAccessOrder = recentSessionIds
    }
    #endif

    func remove(_ sessionId: String) {
        #if targetEnvironment(macCatalyst)
        recentSessionIds.removeAll { $0 == sessionId }
        detailAccessOrder.removeAll { $0 == sessionId }
        #endif
        guard selectedSessionId == sessionId else { return }
        detailPath = NavigationPath()
        selectedSessionId = nil
        preferredCompactColumn = .sidebar
    }
}
