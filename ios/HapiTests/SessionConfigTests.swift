import HapiClient
import HapiProtocol
import SwiftUI
import UIKit
import XCTest
@testable import Hapi

@MainActor
final class SessionConfigTests: XCTestCase {
    func testCollaborationMenuUsesLiveStateWithoutDependingOnTheModelCatalog() async throws {
        let harness = try await SessionConfigTestHarness(flavor: "codex")
        let model = harness.model
        XCTAssertTrue(model.showsCollaborationMode)
        XCTAssertEqual(model.collaborationMode, .default)
        await harness.http.setModelsFailure(true)
        model.loadModels()
        try await configEventually { model.modelLoadFailed }
        XCTAssertTrue(model.config.canChangeCollaborationMode)
        model.selectCollaborationMode(.plan)
        XCTAssertEqual(model.collaborationMode, .plan)
        XCTAssertEqual(model.permission, .default)
        try await configEventually { !model.isApplying }
        let posts = await harness.http.posts
        XCTAssertEqual(posts.first?.path, "/api/sessions/config/collaboration-mode")
        XCTAssertEqual(posts.first?.body, #"{"mode":"plan"}"#)
        harness.store.applySessionEvent(.sessionUpdated(namespace: nil, sessionId: "config", data: .patch(SessionPatch(collaborationMode: .default))))
        XCTAssertEqual(model.collaborationMode, .default)
        harness.store.updateDetailLocal("config") { $0.active = false }
        XCTAssertTrue(model.showsCollaborationMode)
        model.selectCollaborationMode(.plan)
        let finalPosts = await harness.http.posts
        XCTAssertEqual(finalPosts.count, 1)
        let claude = try await SessionConfigTestHarness()
        XCTAssertFalse(claude.model.showsCollaborationMode)
    }

    func testClaudeDefaultsAndUnknownValuesKeepTheirCatalogSemantics() async throws {
        let harness = try await SessionConfigTestHarness()
        let model = harness.model
        for value in [nil, "auto", "default", "  "] as [String?] {
            harness.store.updateDetailLocal("config") {
                $0.model = value
                $0.effort = value
            }
            XCTAssertNil(model.currentModel)
            XCTAssertEqual(model.modelLabel, "Default")
            XCTAssertNil(model.currentEffort)
            XCTAssertEqual(model.effortOptions.first?.label, "Auto")
        }
        harness.store.updateDetailLocal("config") {
            $0.model = " custom-model "
            $0.effort = " TURBO "
        }
        XCTAssertEqual(model.currentModel, "custom-model")
        XCTAssertEqual(model.modelLabel, "custom-model")
        XCTAssertNil(model.unlistedModelOption, "Claude's catalog includes its synthetic current row")
        XCTAssertEqual(model.currentEffort, "turbo")
        XCTAssertTrue(model.canSelectEffort("turbo"))
        XCTAssertEqual(model.effortOptions[1].label, "Turbo")
    }

    func testCodexDefaultIsNotTheFirstItemAndUnknownModelsAreNotCoerced() async throws {
        let harness = try await SessionConfigTestHarness(flavor: "codex")
        harness.model.loadModels()
        try await configEventually { !harness.model.config.modelOptionsLoading }
        XCTAssertEqual(harness.model.currentModel, "deep")
        XCTAssertEqual(harness.model.modelLabel, "Deep · default")
        harness.model.selectModel("deep")
        let initialPosts = await harness.http.posts
        XCTAssertTrue(initialPosts.isEmpty, "Selecting the effective default must not send a redundant POST")
        harness.store.updateDetailLocal("config") { $0.model = "custom-codex" }
        XCTAssertEqual(harness.model.modelLabel, "custom-codex")
        XCTAssertEqual(harness.model.unlistedModelOption, CatalogOption(value: "custom-codex", label: "custom-codex"))
        harness.model.selectModel("custom-codex")
        let posts = await harness.http.posts
        XCTAssertTrue(posts.isEmpty, "An unlisted model is displayed, not offered as a new edit")
    }

    func testCodexCatalogWithoutDefaultKeepsAnUnselectedReadOnlyMenuTag() async throws {
        let harness = try await SessionConfigTestHarness(flavor: "codex")
        await harness.http.setModels([
            CodexModelSummary(id: "fast", displayName: "Fast", isDefault: false),
        ])
        harness.model.loadModels()
        try await configEventually { !harness.model.config.modelOptionsLoading }
        XCTAssertNil(harness.model.currentModel)
        XCTAssertEqual(harness.model.unlistedModelOption, CatalogOption(value: nil, label: "Default"))
        harness.model.selectModel(nil)
        let posts = await harness.http.posts
        XCTAssertTrue(posts.isEmpty, "A synthetic nil tag is display-only, not an unsupported edit")
    }

    func testPendingCodexChangeAlsoGuardsCollaborationAndCatalogReloads() async throws {
        let harness = try await SessionConfigTestHarness(flavor: "codex")
        harness.model.loadModels()
        try await configEventually { !harness.model.config.modelOptionsLoading }
        await harness.http.holdPosts()
        defer { Task { await harness.http.releasePosts() } }
        harness.model.selectModel("fast")
        harness.model.selectCollaborationMode(.plan)
        harness.model.selectPermission(.yolo)
        harness.model.selectEffort("high")
        harness.model.loadModels()
        try await configEventually { await harness.http.posts.count == 1 }
        XCTAssertEqual(harness.model.collaborationMode, .default)
        XCTAssertEqual(harness.model.permission, .default)
        let requests = await harness.http.modelRequests
        XCTAssertEqual(requests, 1)
    }

    func testSelectionSkipsUnchangedValuesAndGuardsAllEditsWhileApplying() async throws {
        let harness = try await SessionConfigTestHarness(model: "sonnet")
        let model = harness.model
        model.selectPermission(.default)
        model.selectModel("sonnet")
        model.selectEffort(nil)
        let initialPosts = await harness.http.posts
        XCTAssertTrue(initialPosts.isEmpty)

        await harness.http.holdPosts()
        defer { Task { await harness.http.releasePosts() } }
        model.selectModel("opus")
        XCTAssertEqual(model.modelLabel, "Opus")
        XCTAssertTrue(model.isApplying)
        model.selectModel("sonnet")
        model.selectPermission(.plan)
        model.selectEffort("high")
        try await configEventually { await harness.http.posts.count == 1 }
        let posts = await harness.http.posts
        XCTAssertEqual(posts.first?.path, "/api/sessions/config/model")
        XCTAssertEqual(posts.first?.body, #"{"model":"opus"}"#)

        await harness.http.releasePosts()
        try await configEventually { !model.isApplying }
        model.selectEffort("high")
        try await configEventually { !model.isApplying }
        let finalPosts = await harness.http.posts
        XCTAssertEqual(finalPosts.count, 2)
        XCTAssertEqual(finalPosts.last?.path, "/api/sessions/config/effort")
    }

    func testModelSwitchUpdatesEffortMenuWithoutSilentlyChangingStaleEffort() async throws {
        let harness = try await SessionConfigTestHarness(flavor: "codex", model: "deep")
        harness.store.updateDetailLocal("config") { $0.modelReasoningEffort = "xhigh" }
        let model = harness.model
        model.loadModels()
        try await configEventually { !model.config.modelOptionsLoading }
        XCTAssertTrue(model.canSelectEffort("xhigh"))
        model.selectModel("fast")
        XCTAssertEqual(model.currentEffort, "xhigh")
        XCTAssertEqual(model.effortOptions.first?.value, "xhigh")
        XCTAssertFalse(model.canSelectEffort("xhigh"), "Keep the stale tag read-only, not a supported option")
        XCTAssertTrue(model.canSelectEffort("low"))
        try await configEventually { !model.isApplying }
        model.selectEffort("xhigh")
        model.selectEffort("low")
        try await configEventually { !model.isApplying }
        let posts = await harness.http.posts
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.last?.path, "/api/sessions/config/model-reasoning-effort")
        XCTAssertEqual(posts.last?.body, #"{"modelReasoningEffort":"low"}"#)
        XCTAssertEqual(model.currentEffort, "low")
    }

    func testFailureReloadsServerTruthAndPreservesTheOwnersNoticeCallback() async throws {
        let harness = try await SessionConfigTestHarness()
        await harness.http.rejectChanges()
        var notices: [String] = []
        harness.interactor.onEvent = {
            if case .notice(let message) = $0 { notices.append(message) }
        }
        harness.model.selectPermission(.plan)
        XCTAssertEqual(harness.model.permission, .plan)
        try await configEventually { !harness.model.isApplying }
        XCTAssertEqual(harness.model.permission, .default)
        XCTAssertEqual(notices, ["HTTP 409 (Config rejected)"])
    }

    func testModelFailureRetriesAndLoadedEmptyCatalogIsUnavailableNotFailed() async throws {
        let harness = try await SessionConfigTestHarness(flavor: "codex")
        await harness.http.setModelsFailure(true)
        harness.model.loadModels()
        XCTAssertTrue(harness.model.config.modelOptionsLoading)
        XCTAssertFalse(harness.model.showsEffort)
        try await configEventually { harness.model.modelLoadFailed }
        await harness.http.setModelsFailure(false)
        harness.model.loadModels()
        try await configEventually { !harness.model.config.modelOptionsLoading }
        XCTAssertFalse(harness.model.modelLoadFailed)
        XCTAssertTrue(harness.model.showsEffort)
        let count = await harness.http.modelRequests
        XCTAssertEqual(count, 2)

        let empty = try await SessionConfigTestHarness(flavor: "codex")
        await empty.http.setModels([])
        empty.model.loadModels()
        try await configEventually { !empty.model.config.modelOptionsLoading }
        XCTAssertEqual(empty.model.config.modelOptions, [])
        XCTAssertFalse(empty.model.modelLoadFailed)
        XCTAssertTrue(empty.model.showsModel)
        XCTAssertFalse(empty.model.showsEffort)
    }

    func testCapabilitiesAndUnsupportedAgentsRemainCatalogDriven() async throws {
        for flavor in ["pi", "dsh"] {
            let harness = try await SessionConfigTestHarness(flavor: flavor)
            XCTAssertFalse(harness.model.hasSettings)
            harness.model.selectPermission(.yolo)
            harness.model.selectModel("opus")
            harness.model.selectEffort("high")
            let posts = await harness.http.posts
            XCTAssertTrue(posts.isEmpty)
        }
        let harness = try await SessionConfigTestHarness(flavor: "codex")
        harness.store.updateDetailLocal("config") {
            $0.active = false
            $0.agentState = AgentState(controlledByUser: true)
            $0.metadata?.capabilities = SessionCapabilities(concurrentClients: true)
        }
        XCTAssertFalse(harness.model.config.active)
        XCTAssertFalse(harness.model.config.controlledByUser)
        XCTAssertFalse(harness.model.config.permissionModes.contains { $0.mode == .safeYolo })
        harness.model.selectPermission(.safeYolo)
        let posts = await harness.http.posts
        XCTAssertTrue(posts.isEmpty)
        // Offline/terminal notices do not introduce a blanket UI authorization gate.
        harness.store.updateDetailLocal("config") { $0.metadata?.capabilities = nil }
        XCTAssertTrue(harness.model.config.controlledByUser)
    }

    func testSubscriptionQuotaLoadsForCodexAndAgy() async throws {
        let harness = try await SessionConfigTestHarness(flavor: "agy")
        let quotaModel = SessionConfigModel(interactor: harness.interactor, api: harness.api, machineId: "machine-1")
        XCTAssertTrue(quotaModel.showsQuota)
        XCTAssertEqual(quotaModel.quotaAgent, .agy)
        quotaModel.loadQuota()
        try await configEventually {
            if case .loaded = quotaModel.quotaState { return true }
            return false
        }
        guard case .loaded(let result) = quotaModel.quotaState else {
            return XCTFail("Expected loaded quota result")
        }
        XCTAssertEqual(result.agent, .agy)
        XCTAssertEqual(result.groups?.count, 2)
        XCTAssertEqual(result.fiveHour?.usedPercentInt, 20)
        XCTAssertEqual(result.fiveHour?.remainingPercentInt, 80)
        XCTAssertEqual(quotaModel.quotaPeakUsedPercent, 20)
        XCTAssertTrue(quotaModel.showsComposerModelMenu)
        XCTAssertTrue(quotaModel.showsComposerPermissionMenu)

        let claude = try await SessionConfigTestHarness(flavor: "claude", model: "sonnet")
        XCTAssertTrue(claude.model.showsComposerModelMenu)
        XCTAssertTrue(claude.model.showsComposerPermissionMenu)
        XCTAssertFalse(claude.model.showsQuota)
        XCTAssertEqual(claude.model.modelSummaryValue, "Sonnet · Auto")
        XCTAssertEqual(claude.model.permissionSummaryValue, "Default")

        let gemini = try await SessionConfigTestHarness(flavor: "gemini")
        XCTAssertFalse(gemini.model.showsComposerModelMenu)
        XCTAssertFalse(gemini.model.showsQuota)

        let dsh = try await SessionConfigTestHarness(flavor: "dsh")
        XCTAssertTrue(dsh.model.showsComposerModelMenu)
        XCTAssertFalse(dsh.model.showsComposerPermissionMenu)
        XCTAssertFalse(dsh.model.showsQuota)
    }

    #if !targetEnvironment(macCatalyst)
    func testIOSComposerCollapsesSessionControlsAndRetainsMicWhenDraftHasText() async throws {
        let harness = try await SessionConfigTestHarness(flavor: "codex")
        let dictation = DictationController(api: harness.api, recorder: AVAudioRecorderDictation())
        let holdDictation = HoldToDictateController(
            api: harness.api,
            streamer: HubStreamingAsrClient(api: harness.api),
            recorder: PCMStreamingAudioRecorder()
        )
        let rootView = VStack {
            Spacer()
            ChatComposerView(
                interactor: harness.interactor,
                dictation: dictation,
                holdDictation: holdDictation,
                api: harness.api,
                machineId: "studio"
            )
            .padding(.horizontal, 12)
        }
        .frame(width: 393, height: 320)
        .background(Color(uiColor: .systemBackground))

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 320)
        let host = UIHostingController(rootView: rootView)
        host.traitOverrides.horizontalSizeClass = .compact
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        func collectViews(in root: UIView) -> [UIView] {
            var all: [UIView] = [root]
            for sub in root.subviews {
                all.append(contentsOf: collectViews(in: sub))
            }
            return all
        }

        func isEffectivelyVisible(_ view: UIView) -> Bool {
            guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return false }
            var current: UIView? = view
            var alphaProduct: CGFloat = 1.0
            while let v = current {
                if v.isHidden { return false }
                alphaProduct *= v.alpha * CGFloat(v.layer.opacity)
                if alphaProduct <= 0.01 { return false }
                current = v.superview
            }
            return true
        }

        func visibleMenuButtons(in root: UIView) -> [UIButton] {
            collectViews(in: root)
                .compactMap { $0 as? UIButton }
                .filter { $0.showsMenuAsPrimaryAction && isEffectivelyVisible($0) }
        }

        func waitUntil(timeoutMs: Int = 2500, condition: () -> Bool) async throws {
            let steps = max(1, timeoutMs / 80)
            for _ in 0..<steps {
                host.view.layoutIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(80))
            }
            host.view.layoutIfNeeded()
        }

        func maybeCapture(_ name: String) throws {
            guard let dirPath = ProcessInfo.processInfo.environment["HAPI_COMPOSER_CAPTURE"] else { return }
            let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let img = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(img.pngData()).write(to: dir.appendingPathComponent("\(name).png"))
        }

        try await waitUntil {
            let ids = Set(collectViews(in: host.view).filter(isEffectivelyVisible).compactMap(\.accessibilityIdentifier))
            return ids.contains("chat.composer-voice") && visibleMenuButtons(in: host.view).count == 0
        }
        try maybeCapture("1-collapsed")

        // 1. Collapsed empty capsule: shows primary voice TouchView (`chat.composer-voice`),
        //    0 UIMenu buttons (+ uses instant custom popup card), and NO `chat.composer-mic`
        let collapsedViews = collectViews(in: host.view).filter(isEffectivelyVisible)
        let collapsedIDs = Set(collapsedViews.compactMap(\.accessibilityIdentifier))
        let collapsedMenuButtons = visibleMenuButtons(in: host.view)
        XCTAssertTrue(collapsedIDs.contains("chat.composer-voice"), "Collapsed empty composer must show primary voice button")
        XCTAssertFalse(collapsedIDs.contains("chat.composer-mic"), "Collapsed composer must not duplicate mic button")
        XCTAssertEqual(collapsedMenuButtons.count, 0, "Collapsed composer must not use a slow UIMenu on the + attachment button")

        // 2. Focused empty state: shows `+` instant attachment button, `sparkles` skills icon,
        //    `clock` schedule-send menu + unified `gauge.with.needle` controls menu (2 menu buttons),
        //    and `chat.composer-voice` primary button
        harness.interactor.focusComposer()
        try await waitUntil {
            visibleMenuButtons(in: host.view).count == 2
        }
        try maybeCapture("2-expanded-empty")

        let expandedEmptyViews = collectViews(in: host.view).filter(isEffectivelyVisible)
        let expandedEmptyIDs = Set(expandedEmptyViews.compactMap(\.accessibilityIdentifier))
        let expandedEmptyMenus = visibleMenuButtons(in: host.view)
        XCTAssertTrue(expandedEmptyIDs.contains("chat.composer-voice"), "Expanded empty composer must show primary voice button")
        XCTAssertEqual(
            expandedEmptyMenus.count,
            2,
            "Expanded composer must show schedule send and unified controls menus (got \(expandedEmptyMenus.count))"
        )

        // 3. Draft has text: retains `chat.composer-mic` right next to `↑ Send`,
        //    plus the 2 menus (`clock` and `gauge.with.needle`)!
        harness.interactor.setComposerText("检查家庭网关")
        try await waitUntil {
            let ids = Set(collectViews(in: host.view).filter(isEffectivelyVisible).compactMap(\.accessibilityIdentifier))
            return ids.contains("chat.composer-mic") && !ids.contains("chat.composer-voice") && visibleMenuButtons(in: host.view).count == 2
        }
        try maybeCapture("3-expanded-draft")

        let expandedDraftViews = collectViews(in: host.view).filter(isEffectivelyVisible)
        let expandedDraftIDs = Set(expandedDraftViews.compactMap(\.accessibilityIdentifier))
        let expandedDraftMenus = visibleMenuButtons(in: host.view)
        XCTAssertTrue(expandedDraftIDs.contains("chat.composer-mic"), "Expanded composer with text must retain voice mic button")
        XCTAssertFalse(expandedDraftIDs.contains("chat.composer-voice"), "Primary voice circle must morph into Send circle when draft has text")
        XCTAssertEqual(expandedDraftMenus.count, 2, "Expanded composer with text must keep schedule send and unified speedometer controls menu")

        if ProcessInfo.processInfo.environment["HAPI_COMPOSER_CAPTURE"] != nil {
            let popupHost = UIHostingController(rootView: ComposerAttachmentPopupCard(
                colorScheme: .light,
                onCamera: {},
                onPhotos: {},
                onFiles: {}
            ))
            popupHost.safeAreaRegions = []
            popupHost.view.backgroundColor = .clear
            let size = popupHost.sizeThatFits(in: CGSize(width: 232, height: 400))
            popupHost.view.frame = CGRect(x: 12, y: window.bounds.height - 8 - ceil(size.height), width: 232, height: ceil(size.height))
            window.addSubview(popupHost.view)
            window.layoutIfNeeded()
            try maybeCapture("4-attachment-popup")
            popupHost.view.removeFromSuperview()
        }
    }
    #endif
}

/// Real app model, interactor, store and API over fake HTTP. No hub connection,
/// Keychain, window activation, saved drafts, or shared conformance fixtures.
@MainActor
final class SessionConfigTestHarness {
    let http: SessionConfigTestHTTP
    let api: APIClient
    let store: SessionListStore
    let interactor: ChatInteractor
    let model: SessionConfigModel

    init(flavor: String = "claude", model: String? = nil) async throws {
        let detail = Session(
            id: "config", namespace: "test", seq: 1, createdAt: 1, updatedAt: 1,
            active: true, activeAt: 1,
            metadata: SessionMetadata(path: "/repo/app", host: "test", flavor: flavor),
            metadataVersion: 1, agentState: nil, agentStateVersion: 1,
            thinking: false, thinkingAt: 0, model: model, permissionMode: .default
        )
        let http = SessionConfigTestHTTP(detail: detail)
        self.http = http
        let baseURL = URL(string: "http://127.0.0.1:1")!
        let credentials = InMemoryCredentialStore()
        let payload = Data(#"{"uid":1,"exp":4102444800,"ns":"test"}"#.utf8).base64EncodedString()
        try credentials.store(HubCredentials(
            hubUrl: baseURL.absoluteString, accessToken: "test", jwt: "e30.\(payload).test"
        ))
        let auth = AuthManager(baseURL: baseURL, credentialStore: credentials, performer: http)
        let api = APIClient(baseURL: baseURL, authManager: auth, performer: http)
        self.api = api
        store = SessionListStore(api: api)
        try await store.loadSessionDetail("config")
        interactor = ChatInteractor(
            sessionId: "config", api: api, sessionStore: store,
            windows: MessageWindowControllers(provider: api)
        )
        self.model = SessionConfigModel(interactor: interactor)
    }
}

actor SessionConfigTestHTTP: HTTPPerforming {
    struct Post: Sendable {
        let path: String
        let body: String?
    }

    private let detail: Session
    private var models = [
        CodexModelSummary(id: "fast", displayName: "Fast", isDefault: false, supportedReasoningEfforts: ["low", "high"]),
        CodexModelSummary(id: "deep", displayName: "Deep", isDefault: true, supportedReasoningEfforts: ["high", "xhigh"]),
    ]
    private var modelsFailure = false
    private var changesRejected = false
    private var postsHeld = false
    private var postWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var posts: [Post] = []
    private(set) var modelRequests = 0

    init(detail: Session) { self.detail = detail }
    func setModelsFailure(_ value: Bool) { modelsFailure = value }
    func setModels(_ values: [CodexModelSummary]) { models = values }
    func rejectChanges() { changesRejected = true }
    func holdPosts() { postsHeld = true }
    func releasePosts() {
        postsHeld = false
        let waiters = postWaiters
        postWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let path = url.path
        let data: Data
        var status = 200
        if path.hasSuffix("/usage-query/query") {
            let result = UsageQueryResult(
                agent: .agy,
                templateId: "agy-subscription",
                status: "success",
                fiveHour: UsageQueryWindow(usedPercent: 20, resetsAt: 1_760_000_000_000),
                sevenDay: UsageQueryWindow(usedPercent: 1, resetsAt: 1_760_500_000_000),
                groups: [
                    UsageQueryGroup(
                        id: "gemini",
                        name: "Gemini Models",
                        fiveHour: UsageQueryWindow(usedPercent: 1, resetsAt: 1_760_000_000_000)
                    ),
                    UsageQueryGroup(
                        id: "claude_gpt",
                        name: "Claude and GPT models",
                        fiveHour: UsageQueryWindow(usedPercent: 20, resetsAt: 1_760_000_000_000),
                        sevenDay: UsageQueryWindow(usedPercent: 1, resetsAt: 1_760_500_000_000)
                    )
                ],
                queriedAt: 1_760_000_000_000,
                stale: false
            )
            data = try HapiJSON.encoder.encode(result)
        } else if path.hasSuffix("/usage-query/settings") {
            let settings = UsageQuerySettingsResponse(
                agent: .agy,
                enabled: true,
                templateId: "agy-subscription",
                template: UsageQueryPresetTemplate.all[1].template,
                credentials: UsageQueryCredentials(
                    baseUrl: UsageQueryCredentialStatus(configured: true, source: "builtin"),
                    apiKey: UsageQueryCredentialStatus(configured: true, source: "file")
                )
            )
            data = try HapiJSON.encoder.encode(settings)
        } else if request.httpMethod == "POST" {
            posts.append(Post(path: path, body: request.httpBody.map { String(decoding: $0, as: UTF8.self) }))
            if postsHeld { await withCheckedContinuation { postWaiters.append($0) } }
            status = changesRejected ? 409 : 200
            data = Data((changesRejected ? #"{"error":"Config rejected"}"# : #"{"ok":true}"#).utf8)
        } else if path.hasSuffix("/codex-models") {
            modelRequests += 1
            data = try HapiJSON.encoder.encode(CodexModelsResponse(
                success: !modelsFailure, models: modelsFailure ? nil : models,
                error: modelsFailure ? "Catalog unavailable" : nil
            ))
        } else if path == "/api/sessions/config" {
            data = try HapiJSON.encoder.encode(SessionResponse(session: detail))
        } else {
            throw URLError(.unsupportedURL)
        }
        return (data, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
}

@MainActor
func configEventually(
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: () async -> Bool
) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for session config state", file: file, line: line)
}
