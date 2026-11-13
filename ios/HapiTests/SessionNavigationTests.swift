import HapiClient
import HapiProtocol
import SwiftUI
import XCTest
@testable import Hapi

@MainActor
final class SessionNavigationTests: XCTestCase {
    func testColdStartAndHubReplacementHaveNoSelection() {
        let navigation = SessionNavigationState()
        XCTAssertNil(navigation.selectedSessionId)
        XCTAssertTrue(navigation.detailPath.isEmpty)
        XCTAssertEqual(navigation.columnVisibility, .all)
        XCTAssertEqual(navigation.preferredCompactColumn, .sidebar)
        navigation.open("a")
        XCTAssertNil(SessionNavigationState().selectedSessionId)
    }

    func testOpenIsIdempotentAndNewSessionClearsNestedNavigation() {
        let navigation = SessionNavigationState()
        navigation.open("a")
        navigation.detailPath.append("files")
        navigation.open("a")
        XCTAssertEqual(navigation.detailPath.count, 1)
        navigation.open("created-before-list-refresh")
        XCTAssertEqual(navigation.selectedSessionId, "created-before-list-refresh")
        XCTAssertTrue(navigation.detailPath.isEmpty)
        XCTAssertEqual(navigation.preferredCompactColumn, .detail)
    }

    func testColumnChangesDoNotDiscardSelectionOrDetailPath() {
        let navigation = SessionNavigationState()
        navigation.open("a")
        navigation.detailPath.append("file.swift")
        navigation.columnVisibility = .detailOnly
        navigation.preferredCompactColumn = .sidebar
        XCTAssertEqual(navigation.selectedSessionId, "a")
        XCTAssertEqual(navigation.detailPath.count, 1)
        navigation.open("a")
        navigation.columnVisibility = .all
        XCTAssertEqual(navigation.preferredCompactColumn, .detail)
        XCTAssertEqual(navigation.detailPath.count, 1)
    }

    func testSupersedingAndRemovalCannotStealAnotherChatsFocus() {
        let navigation = SessionNavigationState()
        navigation.open("a")
        navigation.open("b")
        navigation.detailPath.append("files")
        navigation.supersede("a", with: "a-resumed")
        navigation.remove("a")
        XCTAssertEqual(navigation.selectedSessionId, "b")
        XCTAssertEqual(navigation.detailPath.count, 1)
        navigation.supersede("b", with: "b-resumed")
        XCTAssertEqual(navigation.selectedSessionId, "b-resumed")
        XCTAssertTrue(navigation.detailPath.isEmpty)
        navigation.remove("b-resumed")
        XCTAssertNil(navigation.selectedSessionId)
        XCTAssertEqual(navigation.preferredCompactColumn, .sidebar)
    }

    func testHubPublishesExplicitRemovalsEvenForAnUnlistedSession() throws {
        let hub = try XCTUnwrap(HubSession(hubUrl: "http://127.0.0.1:1/ipad-removal-\(UUID())",
                                         credentialStore: InMemoryCredentialStore()))
        defer { hub.shutdown() }
        hub.sessionStore.applySessionEvent(.sessionRemoved(namespace: nil, sessionId: "a"))
        let first = try XCTUnwrap(hub.sessionRemoval)
        XCTAssertEqual(first.sessionId, "a")
        hub.sessionStore.applySessionEvent(.sessionRemoved(namespace: nil, sessionId: "a"))
        XCTAssertNotEqual(hub.sessionRemoval, first)
    }

    func testAppUsesOneSceneWithoutRequiringFullScreen() {
        let manifest = Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any]
        XCTAssertEqual(manifest?["UIApplicationSupportsMultipleScenes"] as? Bool, false)
        XCTAssertNotEqual(Bundle.main.object(forInfoDictionaryKey: "UIRequiresFullScreen") as? Bool, true)
    }

    func testLastSurfaceReleaseStopsTransportBeforeModelDeallocation() async throws {
        let hub = try XCTUnwrap(HubSession(hubUrl: "http://127.0.0.1:1/ipad-release-\(UUID())",
                                         credentialStore: InMemoryCredentialStore()))
        defer { hub.shutdown() }
        var model: ChatModel? = ChatModel(session: hub, sessionId: "a")
        weak var released = model
        model?.retainSurface("chat")
        for _ in 0..<100 {
            if hub.openChatSessionId == "a" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(hub.openChatSessionId, "a")
        model?.releaseSurface("chat")
        model = nil
        for _ in 0..<100 {
            if hub.openChatSessionId == nil && released == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(hub.openChatSessionId, "Teardown must not depend on the view retaining its old model")
        XCTAssertNil(released)
    }

    func testIdleChildChatModelLiveUpdatesHeaderOnParentRenameAndDeletion() async throws {
        let hub = try XCTUnwrap(HubSession(hubUrl: "http://127.0.0.1:1/parent-header-live-\(UUID())",
                                           credentialStore: InMemoryCredentialStore()))
        defer { hub.shutdown() }

        let parentId = "c9ff2d9a-0e95-48bf-a879-9728df0040c6"
        let childId = "6b5b7d64-8827-4aec-8f69-b27d210f58ac"

        let parentInitial = Session(
            id: parentId,
            namespace: "default",
            seq: 1,
            createdAt: 1_000,
            updatedAt: 1_000,
            active: true,
            activeAt: 1_000,
            metadata: SessionMetadata(path: "/repo", host: "mac", name: "Original Orchestrator", flavor: "agy"),
            metadataVersion: 1,
            agentStateVersion: 0,
            thinking: false,
            thinkingAt: 0
        )
        let childInitial = Session(
            id: childId,
            namespace: "default",
            seq: 1,
            createdAt: 1_100,
            updatedAt: 1_100,
            active: true,
            activeAt: 1_100,
            metadata: SessionMetadata(path: "/repo", host: "mac", name: "Reviewer Subsession", flavor: "codex", parentSessionId: parentId),
            metadataVersion: 1,
            agentStateVersion: 0,
            thinking: false,
            thinkingAt: 0
        )

        hub.sessionStore.applySessionEvent(.sessionAdded(namespace: nil, sessionId: parentId, data: .session(parentInitial)))
        hub.sessionStore.applySessionEvent(.sessionAdded(namespace: nil, sessionId: childId, data: .session(childInitial)))

        let model = ChatModel(session: hub, sessionId: childId)
        model.retainSurface("chat")
        defer { model.releaseSurface("chat") }

        XCTAssertEqual(model.header.parentSessionId, parentId)
        XCTAssertEqual(model.header.parentTitle, "Original Orchestrator")
        XCTAssertTrue(model.header.isParentNavigable)

        // Rename parent via SSE while child chat has zero incoming messages
        var parentRenamed = parentInitial
        parentRenamed.metadata?.name = "Renamed Orchestrator"
        parentRenamed.metadataVersion = 2
        parentRenamed.updatedAt = 2_000
        hub.sessionStore.applySessionEvent(.sessionUpdated(namespace: nil, sessionId: parentId, data: .session(parentRenamed)))

        for _ in 0..<50 {
            if model.header.parentTitle == "Renamed Orchestrator" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.header.parentTitle, "Renamed Orchestrator")
        XCTAssertTrue(model.header.isParentNavigable)

        // Delete parent via SSE while child chat remains open and idle
        hub.sessionStore.applySessionEvent(.sessionRemoved(namespace: nil, sessionId: parentId))

        for _ in 0..<50 {
            if !model.header.isParentNavigable { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.header.parentSessionId, parentId)
        XCTAssertEqual(model.header.parentTitle, "c9ff2d9a")
        XCTAssertFalse(model.header.isParentNavigable)
    }

    func testBuildHeaderIgnoresStaleParentDetailWhenParentMissingFromSummaries() {
        let parentId = "c9ff2d9a-0e95-48bf-a879-9728df0040c6"
        let childId = "6b5b7d64-8827-4aec-8f69-b27d210f58ac"

        let staleParentDetail = Session(
            id: parentId,
            namespace: "default",
            seq: 1,
            createdAt: 1_000,
            updatedAt: 1_000,
            active: false,
            activeAt: 1_000,
            metadata: SessionMetadata(path: "/repo", host: "mac", name: "Deleted While Offline", flavor: "agy"),
            metadataVersion: 1,
            agentStateVersion: 0,
            thinking: false,
            thinkingAt: 0
        )
        let childDetail = Session(
            id: childId,
            namespace: "default",
            seq: 1,
            createdAt: 1_100,
            updatedAt: 1_100,
            active: true,
            activeAt: 1_100,
            metadata: SessionMetadata(path: "/repo", host: "mac", name: "Child", flavor: "codex", parentSessionId: parentId),
            metadataVersion: 1,
            agentStateVersion: 0,
            thinking: false,
            thinkingAt: 0
        )
        var childSummary = HomeFilterTestData.summary(childId, machine: "mac")
        childSummary.metadata = SessionSummaryMetadata(name: "Child", path: "/repo", flavor: "codex", parentSessionId: parentId)

        let missingHeader = ChatModel.buildHeader(
            sessionId: childId,
            detail: childDetail,
            summary: childSummary,
            allSessions: [childSummary],
            parentDetail: staleParentDetail,
            machines: []
        )
        XCTAssertEqual(missingHeader.parentSessionId, parentId)
        XCTAssertEqual(missingHeader.parentTitle, "c9ff2d9a")
        XCTAssertFalse(missingHeader.isParentNavigable)

        var archivedParentSummary = HomeFilterTestData.summary(parentId, machine: "mac")
        archivedParentSummary.metadata = SessionSummaryMetadata(
            name: "Archived Parent Summary",
            path: "/repo",
            flavor: "agy",
            lifecycleState: "archived"
        )
        let archivedHeader = ChatModel.buildHeader(
            sessionId: childId,
            detail: childDetail,
            summary: childSummary,
            allSessions: [archivedParentSummary, childSummary],
            parentDetail: staleParentDetail,
            machines: []
        )
        XCTAssertTrue(archivedHeader.isParentNavigable)
        XCTAssertEqual(archivedHeader.parentTitle, "Deleted While Offline")
    }

    func testOfflineParentRemovalDuringFullResyncDisablesHeaderNavigationDespiteStaleCachedDetail() async throws {
        struct MissedRemovalHTTP: HTTPPerforming {
            let childSummaryJSON: Data
            let childDetailJSON: Data
            let parentId: String
            let childId: String

            func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let url = request.url ?? URL(string: "http://127.0.0.1:1")!
                let path = url.path
                if path.hasSuffix("/api/sessions") {
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (childSummaryJSON, response)
                }
                if path.hasSuffix("/api/sessions/\(parentId)") {
                    let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (Data("{\"error\":\"Session not found\"}".utf8), response)
                }
                if path.hasSuffix("/api/sessions/\(childId)") {
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (childDetailJSON, response)
                }
                let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (Data("{}".utf8), response)
            }
        }

        let parentId = "c9ff2d9a-0e95-48bf-a879-9728df0040c6"
        let childId = "6b5b7d64-8827-4aec-8f69-b27d210f58ac"
        let hubUrl = "https://missed-removal-\(UUID().uuidString.lowercased()).invalid"

        let parentInitial = Session(
            id: parentId,
            namespace: "default",
            seq: 1,
            createdAt: 1_000,
            updatedAt: 1_000,
            active: true,
            activeAt: 1_000,
            metadata: SessionMetadata(path: "/repo", host: "mac", name: "Cached Parent", flavor: "agy"),
            metadataVersion: 1,
            agentStateVersion: 0,
            thinking: false,
            thinkingAt: 0
        )
        let childInitial = Session(
            id: childId,
            namespace: "default",
            seq: 1,
            createdAt: 1_100,
            updatedAt: 1_100,
            active: true,
            activeAt: 1_100,
            metadata: SessionMetadata(path: "/repo", host: "mac", name: "Child", flavor: "codex", parentSessionId: parentId),
            metadataVersion: 1,
            agentStateVersion: 0,
            thinking: false,
            thinkingAt: 0
        )
        var childSummary = HomeFilterTestData.summary(childId, machine: "mac")
        childSummary.metadata = SessionSummaryMetadata(name: "Child", path: "/repo", flavor: "codex", parentSessionId: parentId)

        let childSummaryPayload = try HapiJSON.encoder.encode(SessionsResponse(sessions: [childSummary]))
        let childDetailPayload = try HapiJSON.encoder.encode(SessionResponse(session: childInitial))

        let exp = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let claimsB64 = Data("{\"uid\":1,\"ns\":\"default\",\"exp\":\(exp)}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let fakeJWT = "eyJhbGciOiJIUzI1NiJ9.\(claimsB64).c2ln"

        let credentialStore = InMemoryCredentialStore()
        try credentialStore.store(HubCredentials(hubUrl: hubUrl, accessToken: "token", jwt: fakeJWT))

        let performer = MissedRemovalHTTP(
            childSummaryJSON: childSummaryPayload,
            childDetailJSON: childDetailPayload,
            parentId: parentId,
            childId: childId
        )
        let hub = try XCTUnwrap(HubSession(hubUrl: hubUrl, credentialStore: credentialStore, performer: performer))
        defer { hub.shutdown() }

        // Populate both summary and detail caches before going offline
        hub.sessionStore.applySessionEvent(.sessionAdded(namespace: nil, sessionId: parentId, data: .session(parentInitial)))
        hub.sessionStore.applySessionEvent(.sessionAdded(namespace: nil, sessionId: childId, data: .session(childInitial)))

        let model = ChatModel(session: hub, sessionId: childId)
        model.retainSurface("chat")
        defer { model.releaseSurface("chat") }

        XCTAssertTrue(model.header.isParentNavigable)
        XCTAssertEqual(model.header.parentTitle, "Cached Parent")

        // Reconnect: parent was deleted while offline (missed sessionRemoved).
        // fullResync replaces `sessions` with [childSummary], while parent's 404 keeps stale `details[parentId]`.
        try await hub.sessionStore.fullResync()

        XCTAssertNotNil(hub.sessionStore.detail(for: parentId), "SessionListStore retains stale detail on 404")

        for _ in 0..<50 {
            if !model.header.isParentNavigable { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.header.isParentNavigable)
        XCTAssertEqual(model.header.parentTitle, "c9ff2d9a")
    }
}
