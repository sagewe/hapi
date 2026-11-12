import Foundation
import HapiClient
import HapiProtocol
import XCTest
@testable import Hapi

@MainActor
final class NewSessionDirectoryTests: XCTestCase {
    func testClearingDirectorySurvivesRosterRefreshWithoutResettingModel() async throws {
        let harness = try NewSessionDirectoryHarness()
        defer { harness.model.stopDirectoryWork() }
        await harness.model.start()
        harness.model.setModel("opus")
        harness.model.setDirectory("")
        try await harness.session.machineStore.refresh()
        harness.model.machinesChanged()
        XCTAssertEqual(harness.model.form.directory, "")
        XCTAssertEqual(harness.model.form.model, "opus")
        XCTAssertFalse(harness.model.canCreate)
    }

    func testRestoredEmptyDirectoryIsNotReseeded() async throws {
        let harness = try NewSessionDirectoryHarness()
        defer { harness.model.stopDirectoryWork() }
        harness.prefs.writeDraft(NewSessionForm(machineId: "m1", directory: "", model: "opus"))
        await harness.model.start()
        XCTAssertEqual(harness.model.form.directory, "")
        XCTAssertEqual(harness.model.form.model, "opus")
    }

    func testExplicitPickOfFallbackSurvivesLateRecentDirectoryResponse() async throws {
        let harness = try NewSessionDirectoryHarness()
        defer { harness.model.stopDirectoryWork() }
        harness.prefs.writePrefs(NewSessionPrefsData(lastMachineId: "m1", recentPaths: ["m1": ["/recent"]]))
        await harness.http.holdPath("/recent")
        await harness.model.start()
        try await newSessionEventually { await harness.http.waitingPaths.contains("/recent") }
        // Same text as the automatic fallback: string equality alone is insufficient.
        harness.model.pickRecentPath("/home/m1")
        await harness.http.releasePaths()
        try await newSessionEventually { await harness.http.completedPaths.contains("/recent") }
        XCTAssertEqual(harness.model.form.directory, "/home/m1")
        XCTAssertEqual(harness.prefs.readDraft()?.directory, "/home/m1")
    }

    func testOfflineSelectionRetainsItsPathAndExplicitSwitchUsesTheNewMachineDefault() async throws {
        let harness = try NewSessionDirectoryHarness()
        defer { harness.model.stopDirectoryWork() }
        await harness.model.start()
        harness.model.setDirectory("/project/on/m1")
        harness.session.machineStore.applyMachineEvent(machineId: "m1", data: .removed)
        harness.model.machinesChanged()
        XCTAssertEqual(harness.model.form.machineId, "m1")
        XCTAssertEqual(harness.model.form.directory, "/project/on/m1")
        XCTAssertTrue(harness.model.machineUnavailable)
        XCTAssertFalse(harness.model.canCreate)
        harness.model.create()
        let spawns = await harness.http.spawns
        XCTAssertTrue(spawns.isEmpty)
        harness.model.setMachine("m2")
        XCTAssertEqual(harness.model.form.machineId, "m2")
        XCTAssertEqual(harness.model.form.directory, "/home/m2")
        XCTAssertFalse(harness.model.machineUnavailable)
    }

    func testHomeExpansionIsUsedForChecksSpawnAndRecentPaths() async throws {
        let harness = try NewSessionDirectoryHarness()
        defer { harness.model.stopDirectoryWork() }
        await harness.model.start()
        harness.model.setDirectory("~/project")
        try await newSessionEventually { harness.model.canCreate }
        harness.model.create()
        try await newSessionEventually { !harness.model.isSpawning }
        let spawns = await harness.http.spawns
        XCTAssertEqual(spawns.map(\.directory), ["/home/m1/project"])
        let paths = await harness.http.checkedPaths
        XCTAssertTrue(paths.contains("/home/m1/project"))
        XCTAssertFalse(paths.contains("~/project"))
        XCTAssertEqual(harness.prefs.readPrefs().recentPaths["m1"], ["/home/m1/project"])
        XCTAssertNil(harness.prefs.readDraft())
    }

    func testMissingDirectoryRequiresSecondTapAndWorktreeRemainsBlocked() async throws {
        let harness = try NewSessionDirectoryHarness()
        defer { harness.model.stopDirectoryWork() }
        await harness.model.start()
        harness.model.setDirectory("/missing")
        try await newSessionEventually { harness.model.canCreate }
        harness.model.create()
        try await newSessionEventually { !harness.model.isSpawning }
        XCTAssertTrue(harness.model.confirmCreateDirectory)
        let firstSpawns = await harness.http.spawns
        XCTAssertTrue(firstSpawns.isEmpty)
        harness.model.create()
        try await newSessionEventually { !harness.model.isSpawning }
        let confirmedSpawns = await harness.http.spawns
        XCTAssertEqual(confirmedSpawns.count, 1)

        harness.model.setDirectory("/missing-worktree")
        harness.model.setSessionType(.worktree)
        try await newSessionEventually { !harness.model.directoryInput.isCheckingExistence }
        XCTAssertFalse(harness.model.canCreate)
        harness.model.create()
        let finalSpawns = await harness.http.spawns
        XCTAssertEqual(finalSpawns.count, 1)
    }

    func testMachineGoingOfflineDuringCreatePreflightDoesNotSpawnElsewhere() async throws {
        let harness = try NewSessionDirectoryHarness()
        defer { harness.model.stopDirectoryWork() }
        await harness.model.start()
        harness.model.setDirectory("/project")
        try await newSessionEventually { harness.model.canCreate && !harness.model.directoryInput.isCheckingExistence }
        await harness.http.holdPath("/project")
        harness.model.create()
        try await newSessionEventually { await harness.http.waitingPaths.contains("/project") }
        harness.session.machineStore.applyMachineEvent(machineId: "m1", data: .removed)
        harness.model.machinesChanged()
        await harness.http.releasePaths()
        try await newSessionEventually { !harness.model.isSpawning }
        let spawns = await harness.http.spawns
        XCTAssertTrue(spawns.isEmpty)
        XCTAssertEqual(harness.model.spawnError, NewSessionModel.msgMachineOffline)
        XCTAssertEqual(harness.model.form.machineId, "m1")
    }

    func testRemembersLastCreatedLaunchConfigAcrossReopenAgentSwitchAndCancel() async throws {
        let harness = try NewSessionDirectoryHarness()
        defer { harness.model.stopDirectoryWork() }
        await harness.http.setAvailableAgents([.claude, .codex, .agy])

        await harness.model.start()
        try await newSessionEventually { !harness.model.agentAvailabilityLoading }

        // 1. Create a Claude worktree session with custom model, effort, and permission.
        harness.model.setDirectory("/project/claude")
        harness.model.setModel("opus")
        harness.model.setEffort("high")
        harness.model.setPermissionMode(.plan)
        harness.model.setSessionType(.worktree)
        harness.model.setWorktreeName("temp-branch")
        try await newSessionEventually { harness.model.canCreate }
        harness.model.create()
        try await newSessionEventually { !harness.model.isSpawning }

        // 2. Reopen New Session: remembers Claude + opus + high + plan + recent directory,
        //    while resetting Session Type back to Simple and clearing worktree name.
        let reopened1 = harness.makeModel()
        defer { reopened1.stopDirectoryWork() }
        await reopened1.start()
        try await newSessionEventually {
            reopened1.form.directory == "/project/claude" && !reopened1.agentAvailabilityLoading
        }
        XCTAssertEqual(reopened1.form.machineId, "m1")
        XCTAssertEqual(reopened1.form.agent, .claude)
        XCTAssertEqual(reopened1.form.model, "opus")
        XCTAssertEqual(reopened1.form.effort, "high")
        XCTAssertEqual(reopened1.form.permissionMode, .plan)
        XCTAssertEqual(reopened1.form.sessionType, .simple)
        XCTAssertEqual(reopened1.form.worktreeName, "")
        XCTAssertNil(harness.prefs.readDraft())

        // 3. Switch to Antigravity (agy), enable YOLO + pick model, and create.
        reopened1.setAgent(.agy)
        try await newSessionEventually { reopened1.agentModels != .loading }
        reopened1.setDirectory("/project/agy")
        reopened1.setModel("gemini-3.1-pro-high")
        reopened1.setYolo(true)
        try await newSessionEventually { reopened1.canCreate }
        reopened1.create()
        try await newSessionEventually { !reopened1.isSpawning }

        // 4. Reopen New Session: defaults to agy + gemini-3.1-pro-high + yolo=true + /project/agy;
        //    switching back to Claude restores Claude's saved opus + high + plan;
        //    tapping Cancel discards unsaved edits so the next open still defaults to agy.
        let reopened2 = harness.makeModel()
        defer { reopened2.stopDirectoryWork() }
        await reopened2.start()
        try await newSessionEventually {
            reopened2.form.directory == "/project/agy"
                && !reopened2.agentAvailabilityLoading
                && reopened2.agentModels != .loading
        }
        XCTAssertEqual(reopened2.form.agent, .agy)
        XCTAssertEqual(reopened2.form.model, "gemini-3.1-pro-high")
        XCTAssertTrue(reopened2.form.yolo)

        reopened2.setAgent(.claude)
        XCTAssertEqual(reopened2.form.model, "opus")
        XCTAssertEqual(reopened2.form.effort, "high")
        XCTAssertEqual(reopened2.form.permissionMode, .plan)
        XCTAssertNotNil(harness.prefs.readDraft())

        reopened2.cancel()
        XCTAssertNil(harness.prefs.readDraft())

        let reopened3 = harness.makeModel()
        defer { reopened3.stopDirectoryWork() }
        await reopened3.start()
        try await newSessionEventually { !reopened3.agentAvailabilityLoading }
        XCTAssertEqual(reopened3.form.agent, .agy)
        XCTAssertEqual(reopened3.form.model, "gemini-3.1-pro-high")
        XCTAssertTrue(reopened3.form.yolo)
    }

    func testLegacyPrefsWithoutLaunchFieldsDecodeCleanly() throws {
        let legacyJSON = Data(#"{"lastMachineId":"m2","recentPaths":{"m2":["/legacy"]}}"#.utf8)
        let decoded = try HapiJSON.decoder.decode(NewSessionPrefsData.self, from: legacyJSON)
        XCTAssertEqual(decoded.lastMachineId, "m2")
        XCTAssertEqual(decoded.recentPaths, ["m2": ["/legacy"]])
        XCTAssertNil(decoded.lastAgent)
        XCTAssertNil(decoded.lastYolo)
        XCTAssertTrue(decoded.launchSettings.isEmpty)
    }
}

@MainActor
private func newSessionEventually(_ condition: @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(4))
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("New-session state did not settle")
    throw URLError(.timedOut)
}

@MainActor
private final class NewSessionDirectoryHarness {
    let http = NewSessionDirectoryHTTP()
    let session: HubSession
    let model: NewSessionModel
    let prefs: NewSessionPrefsStore
    private let defaults: UserDefaults

    init() throws {
        let hubUrl = "https://directory-\(UUID().uuidString.lowercased()).test"
        let credentials = InMemoryCredentialStore()
        let payload = Data(#"{"uid":1,"exp":4102444800,"ns":"test"}"#.utf8).base64EncodedString()
        try credentials.store(HubCredentials(hubUrl: hubUrl, accessToken: "test", jwt: "e30.\(payload).test"))
        session = try XCTUnwrap(HubSession(hubUrl: hubUrl, credentialStore: credentials, performer: http))
        defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        prefs = NewSessionPrefsStore(hubUrl: hubUrl, defaults: defaults)
        model = NewSessionModel(session: session, defaults: defaults, onCreated: { _ in })
    }

    func makeModel() -> NewSessionModel {
        NewSessionModel(session: session, defaults: defaults, onCreated: { _ in })
    }
}

private actor NewSessionDirectoryHTTP: HTTPPerforming {
    private(set) var spawns: [SpawnRequest] = []
    private(set) var checkedPaths: [String] = []
    private(set) var completedPaths: [String] = []
    private(set) var waitingPaths: Set<String> = []
    private var heldPaths: Set<String> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var availableAgents: [AgentFlavor] = [.claude]

    func setAvailableAgents(_ agents: [AgentFlavor]) { availableAgents = agents }
    func holdPath(_ path: String) { heldPaths.insert(path) }
    func releasePaths() {
        heldPaths = []
        waitingPaths = []
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let data: Data
        if url.path == "/api/machines" {
            struct Roster: Encodable { let machines: [Machine] }
            let machines = ["m1", "m2"].map { id in
                Machine(
                    id: id, namespace: "test", seq: 1, createdAt: 0, updatedAt: 0, active: true, activeAt: 0,
                    metadata: MachineMetadata(host: id, platform: "linux", happyCliVersion: "test", homeDir: "/home/\(id)"),
                    metadataVersion: 1, runnerStateVersion: 0
                )
            }
            data = try HapiJSON.encoder.encode(Roster(machines: machines))
        } else if url.path.hasSuffix("/agent-availability") {
            struct AvailabilityBody: Encodable { let agents: [AgentAvailabilityEntry] }
            data = try HapiJSON.encoder.encode(AvailabilityBody(
                agents: availableAgents.map { AgentAvailabilityEntry(agent: $0, available: true) }
            ))
        } else if url.path.hasSuffix("/agy-models") {
            data = Data(#"{"success":true,"availableModels":[{"modelId":"gemini-3.1-pro-high","name":"Gemini 3.1 Pro (High)"}]}"#.utf8)
        } else if url.path.hasSuffix("/list-directory") {
            data = Data(#"{"success":true,"entries":[]}"#.utf8)
        } else if url.path.hasSuffix("/paths/exists") {
            struct PathsRequest: Decodable { let paths: [String] }
            let paths = try HapiJSON.decoder.decode(PathsRequest.self, from: XCTUnwrap(request.httpBody)).paths
            checkedPaths += paths
            if paths.contains(where: heldPaths.contains) {
                waitingPaths.formUnion(paths)
                await withCheckedContinuation { waiters.append($0) }
            }
            completedPaths += paths
            data = try HapiJSON.encoder.encode(MachinePathsExistsResponse(
                exists: Dictionary(uniqueKeysWithValues: paths.map { ($0, !$0.hasPrefix("/missing")) })
            ))
        } else if url.path.hasSuffix("/spawn") {
            spawns.append(try HapiJSON.decoder.decode(SpawnRequest.self, from: XCTUnwrap(request.httpBody)))
            data = Data(#"{"type":"success","sessionId":"created"}"#.utf8)
        } else {
            XCTFail("Unexpected new-session request: \(url.path)")
            throw URLError(.badURL)
        }
        return (data, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}
