import Foundation
import HapiClient
import HapiProtocol
import HapiUI
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ChatHeaderStatus: Equatable {
    case needsReply(Int)
    case needsApproval(Int)
    case needsAttention(Int)
    case running
    case background(Int)
    case online
    case archived
    case offline

    var isAttention: Bool {
        switch self {
        case .needsReply, .needsApproval, .needsAttention:
            return true
        case .running, .background, .online, .archived, .offline:
            return false
        }
    }

    var showsInHeader: Bool {
        isAttention || self == .offline
    }

    var titleKey: String {
        switch self {
        case .needsReply: return "Needs reply"
        case .needsApproval: return "Needs approval"
        case .needsAttention: return "Needs attention"
        case .running: return "Running"
        case .background: return "Background"
        case .online: return "Online"
        case .archived: return "Archived"
        case .offline: return "Offline"
        }
    }

    var count: Int? {
        switch self {
        case .needsReply(let n), .needsApproval(let n), .needsAttention(let n), .background(let n):
            return n
        case .running, .online, .archived, .offline:
            return nil
        }
    }

    var symbolName: String {
        switch self {
        case .needsReply: return "bubble.left.fill"
        case .needsApproval: return "hand.raised.fill"
        case .needsAttention: return "exclamationmark.bubble.fill"
        case .running: return "bolt.fill"
        case .background: return "arrow.triangle.2.circlepath"
        case .online: return "circle.fill"
        case .archived: return "archivebox.fill"
        case .offline: return "circle"
        }
    }

    var systemSubtitlePrefix: String {
        switch self {
        case .needsReply(let n):
            return n > 1
                ? String(format: String(localized: "Needs reply (%lld)"), Int64(n))
                : String(localized: "Needs reply")
        case .needsApproval(let n):
            return n > 1
                ? String(format: String(localized: "Needs approval (%lld)"), Int64(n))
                : String(localized: "Needs approval")
        case .needsAttention(let n):
            return n > 1
                ? String(format: String(localized: "Needs attention (%lld)"), Int64(n))
                : String(localized: "Needs attention")
        case .running:
            return String(localized: "Running")
        case .background(let n):
            return String(format: String(localized: "Background (%lld)"), Int64(n))
        case .online:
            return String(localized: "Online")
        case .archived:
            return String(localized: "Archived")
        case .offline:
            return String(localized: "Offline")
        }
    }
}

/// Chat top-bar state: title cascade + status + meta line.
struct ChatHeaderUI: Equatable {
    var title: String
    /// Plain-text metadata for consumers outside the compact title row.
    var subtitle: String?
    /// Raw `metadata.flavor` — drives the brand icon next to the meta line.
    var flavor: String?
    var active: Bool
    var thinking: Bool
    var status: ChatHeaderStatus = .offline
    var parentSessionId: String? = nil
    var parentTitle: String? = nil
    var isParentNavigable: Bool = false
}

struct ChatTurnNavItem: Identifiable, Equatable, Sendable {
    let id: String
    let turnNumber: Int
    let userText: String
    let assistantPreview: String?
    let toolCount: Int
    let createdAt: Int
}

struct ChatMessageNavItem: Identifiable, Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case user
        case assistant
    }
    let id: String
    let role: Role
    let turnNumber: Int
    let text: String
    let createdAt: Int
}

struct ChatRailNavItem: Identifiable, Equatable, Sendable {
    let id: String
    let isUserTurn: Bool
    let turnNumber: Int
    let title: String
    let subtitle: String?
    let toolCount: Int
    let createdAt: Int
}

/// Presentation state machine for the read-only chat screen (M2f) — the iOS
/// counterpart of the Android `ChatViewModel`'s pipeline half. It combines
/// the message window's UI state with the cached session detail (whose
/// `agentState` carries permission verdicts) and machine labels, runs the
/// reduction pipeline **off the main actor** through ``ChatPipeline``, and
/// publishes render-ready `[VisibleChatBlock]` plus header/loading state.
///
/// Recompute scheduling mirrors the web's render batching (Android's
/// `sample(100ms)`): inputs bump a revision and a single serial loop drains
/// it — the first run starts immediately, later runs coalesce to at most one
/// per ~100 ms, and because exactly one loop runs at a time every publish is
/// computed-from-latest-at-start and strictly ordered (a stale run can never
/// overwrite a newer one — the race the "detached task keyed by revision"
/// design exists to prevent).
///
/// Pipeline memoization (normalize per row instance, `previousGroups` for
/// stable group ids) lives inside ``ChatPipeline``; see its docs.
@MainActor @Observable
final class ChatModel {


    let sessionId: String

    // MARK: Published render state

    private(set) var blocks: [VisibleChatBlock] = []
    private(set) var messageRows: [TranscriptRow] = []
    @ObservationIgnored private var executionCompletedRounds = Set<String>()
    @ObservationIgnored private var executionIsRunning = false
    @ObservationIgnored private var heldExecutionIDs = Set<String>()
    @ObservationIgnored private var executionGroups: [ToolGroupBlock] = []

    private(set) var header: ChatHeaderUI
    /// Workspace root, for path display in tool cards.
    private(set) var basePath: String?
    private(set) var hasMore = false
    private(set) var isLoadingOlder = false
    private(set) var isSyncingTail = true
    /// First sync still running and nothing (snapshot included) to show yet.
    private(set) var isInitialLoading = true
    /// Initial load produced nothing and the last attempt failed.
    private(set) var loadFailed = false
    /// Tail-sync warning — the degraded banner.
    private(set) var warning: String?
    /// Bumps on tail-side content changes.
    private(set) var tailRevision = 0
    private(set) var readThroughRevision: Int?
    private(set) var renderedReadState: SessionReadState?
    private var displayedReadRevision: Int?
    /// Bumps when an older page was prepended (drives scroll re-anchoring).
    private(set) var historyVersion = 0
    private(set) var historyPaging = ChatHistoryPagingState()
    private(set) var followsTail = true
    private(set) var jumpToLatestToken = 0
    private(set) var scrollTarget: TranscriptScrollTarget?
    private(set) var highlightedBlockID: String?
    private(set) var topVisibleBlockID: String?
    private(set) var userTurnItems: [ChatTurnNavItem] = []
    private(set) var allMessageNavItems: [ChatMessageNavItem] = []
    private(set) var railNavItems: [ChatRailNavItem] = []
    private(set) var isSeekingOlderTurn = false
    private(set) var isJumpingToLatest = false
    private(set) var hasTrimmedTail = false
    private var isAwayFromBottom = false
    @ObservationIgnored private var scrollTargetToken = 0
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    @ObservationIgnored private var olderTurnSeekTask: Task<Void, Never>?
    @ObservationIgnored private var hasAutoBackfilledTurns = false
    @ObservationIgnored private var blockIndexByID: [String: Int] = [:]
    @ObservationIgnored private var blockToUserTurnIndex: [String: Int] = [:]
    @ObservationIgnored private var blockToRailIndex: [String: Int] = [:]
    @ObservationIgnored private var cachedGroupPresentations: [String: (group: ToolGroupBlock, presentation: ToolGroupPresentation, row: TranscriptRow)] = [:]
    @ObservationIgnored private var cachedMessageRows: [String: (block: VisibleChatBlock, isHighlighted: Bool, row: TranscriptRow)] = [:]
    var showsJumpToLatest: Bool {
        isJumpingToLatest || hasTrimmedTail || (!followsTail && isAwayFromBottom)
    }

    /// 0-based index in `userTurnItems` corresponding to the user turn currently in view.
    var activeUserTurnIndex: Int? {
        guard !userTurnItems.isEmpty else { return nil }
        if followsTail {
            return userTurnItems.count - 1
        }
        guard let topID = topVisibleBlockID,
              let turnIdx = blockToUserTurnIndex[topID] else {
            return userTurnItems.count - 1
        }
        return turnIdx
    }

    /// 0-based index in `railNavItems` corresponding to the item currently in view.
    var activeRailIndex: Int? {
        guard !railNavItems.isEmpty else { return nil }
        if followsTail {
            return railNavItems.count - 1
        }
        guard let topID = topVisibleBlockID,
              let railIdx = blockToRailIndex[topID] else {
            return railNavItems.count - 1
        }
        return railIdx
    }
    let toolInspection = ToolInspectionState()
    private(set) var visibleSurfaces = Set<String>()
    var isInspectingContent: Bool {
        toolInspection.owner != nil || visibleSurfaces.contains {
            $0.hasPrefix("process:") || $0.hasPrefix("message:") || $0.hasPrefix("inspector:")
        }
    }

    /// Transient toast text (interaction failures/notices); auto-dismissed.
    private(set) var notice: String?
    /// Resume handed back a different session id — the view replaces its
    /// navigation entry with this one.
    private(set) var supersededSessionId: String?

    /// Delayed session-pipe notice; stable until the hub handshake arrives.
    var isReconnecting: Bool { chat.reconnectNotice.isVisible }

    // MARK: Export

    /// A hub answer that needs the user's decision before saving.
    enum ExportPrompt: Equatable {
        case warning(count: Int, limit: Int, estimatedBytes: Int)
        case tooLarge(count: Int, estimatedBytes: Int, maxBytes: Int)
    }

    enum ExportFormat { case json, markdown }
    private var exportFormat: ExportFormat = .json
    private(set) var isExporting = false
    var exportPrompt: ExportPrompt?
    /// Set when the export is ready; drives the Files save panel.
    var exportDocument: SessionExportDocument?

    /// `GET /export` (web JSON download); a large export asks first and is
    /// retried with `force`.
    func exportConversation(force: Bool = false, format: ExportFormat? = nil) {
        guard !isExporting else { return }
        if let format { exportFormat = format }
        let selectedFormat = exportFormat
        isExporting = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isExporting = false }
            do {
                switch try await self.hub.api.exportSession(sessionId: self.sessionId, force: force) {
                case .file(let file):
                    self.exportDocument = SessionExportDocument(file: selectedFormat == .markdown ? try file.markdown { eventPresentation($0).text } : file)
                case .warning(let count, let limit, let estimatedBytes):
                    self.exportPrompt = .warning(count: count, limit: limit, estimatedBytes: estimatedBytes)
                case .tooLarge(let count, let estimatedBytes, let maxBytes):
                    self.exportPrompt = .tooLarge(count: count, estimatedBytes: estimatedBytes, maxBytes: maxBytes)
                }
            } catch {
                self.showNotice(hubErrorMessage(error) ?? String(localized: "Failed to export conversation"))
            }
        }
    }

    func exportFinished(_ result: Result<URL, any Error>) {
        exportDocument = nil
        switch result {
        case .success:
            showNotice(String(localized: "Conversation exported"))
        case .failure(let error as CocoaError) where error.code == .userCancelled:
            break
        case .failure:
            showNotice(String(localized: "Failed to export conversation"))
        }
    }

    /// Loaded user messages with a native fork/rewind point, newest first.
    var historyPointMessages: [UserTextBlock] {
        blocks.reversed().compactMap { visible in
            guard case .block(.userText(let message)) = visible else { return nil }
            let actions = interactor.historyActions(forMessageLocalId: message.localId)
            return actions.fork || actions.rewind ? message : nil
        }
    }

    /// Lifecycle actions need a known state: nil until the detail or the
    /// list row is loaded (the header defaults to inactive before that).
    var sessionIsActive: Bool? {
        hub.sessionStore.detail(for: sessionId)?.active
            ?? hub.sessionStore.sessions.first { $0.id == sessionId }?.active
    }

    // MARK: Wiring

    private let hub: HubSession
    /// Rebuilt on every `start()` after a `stop()` — a `ChatSession` is
    /// single-use (its SSE client cannot restart), and the saved resume
    /// cursor makes the rebuild cheap. This absorbs SwiftUI's
    /// appear/disappear cycles around full-screen presentations.
    private var chat: ChatSession
    /// Interaction engine (A-M3ab): composer, queued bar, permissions,
    /// config. Long-lived alongside this model; `start()`/`stop()` map to its
    /// `activate()`/`deactivate()`.
    let interactor: ChatInteractor
    /// Voice dictation (A-M3f): provider discovery + record/transcribe state
    /// machine (HapiKit) over the app-side `AVAudioRecorder` seam.
    /// Transcripts append to the composer; failures surface as notices.
    let dictation: DictationController
    #if !targetEnvironment(macCatalyst)
    /// WeChat-style Hold-to-Dictate ("按住转文字") streaming controller on iOS.
    let holdDictation: HoldToDictateController
    #endif
    @ObservationIgnored private let pipeline = ChatPipeline()
    @ObservationIgnored let mediaLoader: GeneratedMediaLoader
    @ObservationIgnored let presentationState = ChatPresentationState()
    @ObservationIgnored let geometryCache = TranscriptGeometryCache()
    @ObservationIgnored let markdownCache = MarkdownRenderCache()
    @ObservationIgnored private let renderPreparation = ChatRenderPreparation()
    @ObservationIgnored private var lastPipelineStart: ContinuousClock.Instant?
    /// Authed thumbnail/viewer loader for scratchlist attachments (A-M4b).
    @ObservationIgnored let scratchlistAttachments: ScratchlistAttachmentLoader

    /// The hub's scratchlist store, for the toolbar-badge sheet (A-M4b).
    var scratchlist: ScratchlistStore { hub.scratchlist }
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    @ObservationIgnored private var windowState: MessageWindowState?
    @ObservationIgnored private var detailLoadFailed = false
    @ObservationIgnored private var inputRevision = 0
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?
    @ObservationIgnored private var statesTask: Task<Void, Never>?
    @ObservationIgnored private var olderTask: Task<Void, Never>?
    @ObservationIgnored private var jumpTask: Task<Void, Never>?
    @ObservationIgnored private var historyRetryTask: Task<Void, Never>?
    @ObservationIgnored private var historyCancellation: Task<Void, Never>?
    @ObservationIgnored private var windowModeTask: Task<Void, Never>?
    @ObservationIgnored private var historyGate: ChatHistoryRequestGate?
    @ObservationIgnored private var viewportNeedsOlder = false
    @ObservationIgnored private var lastHistoryLayout: (version: Int, progress: Bool)?
    @ObservationIgnored private var lastEpoch: Int?
    @ObservationIgnored private var historyPumpScheduled = false
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var wantsTailFollowing = false
    @ObservationIgnored private var registeredTailFollowing = false
    @ObservationIgnored private var everStarted = false
    @ObservationIgnored private var headerObservationToken = 0

    init(session: HubSession, sessionId: String) {
        self.hub = session
        self.sessionId = sessionId
        self.chat = session.makeChatSession(sessionId: sessionId)
        self.interactor = session.makeChatInteractor(sessionId: sessionId)
        self.dictation = DictationController(
            api: session.api,
            recorder: AVAudioRecorderDictation()
        )
        #if !targetEnvironment(macCatalyst)
        self.holdDictation = HoldToDictateController(
            api: session.api,
            streamer: HubStreamingAsrClient(api: session.api),
            recorder: PCMStreamingAudioRecorder()
        )
        #endif
        self.mediaLoader = GeneratedMediaLoader(api: session.api, sessionId: sessionId)
        self.scratchlistAttachments = ScratchlistAttachmentLoader(api: session.api, sessionId: sessionId)
        let initialDetail = session.sessionStore.detail(for: sessionId)
        let initialSessions = session.sessionStore.sessions
        let initialSummary = initialSessions.first { $0.id == sessionId }
        let initialRawParent = (initialDetail?.metadata?.parentSessionId ?? initialSummary?.metadata?.parentSessionId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let initialParentDetail = initialRawParent.flatMap { pid in
            pid.isEmpty || pid == sessionId ? nil : session.sessionStore.detail(for: pid)
        }
        self.header = Self.buildHeader(
            sessionId: sessionId,
            detail: initialDetail,
            summary: initialSummary,
            allSessions: initialSessions,
            parentDetail: initialParentDetail,
            machines: session.machineStore.machines
        )
    }

    // MARK: - Lifecycle (paired with the screen's appear/disappear)

    /// Navigation/sheet handoffs keep a single session pipe alive. Deferring
    /// the final release also absorbs SwiftUI's disappear-before-appear order.
    func retainSurface(_ id: String) {
        visibleSurfaces.insert(id)
        start()
    }

    func releaseSurface(_ id: String) {
        visibleSurfaces.remove(id)
        // Keep the model alive through the deferred teardown. A replaced
        // split detail may otherwise deallocate before this task runs, leaving
        // its SSE client running and the hub's open-chat marker stale.
        Task { [self] in
            await Task.yield()
            guard visibleSurfaces.isEmpty else { return }
            self.stop()
        }
    }

    func beginContentInspection() {
        dictation.cancel()
        #if !targetEnvironment(macCatalyst)
        holdDictation.cancelIfHolding()
        #endif
        jumpTask?.cancel()
        jumpTask = nil
        isJumpingToLatest = false
        // Pause following/paging without claiming the reader left the bottom.
        // The latest action still depends on viewport distance or a trimmed tail.
        readingViewportChanged(followsTail: false, needsOlder: false, isAwayFromBottom: isAwayFromBottom)
    }

    @discardableResult
    func inspectToolGroup(_ id: String, owner: String) -> Bool {
        guard toolInspection.openGroup(id, owner: owner) else { return false }
        beginContentInspection()
        retainSurface("inspector:\(owner)")
        return true
    }

    func start() {
        guard !isActive else { return }
        let preservingHistory = everStarted && (!followsTail || hasTrimmedTail)
        isActive = true
        syncTailFollowing()
        if everStarted {
            // Coming back from a stop (e.g. a full-screen cover fired the
            // screen's disappear): fresh wiring, resumed at the saved cursor.
            chat = hub.makeChatSession(sessionId: sessionId)
        }
        everStarted = true
        interactor.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .sessionSuperseded(let sessionId):
                self.supersededSessionId = sessionId
            case .notice(let message):
                // Scratchlist failures already have an inline banner with a
                // retry action. A second toast obscures the same input area.
                if message != self.interactor.scratchlistError { self.showNotice(message) }
            }
        }
        interactor.onDirectSendsChanged = { [weak self] in
            self?.scheduleRecompute()
        }
        interactor.activate()
        dictation.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .transcribed(let text):
                self.interactor.appendDictatedText(text)
            case .noProvider:
                self.showNotice(String(localized: "No transcription provider configured on hub"))
            case .error(let message):
                self.showNotice(message)
            }
        }
        #if !targetEnvironment(macCatalyst)
        holdDictation.onOutcome = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .sendText(let text):
                self.interactor.clearVoiceInlineEditTracking()
                self.interactor.appendDictatedText(text)
                self.interactor.sendMessage()
            case .beginInlineEdit(let partialText):
                self.interactor.beginVoiceInlineEdit(partialText: partialText)
            case .refineInlineEdit(let finalText):
                self.interactor.applyRefinedVoiceInlineEdit(finalText)
            case .noProvider:
                self.showNotice(String(localized: "No transcription provider configured on hub"))
            case .error(let message):
                self.showNotice(message)
            }
        }
        #endif
        // Badge count + SSE-invalidation refetch while the chat is open
        // (the Android ChatViewModel start/stop pairing).
        hub.scratchlist.open(sessionId)
        let chat = chat
        chat.onSessionRemoved = { [weak self] in
            self?.toolInspection.invalidate()
            self?.blocks = []
            self?.messageRows = []
            self?.blockIndexByID = [:]
            self?.blockToUserTurnIndex = [:]
            self?.blockToRailIndex = [:]
            self?.isInitialLoading = false
            self?.hasMore = false
        }
        chat.onStoreActivity = { [weak self] in
            self?.scheduleRecompute()
        }
        startObservingHeaderStores()
        Task { [weak self] in
            await chat.start(preservingHistory: preservingHistory)
            guard let self, self.isActive, self.chat === chat else { return }
            guard let controller = chat.windowController else { return }
            self.statesTask = Task { [weak self] in
                let states = await controller.states()
                for await state in states {
                    guard let self, !Task.isCancelled else { return }
                    self.windowState = state
                    self.scheduleRecompute()
                }
            }
            await self.loadDetail()
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        stopObservingHeaderStores()
        syncTailFollowing()
        displayedReadRevision = nil
        statesTask?.cancel()
        statesTask = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        cancelHistory()
        jumpTask?.cancel()
        jumpTask = nil
        isJumpingToLatest = false
        highlightTask?.cancel()
        highlightTask = nil
        olderTurnSeekTask?.cancel()
        olderTurnSeekTask = nil
        isSeekingOlderTurn = false
        noticeTask?.cancel()
        noticeTask = nil
        // Discard an in-flight take — the mic must not stay hot off-screen
        // (an upload already in Transcribing runs to completion and still
        // appends). Attachment chips deliberately survive this stop: a
        // full-screen cover (camera, image viewer) bounces through
        // stop/start, and un-sent uploads are cleaned up when the tray
        // deallocates with this model.
        dictation.cancel()
        #if !targetEnvironment(macCatalyst)
        holdDictation.cancelIfHolding()
        #endif
        interactor.deactivate()
        mediaLoader.clearCachedImages()
        hub.scratchlist.release(sessionId)
        chat.stop()
    }

    private func showNotice(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - Actions

    var titleEditorRow: SessionRowUI? {
        if let detail = hub.sessionStore.detail(for: sessionId) {
            return SessionRowUI(summary: SummaryPatching.toSessionSummary(detail), title: header.title, project: "", flavor: detail.metadata?.flavor, unread: false)
        }
        if let summary = hub.sessionStore.sessions.first(where: { $0.id == sessionId }) {
            return SessionRowUI(summary: summary, title: header.title, project: "", flavor: summary.metadata?.flavor, unread: false)
        }
        return nil
    }

    var availableTags: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for summary in hub.sessionStore.sessions {
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

    var sessionTags: [String] {
        if let tags = hub.sessionStore.detail(for: sessionId)?.metadata?.tags {
            return tags
        }
        return hub.sessionStore.sessions.first(where: { $0.id == sessionId })?.metadata?.tags ?? []
    }

    func saveTitle(name: String?, locked: Bool, tags: [String]? = nil) async throws {
        try await hub.sessionStore.updateTitle(sessionId: sessionId, name: name, locked: locked, tags: tags)
    }
    func markUnread() {
        let observed = hub.sessionStore.detail(for: sessionId)?.readState
        Task {
            await hub.lastSeenStore.markUnread(sessionId: sessionId, serverState: observed)
            if let error = hub.lastSeenStore.persistenceError { showNotice(error) }
        }
    }

    func resetDisplayedReadReceipt() { displayedReadRevision = nil }

    /// The conditions under which `markDisplayed` acknowledges new tail output.
    var followsReadableTail: Bool {
        followsTail && !isInspectingContent && !isSyncingTail && !isInitialLoading
            && !loadFailed && warning == nil && !hasTrimmedTail
    }

    /// Hides this session's list dot while output it will acknowledge renders.
    func setTailFollowing(_ value: Bool) {
        wantsTailFollowing = value
        syncTailFollowing()
    }

    private func syncTailFollowing() {
        let value = wantsTailFollowing && isActive
        guard value != registeredTailFollowing else { return }
        registeredTailFollowing = value
        hub.lastSeenStore.setFollowingTail(sessionId, value)
    }

    /// Called by the laid-out transcript, with the revision belonging to its rows.
    func markDisplayed(revision: Int?, serverState: SessionReadState?) {
        guard isActive, followsReadableTail, let revision, revision != displayedReadRevision else { return }
        displayedReadRevision = revision
        Task {
            await hub.lastSeenStore.markSeen(sessionId: sessionId, revision: revision, serverState: serverState)
            if let error = hub.lastSeenStore.persistenceError {
                displayedReadRevision = nil
                showNotice(error)
            }
        }
    }

    func readingViewportChanged(followsTail: Bool, needsOlder: Bool, isAwayFromBottom: Bool) {
        let followsTail = isInspectingContent ? false : followsTail
        let needsOlder = isInspectingContent ? false : needsOlder
        let changedMode = self.followsTail != followsTail
        if !followsTail { holdVisibleExecutionContent() }
        self.followsTail = followsTail
        if followsTail && changedMode && !heldExecutionIDs.isEmpty {
            heldExecutionIDs = []
            rebuildMessageRows()
        }
        if !followsTail { displayedReadRevision = nil }
        self.isAwayFromBottom = !followsTail && isAwayFromBottom
        viewportNeedsOlder = needsOlder
        if changedMode, !isJumpingToLatest, let controller = chat.windowController {
            if followsTail && hasTrimmedTail { jumpToLatest(); return }
            let previous = windowModeTask
            windowModeTask = Task {
                await previous?.value
                await controller.setViewMode(followsTail ? .tail : .history)
            }
        }
        if !needsOlder, olderTask != nil || historyPaging.phase == .retrying {
            cancelHistory()
        }
        scheduleHistoryPump()
    }

    func historyLaidOut(version: Int, madeProgress: Bool) {
        if lastHistoryLayout?.version == version {
            let progress = (lastHistoryLayout?.progress ?? false) || madeProgress
            lastHistoryLayout = (version, progress)
        } else {
            lastHistoryLayout = (version, madeProgress)
        }
        acknowledgeHistoryLayout()
    }

    private func acknowledgeHistoryLayout() {
        guard let layout = lastHistoryLayout else { return }
        if historyPaging.laidOut(historyVersion: layout.version, madeProgress: layout.progress) {
            scheduleHistoryPump()
        }
    }

    func retryHistory() {
        historyPaging.resume()
        viewportNeedsOlder = true
        scheduleHistoryPump()
    }

    private func scheduleHistoryPump() {
        guard !historyPumpScheduled else { return }
        historyPumpScheduled = true
        Task { [weak self] in
            // Layout's viewport report must arrive before we re-evaluate
            // demand; an inserted page may have filled the entire buffer.
            await Task.yield()
            guard let self else { return }
            self.historyPumpScheduled = false
            self.pumpHistory()
        }
    }

    private func pumpHistory() {
        guard isActive, !isInspectingContent, !isJumpingToLatest, viewportNeedsOlder, hasMore,
              !isSyncingTail, !isLoadingOlder, olderTask == nil,
              let controller = chat.windowController,
              let request = historyPaging.begin() else { return }
        let gate = ChatHistoryRequestGate()
        historyGate = gate
        let cancellation = historyCancellation
        let modeChange = windowModeTask
        olderTask = Task { [weak self] in
            await cancellation?.value
            await modeChange?.value
            guard !Task.isCancelled, gate.allowsApply else { return }
            let outcome = await controller.fetchOlder(onBeforeApply: { _ in gate.allowsApply })
            guard let self, self.historyPaging.generation == request else { return }
            self.olderTask = nil
            self.historyGate = nil
            let delay = self.historyPaging.received(outcome, generation: request)
            self.acknowledgeHistoryLayout()
            // A completed tail sync may already have tried to pump while
            // olderTask was occupied. Stale pages never acknowledge layout.
            switch outcome {
            case .stopped(.invalidated), .stopped(.epochReset): self.scheduleHistoryPump()
            default: break
            }
            if let delay {
                self.historyRetryTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard !Task.isCancelled, let self else { return }
                    if self.historyPaging.retryElapsed(generation: request) { self.scheduleHistoryPump() }
                }
            }
        }
    }

    private func cancelHistory() {
        historyGate?.invalidate()
        historyGate = nil
        olderTask?.cancel()
        olderTask = nil
        historyRetryTask?.cancel()
        historyRetryTask = nil
        historyPaging.cancel()
        lastHistoryLayout = nil
        if let controller = chat.windowController {
            let previous = historyCancellation
            historyCancellation = Task {
                await previous?.value
                await controller.cancelOlderLoad()
            }
        }
    }

    func topVisibleRowChanged(_ rowID: String?) {
        guard topVisibleBlockID != rowID else { return }
        topVisibleBlockID = rowID
    }

    func jumpToBlock(id: String) {
        guard blockIndexByID[id] != nil else { return }
        scrollTargetToken += 1
        followsTail = false
        topVisibleBlockID = id
        scrollTarget = TranscriptScrollTarget(token: scrollTargetToken, itemID: id, topPadding: 14)
        highlightedBlockID = id
        rebuildMessageRows()
        holdVisibleExecutionContent()
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self?.highlightedBlockID = nil
                self?.rebuildMessageRows()
            }
        }
    }

    func jumpToPendingRequestOrLatest() {
        for block in blocks.reversed() {
            switch block {
            case .block(.toolCall(let toolCall)) where toolCall.tool.permission?.status == .pending:
                jumpToBlock(id: block.stableId)
                return
            case .toolGroup(let group) where group.tools.contains(where: { $0.tool.permission?.status == .pending }):
                jumpToBlock(id: block.stableId)
                return
            default:
                break
            }
        }
        jumpToLatest()
    }

    func jumpToPreviousUserTurn() {
        let turns = userTurnItems
        guard !turns.isEmpty else {
            if hasMore {
                seekOlderUserTurn(jumpWhenFound: true)
            } else if let prevRail = previousRailTargetID() {
                jumpToBlock(id: prevRail)
            }
            return
        }
        let current = activeUserTurnIndex ?? (turns.count - 1)
        // If we are scrolled down into the assistant output of the current turn
        // (so the current turn's user prompt is above the top of the viewport),
        // jump to the top of the current turn's user prompt first.
        if topVisibleBlockID != turns[current].id,
           let topID = topVisibleBlockID,
           let topBlockIdx = blockIndexByID[topID],
           let turnBlockIdx = blockIndexByID[turns[current].id],
           topBlockIdx > turnBlockIdx {
            jumpToBlock(id: turns[current].id)
            return
        }
        if current > 0 {
            jumpToBlock(id: turns[current - 1].id)
        } else if hasMore {
            seekOlderUserTurn(jumpWhenFound: true)
        } else {
            jumpToBlock(id: turns[0].id)
        }
    }

    func jumpToNextUserTurn() {
        let turns = userTurnItems
        guard !turns.isEmpty else {
            if let nextRail = nextRailTargetID() {
                jumpToBlock(id: nextRail)
            } else {
                jumpToLatest()
            }
            return
        }
        let current = activeUserTurnIndex ?? 0
        if current + 1 < turns.count {
            jumpToBlock(id: turns[current + 1].id)
        } else if let nextRail = nextRailTargetID() {
            jumpToBlock(id: nextRail)
        } else {
            jumpToLatest()
        }
    }

    private func previousRailTargetID() -> String? {
        guard !railNavItems.isEmpty else { return nil }
        let idx = activeRailIndex ?? (railNavItems.count - 1)
        if idx > 0 { return railNavItems[idx - 1].id }
        return railNavItems.first?.id
    }

    private func nextRailTargetID() -> String? {
        guard !railNavItems.isEmpty else { return nil }
        let idx = activeRailIndex ?? 0
        if idx + 1 < railNavItems.count { return railNavItems[idx + 1].id }
        return nil
    }

    /// Pages older message batches from the Hub (up to `maxPages` pages of 200
    /// messages). When `loadAll` is true, continues paging until all session
    /// history is loaded (`!hasMore`); otherwise pages until at least one older
    /// user turn appears and optionally jumps to it.
    func seekOlderUserTurn(
        jumpWhenFound: Bool = true,
        loadAll: Bool = false,
        maxPages: Int = 45,
        minTurns: Int? = nil
    ) {
        guard isActive, !isSeekingOlderTurn, hasMore, let controller = chat.windowController else { return }
        isSeekingOlderTurn = true
        let initialTurnCount = userTurnItems.count
        let targetCount = max(initialTurnCount + 1, minTurns ?? (initialTurnCount + 1))
        let initialFirstTurnID = userTurnItems.first?.id
        olderTurnSeekTask?.cancel()
        olderTurnSeekTask = Task { [weak self] in
            defer { self?.isSeekingOlderTurn = false }
            var pagesLoaded = 0
            var busyRetries = 0
            while pagesLoaded < maxPages {
                guard let self, !Task.isCancelled, self.hasMore else { break }
                let outcome = await controller.fetchOlder()
                guard !Task.isCancelled else { return }
                switch outcome {
                case .applied(_, let more, _):
                    pagesLoaded += 1
                    busyRetries = 0
                    // Wait one brief cycle for pipeline recompute to publish new `userTurnItems`
                    try? await Task.sleep(for: .milliseconds(90))
                    guard !Task.isCancelled else { return }
                    if !loadAll,
                       self.userTurnItems.count >= targetCount,
                       let newestOlderTurn = self.userTurnItems.first,
                       newestOlderTurn.id != initialFirstTurnID {
                        if jumpWhenFound {
                            self.jumpToBlock(id: newestOlderTurn.id)
                        }
                        return
                    }
                    if !more { return }
                case .stopped(.busy):
                    busyRetries += 1
                    if busyRetries > 10 { return }
                    try? await Task.sleep(for: .milliseconds(120))
                case .stopped, .failed:
                    return
                }
            }
            if let self, !Task.isCancelled, jumpWhenFound,
               let first = self.userTurnItems.first ?? self.railNavItems.first.map({
                   ChatTurnNavItem(
                       id: $0.id,
                       turnNumber: $0.turnNumber,
                       userText: $0.title,
                       assistantPreview: $0.subtitle,
                       toolCount: $0.toolCount,
                       createdAt: $0.createdAt
                   )
               }) {
                self.jumpToBlock(id: first.id)
            }
        }
    }

    func jumpToLatest() {
        guard isActive, !isJumpingToLatest, let controller = chat.windowController else { return }
        cancelHistory()
        viewportNeedsOlder = false
        isJumpingToLatest = true
        let chat = chat
        let cancellation = historyCancellation
        let modeChange = windowModeTask
        jumpTask = Task { [weak self] in
            await cancellation?.value
            await modeChange?.value
            guard !Task.isCancelled else { return }
            if await controller.state.requiresLatestReset {
                await controller.syncTail(ensureAfterCurrent: true, allowingHistoryReset: true)
            }
            guard !Task.isCancelled, let self, self.isActive, self.chat === chat else { return }
            self.isJumpingToLatest = false
            self.jumpTask = nil
            // A failed catch-up must not claim that the retained window is
            // the live tail, or trim away the reader's remaining history.
            guard await !controller.state.requiresLatestReset else { return }
            await controller.setViewMode(.tail)
            guard !Task.isCancelled, self.chat === chat else { return }
            self.followsTail = true
            self.isAwayFromBottom = false
            self.jumpToLatestToken += 1
        }
    }

    /// Error state → try again (detail + a tail sync past any in-flight run).
    func retry() {
        let controller = chat.windowController
        Task { [weak self] in
            await self?.loadDetail()
            if let controller {
                await controller.syncTail(ensureAfterCurrent: true)
            }
        }
    }

    private func loadDetail() async {
        do {
            _ = try await hub.sessionStore.loadSessionDetail(sessionId)
            detailLoadFailed = false
        } catch is CancellationError {
            return
        } catch {
            detailLoadFailed = true
        }
        scheduleRecompute()
    }

    // MARK: - Pipeline scheduling

    private func scheduleRecompute() {
        inputRevision += 1
        guard pipelineTask == nil else { return }
        pipelineTask = Task { [weak self] in
            await self?.pipelineLoop()
        }
    }

    /// Serial drain loop; see the type comment for the ordering argument.
    /// All state reads/writes happen on the main actor — only the reduction
    /// itself hops onto the pipeline actor.
    private func pipelineLoop() async {
        while !Task.isCancelled {
            if let lastPipelineStart {
                do { try await ContinuousClock().sleep(until: lastPipelineStart.advanced(by: .milliseconds(100))) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            lastPipelineStart = .now
            let revision = inputRevision
            if let window = windowState {
                let detail = hub.sessionStore.detail(for: sessionId)
                let allSessions = hub.sessionStore.sessions
                let summary = allSessions.first { $0.id == sessionId }
                let rawParentId = (detail?.metadata?.parentSessionId ?? summary?.metadata?.parentSessionId)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let parentDetail = rawParentId.flatMap { pid in
                    pid.isEmpty || pid == sessionId ? nil : hub.sessionStore.detail(for: pid)
                }
                let machines = hub.machineStore.machines
                let visible = await pipeline.run(
                    messages: window.messages,
                    agentState: detail?.agentState,
                    hasMoreMessages: window.hasMore,
                    directSendLocalIds: interactor.directSendLocalIds
                )
                let completionEvidence = await pipeline.executionCompletionEvidence()
                let prepared = await renderPreparation.prepare(visible, previous: blocks, markdownCache: markdownCache)
                guard !Task.isCancelled else { return }
                apply(
                    visible,
                    prepared: prepared,
                    completionEvidence: completionEvidence,
                    window: window,
                    detail: detail,
                    summary: summary,
                    allSessions: allSessions,
                    parentDetail: parentDetail,
                    machines: machines
                )
            }
            // No suspension between this check and parking, so a concurrent
            // scheduleRecompute either lands before it (loop again) or finds
            // pipelineTask nil and starts a fresh loop — never lost.
            if inputRevision == revision {
                pipelineTask = nil
                return
            }
        }
    }

    private func apply(
        _ visible: [VisibleChatBlock],
        prepared: PreparedChatRender,
        completionEvidence: Set<String>,
        window: MessageWindowState,
        detail: Session?,
        summary: SessionSummary?,
        allSessions: [SessionSummary],
        parentDetail: Session?,
        machines: [Machine]
    ) {
        guard !chat.isRemoved else { return }
        let running = detail?.thinking ?? summary?.thinking ?? false
        let processChanged = executionCompletedRounds != completionEvidence || executionIsRunning != running || hasMore != window.hasMore
        executionCompletedRounds = completionEvidence
        executionIsRunning = running
        hasMore = window.hasMore
        if let previousEpoch = lastEpoch, let epoch = window.epoch, previousEpoch != epoch {
            cancelHistory()
            heldExecutionIDs = []
            executionGroups = []
            jumpToLatestToken += 1
            toolInspection.invalidate()
            toolInspection.update(visible)
        }
        if let epoch = window.epoch { lastEpoch = epoch }
        // Session/machine status events can arrive without new messages.
        // Do not invalidate the entire lazy transcript for identical output.
        if let nav = prepared.navigation {
            blocks = visible
            userTurnItems = nav.turns
            allMessageNavItems = nav.messages
            railNavItems = nav.rail
            blockIndexByID = nav.blockIndexByID
            blockToUserTurnIndex = nav.blockToUserTurnIndex
            blockToRailIndex = nav.blockToRailIndex
            presentationState.prune(to: prepared.liveIDs)
            heldExecutionIDs.formIntersection(prepared.liveIDs)
        }
        if prepared.navigation != nil || processChanged { rebuildMessageRows() }

        header = Self.buildHeader(
            sessionId: sessionId,
            detail: detail,
            summary: summary,
            allSessions: allSessions,
            parentDetail: parentDetail,
            machines: machines
        )
        basePath = detail?.metadata?.path ?? summary?.metadata?.path
        hasMore = window.hasMore
        historyPaging.refreshAvailability(hasMore: hasMore)
        isLoadingOlder = window.isLoadingMore
        isSyncingTail = window.isSyncingTail
        warning = window.warning
        tailRevision = window.tailRevision
        historyVersion = window.historyVersion
        hasTrimmedTail = window.requiresLatestReset
        scheduleHistoryPump()

        let isEmpty = visible.isEmpty
        // syncGeneration 0 = no tail sync has even begun (the moment between
        // open and syncTail) — still "loading", never a flash of empty state.
        let syncSettled = !window.isSyncingTail && window.syncGeneration > 0
        isInitialLoading = isEmpty && !syncSettled && window.warning == nil
        loadFailed = isEmpty && syncSettled && (window.warning != nil || detailLoadFailed)

        if syncSettled, !hasAutoBackfilledTurns, !isEmpty {
            hasAutoBackfilledTurns = true
            if hasMore, userTurnItems.count < 4 {
                seekOlderUserTurn(jumpWhenFound: false, loadAll: false, maxPages: 3, minTurns: 4)
            }
        }

        readThroughRevision = window.readThroughRevision
        renderedReadState = SessionReadState.merge(detail?.readState, summary?.readState)
    }

    private func holdVisibleExecutionContent() {
        for row in messageRows {
            if case .message(let block, _) = row.kind { heldExecutionIDs.insert(block.stableId) }
        }
    }

    private func rebuildMessageRows() {
        if !followsTail { holdVisibleExecutionContent() }
        var keepVisible = heldExecutionIDs
        for (key, value) in presentationState.values where key.field == "expanded" && (value as? Bool) == true {
            keepVisible.insert(key.id)
        }
        let displayed = highlightedBlockID == nil
            ? buildExecutionProcessBlocks(blocks, completedRounds: executionCompletedRounds,
                isRunning: executionIsRunning, hasMoreMessages: hasMore,
                keepVisibleIds: keepVisible, previousGroups: executionGroups)
            : blocks
        for group in executionGroups {
            blockIndexByID.removeValue(forKey: group.id)
            blockToUserTurnIndex.removeValue(forKey: group.id)
            blockToRailIndex.removeValue(forKey: group.id)
        }
        var canonicalIndex = blockIndexByID
        for (index, block) in blocks.enumerated() {
            if case .toolGroup(let group) = block {
                for tool in group.tools { canonicalIndex[tool.id] = index }
            }
        }
        let displayedGroups = displayed.compactMap { block -> ToolGroupBlock? in
            if case .toolGroup(let group) = block { return group }; return nil
        }
        if highlightedBlockID == nil { executionGroups = displayedGroups }
        for group in displayedGroups where group.processBlocks != nil {
            guard let first = group.processBlocks?.first, let index = canonicalIndex[first.id] else { continue }
            blockIndexByID[group.id] = index
            let canonicalID = blocks[index].stableId
            blockToUserTurnIndex[group.id] = blockToUserTurnIndex[canonicalID]
            blockToRailIndex[group.id] = blockToRailIndex[canonicalID]
        }
        toolInspection.update(displayed + blocks)
        var nextRows: [TranscriptRow] = []
        nextRows.reserveCapacity(displayed.count)
        let highlightedID = highlightedBlockID
        var activeIDs = Set<String>()
        activeIDs.reserveCapacity(displayed.count)
        for block in displayed {
            if case .toolGroup(let group) = block {
                activeIDs.insert(group.id)
                if let cached = cachedGroupPresentations[group.id], cached.presentation == ToolGroupPresentation(group) {
                    nextRows.append(cached.row)
                } else {
                    let presentation = ToolGroupPresentation(group)
                    let row = TranscriptRow.group(presentation)
                    cachedGroupPresentations[group.id] = (group, presentation, row)
                    nextRows.append(row)
                }
            } else {
                let id = block.stableId
                activeIDs.insert(id)
                let isHighlighted = (id == highlightedID)
                if let cached = cachedMessageRows[id],
                   cached.isHighlighted == isHighlighted,
                   cached.block == block {
                    nextRows.append(cached.row)
                } else {
                    let row = TranscriptRow.message(block, isHighlighted)
                    cachedMessageRows[id] = (block, isHighlighted, row)
                    nextRows.append(row)
                }
            }
        }
        if cachedGroupPresentations.count > activeIDs.count + 32 {
            cachedGroupPresentations = cachedGroupPresentations.filter { activeIDs.contains($0.key) }
        }
        if cachedMessageRows.count > activeIDs.count + 64 {
            cachedMessageRows = cachedMessageRows.filter { activeIDs.contains($0.key) }
        }
        messageRows = nextRows
    }

    // MARK: - Header derivation (Android `buildHeader` port)

    static func buildHeader(
        sessionId: String,
        detail: Session?,
        summary: SessionSummary?,
        allSessions: [SessionSummary] = [],
        parentDetail: Session? = nil,
        machines: [Machine]
    ) -> ChatHeaderUI {
        // Detail first — the fresher source once loaded (this pipe patches
        // it live); a detail without usable metadata falls through to the
        // list summary, then to the id prefix (`getSessionTitle` cascade).
        let title = detail.flatMap(detailTitle)
            ?? summary.map(SessionListModel.sessionTitle)
            ?? String(sessionId.prefix(8))

        let flavor = detail?.metadata?.flavor ?? summary?.metadata?.flavor
        let machineId = detail?.metadata?.machineId ?? summary?.metadata?.machineId
        let machineLabel: String? = machineId.map { id in
            guard let metadata = machines.first(where: { $0.id == id })?.metadata else {
                return String(id.prefix(8))
            }
            if let displayName = metadata.displayName,
               !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
                return displayName
            }
            return metadata.host
        }
        let worktree = (detail?.metadata?.worktree ?? summary?.metadata?.worktree).map { tree in
            tree.name.trimmingCharacters(in: .whitespaces).isEmpty ? tree.branch : tree.name
        }
        let parts: [String] = [
            flavor.map { flavorLabel(forFlavor: $0) },
            machineLabel,
            worktree,
        ].compactMap { $0 }

        let active = detail?.active ?? summary?.active ?? false
        let thinking = detail?.thinking ?? summary?.thinking ?? false
        let status = resolveHeaderStatus(detail: detail, summary: summary)

        let rawParent = (detail?.metadata?.parentSessionId ?? summary?.metadata?.parentSessionId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parentSessionId: String? = {
            guard let rawParent, !rawParent.isEmpty, rawParent != sessionId else { return nil }
            return rawParent
        }()
        let parentSummary = parentSessionId.flatMap { pid in
            allSessions.first(where: { $0.id == pid })
        }
        let isParentNavigable = parentSummary != nil
        let parentTitle: String? = parentSessionId.map { pid in
            if let parentSummary {
                if let parentDetail, parentDetail.id == pid, let resolved = detailTitle(parentDetail) {
                    return resolved
                }
                return SessionListModel.sessionTitle(parentSummary)
            }
            return String(pid.prefix(8))
        }

        return ChatHeaderUI(
            title: title,
            subtitle: parts.isEmpty ? nil : parts.joined(separator: "  "),
            flavor: flavor,
            active: active,
            thinking: thinking,
            status: status,
            parentSessionId: parentSessionId,
            parentTitle: parentTitle,
            isParentNavigable: isParentNavigable
        )
    }

    private func startObservingHeaderStores() {
        headerObservationToken &+= 1
        let token = headerObservationToken
        armHeaderStoreObservation(token: token)
    }

    private func stopObservingHeaderStores() {
        headerObservationToken &+= 1
    }

    private func armHeaderStoreObservation(token: Int) {
        guard isActive, headerObservationToken == token else { return }
        withObservationTracking {
            refreshHeaderFromStores()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.headerObservationToken == token else { return }
                self.armHeaderStoreObservation(token: token)
            }
        }
    }

    func refreshHeaderFromStores() {
        guard !chat.isRemoved else { return }
        let detail = hub.sessionStore.detail(for: sessionId)
        let allSessions = hub.sessionStore.sessions
        let summary = allSessions.first { $0.id == sessionId }
        let rawParent = (detail?.metadata?.parentSessionId ?? summary?.metadata?.parentSessionId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parentDetail = rawParent.flatMap { pid in
            pid.isEmpty || pid == sessionId ? nil : hub.sessionStore.detail(for: pid)
        }
        let nextHeader = Self.buildHeader(
            sessionId: sessionId,
            detail: detail,
            summary: summary,
            allSessions: allSessions,
            parentDetail: parentDetail,
            machines: hub.machineStore.machines
        )
        if header != nextHeader {
            header = nextHeader
        }
        let nextBasePath = detail?.metadata?.path ?? summary?.metadata?.path
        if basePath != nextBasePath {
            basePath = nextBasePath
        }
    }

    private static let inputRequestTools: Set<String> = [
        "AskUserQuestion",
        "ask_user_question",
        "ask_question",
        "Run ask_question",
        "ExitPlanMode",
        "exit_plan_mode",
        "request_user_input",
    ]

    private static func resolveHeaderStatus(detail: Session?, summary: SessionSummary?) -> ChatHeaderStatus {
        if let detail {
            if let requests = detail.agentState?.requests, !requests.isEmpty {
                var hasInput = false
                var hasPermission = false
                for req in requests.values {
                    if inputRequestTools.contains(req.tool) {
                        hasInput = true
                    } else {
                        hasPermission = true
                    }
                }
                let count = requests.count
                if hasInput && !hasPermission {
                    return .needsReply(count)
                } else if hasPermission && !hasInput {
                    return .needsApproval(count)
                } else {
                    return .needsAttention(count)
                }
            }
            if detail.active && detail.thinking {
                return .running
            }
            let bgCount = detail.backgroundTaskCount ?? summary?.backgroundTaskCount ?? 0
            if detail.active && bgCount > 0 {
                return .background(bgCount)
            }
            if detail.active {
                return .online
            }
            if (detail.metadata?.lifecycleState ?? summary?.metadata?.lifecycleState) == "archived" {
                return .archived
            }
            return .offline
        }

        if let summary {
            if let rowStatus = SessionRowStatus(summary: summary) {
                switch rowStatus {
                case .needsReply(let n): return .needsReply(n)
                case .needsApproval(let n): return .needsApproval(n)
                case .needsAttention(let n): return .needsAttention(n)
                case .running: return .running
                case .background(let n): return .background(n)
                }
            }
            if summary.active {
                return .online
            }
            if summary.metadata?.lifecycleState == "archived" {
                return .archived
            }
        }
        return .offline
    }

    /// Detail-side title cascade; nil when the metadata carries nothing usable.
    private static func detailTitle(_ detail: Session) -> String? {
        guard let metadata = detail.metadata else { return nil }
        if let name = metadata.name, !name.isEmpty {
            return name
        }
        if let text = metadata.summary?.text, !text.isEmpty {
            return text
        }
        if let tail = metadata.path.split(separator: "/").last(where: { !$0.isEmpty }) {
            return String(tail)
        }
        return nil
    }
}

/// The export as a Files document (`fileExporter`); never read back.
struct SessionExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, UTType(filenameExtension: "md") ?? .plainText] }
    var contentType: UTType { file.filename.hasSuffix(".md") ? (UTType(filenameExtension: "md") ?? .plainText) : .json }

    let file: SessionExportFile

    init(file: SessionExportFile) {
        self.file = file
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: file.data)
    }
}

struct ChatNavigationProjection: Sendable {
    let turns: [ChatTurnNavItem]
    let messages: [ChatMessageNavItem]
    let rail: [ChatRailNavItem]
    let blockIndexByID: [String: Int]
    let blockToUserTurnIndex: [String: Int]
    let blockToRailIndex: [String: Int]
}

struct PreparedChatRender: Sendable {
    let navigation: ChatNavigationProjection?
    let changedIndices: [Int]?
    let liveIDs: Set<String>
    let toolsChanged: Bool
}

/// Whole-window comparison, navigation and Markdown preparation run off-main.
/// Compare against the last *published* blocks, never a cancelled preparation.
actor ChatRenderPreparation {
    private var snippetCache: [String: (source: String, snippet: String)] = [:]

    func prepare(_ visible: [VisibleChatBlock], previous: [VisibleChatBlock],
                 markdownCache: MarkdownRenderCache) async -> PreparedChatRender {
        var changes: [Int] = []
        var sameStructure = visible.count == previous.count
        for (index, block) in visible.enumerated() {
            if index >= previous.count || block != previous[index] { changes.append(index) }
            if index < previous.count, block.stableId != previous[index].stableId { sameStructure = false }
        }
        guard !sameStructure || !changes.isEmpty else {
            return PreparedChatRender(navigation: nil, changedIndices: [], liveIDs: [], toolsChanged: false)
        }
        var sources: [String] = []
        for index in changes {
            guard case .block(let block) = visible[index] else { continue }
            switch block {
            case .agentText(let value): sources.append(value.text)
            case .agentReasoning(let value): sources.append(value.text)
            case .toolCall(let value):
                if let source = planProposalMarkdown(value.tool) { sources.append(source) }
            default: break
            }
        }
        if !sources.isEmpty { await markdownCache.prepare(sources) }
        let nav = buildNavigationItems(from: visible)
        var liveIDs = Set<String>()
        func collect(_ block: ChatBlock) {
            liveIDs.insert(block.id)
            if case .toolCall(let tool) = block {
                if let request = tool.tool.permission?.id { liveIDs.insert(request) }
                tool.children.forEach(collect)
            }
        }
        for block in visible {
            switch block {
            case .block(let value): collect(value)
            case .toolGroup(let group):
                liveIDs.insert(group.id)
                group.tools.forEach { collect(.toolCall($0)) }
            }
        }
        snippetCache = snippetCache.filter { liveIDs.contains($0.key) }
        func isTool(_ block: VisibleChatBlock) -> Bool {
            switch block {
            case .toolGroup, .block(.toolCall): return true
            default: return false
            }
        }
        let toolsChanged = !sameStructure || changes.contains { isTool(visible[$0]) || isTool(previous[$0]) }
        return PreparedChatRender(navigation: nav, changedIndices: sameStructure ? changes : nil,
                                  liveIDs: liveIDs, toolsChanged: toolsChanged)
    }
    // MARK: - Turn & Message Navigation Builder

    private func cachedSnippet(id: String, raw: String) -> String {
        if let cached = snippetCache[id], cached.source == raw {
            return cached.snippet
        }
        let snippet = Self.cleanSnippet(raw)
        snippetCache[id] = (raw, snippet)
        return snippet
    }

    private func buildNavigationItems(
        from visible: [VisibleChatBlock]
    ) -> ChatNavigationProjection {
        var turns: [ChatTurnNavItem] = []
        var messages: [ChatMessageNavItem] = []
        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(visible.count)
        var turnIndexByBlock: [String: Int] = [:]
        turnIndexByBlock.reserveCapacity(visible.count)

        var currentUser: UserTextBlock?
        var currentTurnNumber = 0
        var currentAssistantPreview: String?
        var currentToolCount = 0

        func flushCurrentTurn() {
            guard let user = currentUser else { return }
            turns.append(ChatTurnNavItem(
                id: user.id,
                turnNumber: currentTurnNumber,
                userText: cachedSnippet(id: user.id, raw: user.text),
                assistantPreview: currentAssistantPreview,
                toolCount: currentToolCount,
                createdAt: user.createdAt
            ))
        }

        for (blockIdx, item) in visible.enumerated() {
            let blockID = item.stableId
            indexByID[blockID] = blockIdx
            switch item {
            case .block(.userText(let user)):
                flushCurrentTurn()
                currentTurnNumber += 1
                currentUser = user
                currentAssistantPreview = nil
                currentToolCount = 0
                messages.append(ChatMessageNavItem(
                    id: user.id,
                    role: .user,
                    turnNumber: currentTurnNumber,
                    text: cachedSnippet(id: user.id, raw: user.text),
                    createdAt: user.createdAt
                ))
            case .block(.agentText(let agent)):
                let snippet = cachedSnippet(id: agent.id, raw: agent.text)
                if !snippet.isEmpty {
                    currentAssistantPreview = snippet
                    messages.append(ChatMessageNavItem(
                        id: agent.id,
                        role: .assistant,
                        turnNumber: max(1, currentTurnNumber),
                        text: snippet,
                        createdAt: agent.createdAt
                    ))
                }
            case .block(.toolCall):
                currentToolCount += 1
            case .toolGroup(let group):
                currentToolCount += group.tools.count
            default:
                break
            }
            turnIndexByBlock[blockID] = max(0, currentTurnNumber - 1)
        }
        flushCurrentTurn()

        let rail: [ChatRailNavItem]
        if !turns.isEmpty {
            rail = turns.map { turn in
                ChatRailNavItem(
                    id: turn.id,
                    isUserTurn: true,
                    turnNumber: turn.turnNumber,
                    title: turn.userText,
                    subtitle: turn.assistantPreview,
                    toolCount: turn.toolCount,
                    createdAt: turn.createdAt
                )
            }
        } else if !messages.isEmpty {
            rail = messages.map { msg in
                ChatRailNavItem(
                    id: msg.id,
                    isUserTurn: msg.role == .user,
                    turnNumber: msg.turnNumber,
                    title: msg.text,
                    subtitle: nil,
                    toolCount: 0,
                    createdAt: msg.createdAt
                )
            }
        } else {
            rail = []
        }

        var railIndexByBlock: [String: Int] = [:]
        if !turns.isEmpty {
            railIndexByBlock = turnIndexByBlock
        } else if !rail.isEmpty {
            railIndexByBlock.reserveCapacity(visible.count)
            let railPosByID = Dictionary(uniqueKeysWithValues: rail.enumerated().map { ($0.element.id, $0.offset) })
            var activeRailPos = 0
            for item in visible {
                let blockID = item.stableId
                if let pos = railPosByID[blockID] {
                    activeRailPos = pos
                }
                railIndexByBlock[blockID] = activeRailPos
            }
        }

        return ChatNavigationProjection(turns: turns, messages: messages, rail: rail, blockIndexByID: indexByID, blockToUserTurnIndex: turnIndexByBlock, blockToRailIndex: railIndexByBlock)
    }

    private static func cleanSnippet(_ raw: String) -> String {
        var result = String()
        result.reserveCapacity(min(raw.utf8.count, 184))
        var count = 0
        var pendingSpace = false
        for ch in raw {
            if ch.isWhitespace || ch.isNewline {
                if count > 0 {
                    pendingSpace = true
                }
            } else {
                if pendingSpace {
                    if count >= 180 {
                        result.append("…")
                        return result
                    }
                    result.append(" ")
                    count += 1
                    pendingSpace = false
                }
                if count >= 180 {
                    result.append("…")
                    return result
                }
                result.append(ch)
                count += 1
            }
        }
        return result
    }

}
