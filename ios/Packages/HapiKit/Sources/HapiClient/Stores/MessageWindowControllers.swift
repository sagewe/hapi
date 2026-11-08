import Foundation
import HapiProtocol

/// Per-hub registry of per-session ``MessageWindowController``s — the
/// analogue of the web module's session-keyed maps and the Android port's
/// `MessageWindowStores`. ``open(sessionId:)`` hydrates a cold session from
/// its disk snapshot (interrupted `sending` rows restore, stale snapshots
/// start flagged for a latest reset); ``seed(fromSessionId:toSessionId:)``
/// carries a window across a resume/reopen id change. Snapshot files
/// themselves are LRU-capped by ``WindowSnapshotStore``.
public actor MessageWindowControllers {
    private let provider: any MessagesProviding
    private let snapshots: WindowSnapshotStore?
    private let visibleRetentionLimit: Int
    private let historyRetentionLimit: Int
    // Weak identity map plus a small LRU for resume/navigation handoffs. Live
    // owners can outlive eviction without creating two controllers for one ID.
    private final class Entry {
        weak var controller: MessageWindowController?
        init(_ controller: MessageWindowController) { self.controller = controller }
    }
    private var controllers: [String: Entry] = [:]
    private var recent: [String: MessageWindowController] = [:]
    private var recency: [String] = []
    private let maxCachedWindows: Int

    public init(provider: any MessagesProviding, snapshots: WindowSnapshotStore? = nil,
                visibleRetentionLimit: Int = MessageWindowConstants.visibleWindowSize,
                historyRetentionLimit: Int = MessageWindowConstants.historyWindowSize,
                maxCachedWindows: Int = 4) {
        self.provider = provider
        self.snapshots = snapshots
        self.visibleRetentionLimit = visibleRetentionLimit
        self.historyRetentionLimit = historyRetentionLimit
        self.maxCachedWindows = max(1, maxCachedWindows)
    }

    /// The session's controller, hydrating from its snapshot on first open.
    public func open(sessionId: String) -> MessageWindowController {
        if let existing = controllers[sessionId]?.controller {
            retainRecent(existing, sessionId: sessionId)
            return existing
        }
        controllers = controllers.filter { $0.value.controller != nil }
        let hydrated = snapshots?.load(sessionId: sessionId).map {
            MessageWindowLogic.hydrate(sessionId: sessionId, persisted: $0)
        }
        let controller = MessageWindowController(
            sessionId: sessionId,
            provider: provider,
            snapshots: snapshots,
            initialState: hydrated,
            visibleRetentionLimit: visibleRetentionLimit,
            historyRetentionLimit: historyRetentionLimit
        )
        controllers[sessionId] = Entry(controller)
        retainRecent(controller, sessionId: sessionId)
        return controller
    }

    private func retainRecent(_ controller: MessageWindowController, sessionId: String) {
        recent[sessionId] = controller
        recency.removeAll { $0 == sessionId }
        recency.append(sessionId)
        while recency.count > maxCachedWindows {
            recent.removeValue(forKey: recency.removeFirst())
        }
    }

    public func releaseCachedWindows() { recent.removeAll(); recency.removeAll() }

    /// Already-open controller, if any (no hydration).
    public func peek(sessionId: String) -> MessageWindowController? {
        controllers[sessionId]?.controller
    }

    /// Web `seedMessageWindowFromSession` for resume/reopen id migration.
    public func seed(fromSessionId: String, toSessionId: String) async {
        guard !fromSessionId.isEmpty, !toSessionId.isEmpty, fromSessionId != toSessionId else {
            return
        }
        let source = open(sessionId: fromSessionId)
        let target = open(sessionId: toSessionId)
        await target.seedFrom(source)
    }

    /// Web `clearMessageWindow` (e.g. on `session-removed`).
    public func clear(sessionId: String) async {
        await controllers[sessionId]?.controller?.clear()
    }

    public func flushPersistence() async {
        let live = controllers.values.compactMap(\.controller)
        for controller in live { await controller.flushPersistence() }
    }
}
