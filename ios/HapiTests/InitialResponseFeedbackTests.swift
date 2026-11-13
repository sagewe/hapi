import HapiClient
@testable import HapiProtocol
import HapiUI
import SwiftUI
import UIKit
import XCTest
@testable import Hapi

@MainActor
final class InitialResponseFeedbackTests: XCTestCase {
    func testRealSendShowsFeedbackUntilFirstResponseWithoutAddingAMessage() async throws {
        let credentials = InMemoryCredentialStore()
        let payload = Data(#"{"uid":1,"exp":4102444800,"ns":"test"}"#.utf8).base64EncodedString()
        try credentials.store(HubCredentials(hubUrl: "http://127.0.0.1:1", accessToken: "test", jwt: "e30.\(payload).test"))
        let http = InitialResponseHTTP()
        let hub = try XCTUnwrap(HubSession(hubUrl: "http://127.0.0.1:1/feedback-\(UUID().uuidString)", credentialStore: credentials, performer: http))
        try await hub.sessionStore.loadSessionDetail("feedback")
        let model = ChatModel(session: hub, sessionId: "feedback")
        defer { model.stop(); hub.shutdown(); Task { await http.releaseSend() } }
        model.start()
        try await eventually { !model.isSyncingTail && model.header.active }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let host = UIHostingController(rootView: ChatTranscriptView(model: model).hapiTypography().hapiTheme(.light))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        model.interactor.setComposerText("Hello")
        model.interactor.sendMessage()
        XCTAssertEqual(model.responseFeedback, .sending, "Send must provide feedback before HTTP or SSE returns")
        try await eventually { self.collection(in: host.view)?.visibleCells.contains { $0.accessibilityIdentifier == "chat-row-chat-response-feedback" } == true }
        let controller = await hub.windows.open(sessionId: "feedback")
        let lastMessage = await controller.state.messages.last
        let pending = try XCTUnwrap(lastMessage)
        let localID = try XCTUnwrap(pending.localId)
        await http.startRun(at: pending.createdAt)
        hub.sessionStore.updateDetailLocal("feedback") {
            $0.thinking = true
            $0.activeTurnStartedAt = pending.createdAt
        }
        await http.releaseSend()
        try await eventually { model.responseFeedback == .waiting }
        await controller.markConsumed(localIds: [localID], invokedAt: pending.createdAt + 1)
        try await eventually { model.responseFeedback == .thinking }
        let collection = try XCTUnwrap(collection(in: host.view))
        let placeholder = try XCTUnwrap(collection.visibleCells.first { $0.accessibilityIdentifier == "chat-row-chat-response-feedback" })
        let beforeY = placeholder.frame.minY - collection.contentOffset.y
        let seq = (await controller.state.newestSeq ?? 0) + 1
        let reply = DecryptedMessage(id: "reply", seq: seq,
            content: ["role": "agent", "content": ["type": "codex", "data": ["type": "message", "message": "First reply"]]],
            createdAt: pending.createdAt + 2, invokedAt: pending.createdAt + 2)
        await controller.onMessageEvent(.messageReceived(namespace: nil, sessionId: "feedback", message: reply))
        try await eventually { model.responseFeedback == nil && model.messageRows.count == 3 }
        try await eventually { collection.visibleCells.contains { $0.accessibilityIdentifier == model.messageRows.dropFirst().first.map { "chat-row-\($0.id)" } } }
        XCTAssertFalse(collection.visibleCells.contains { $0.accessibilityIdentifier == "chat-row-chat-response-feedback" })
        let replyCell = try XCTUnwrap(collection.visibleCells.first { $0.accessibilityIdentifier == model.messageRows.dropFirst().first.map { "chat-row-\($0.id)" } })
        XCTAssertEqual(replyCell.frame.minY - collection.contentOffset.y, beforeY, accuracy: 2)
        let storedCount = await controller.state.messages.count
        XCTAssertEqual(storedCount, 2, "Feedback is UI state, never conversation history")
    }

    private func collection(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView { return collection }
        return view.subviews.lazy.compactMap { self.collection(in: $0) }.first
    }
    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for response feedback", file: file, line: line)
    }
}

private actor InitialResponseHTTP: HTTPPerforming {
    private var released = false
    private var startedAt: Int?
    func startRun(at: Int) { startedAt = at }
    private var waiter: CheckedContinuation<Void, Never>?
    func releaseSend() { released = true; waiter?.resume(); waiter = nil }
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let data: Data
        if request.httpMethod == "POST", url.lastPathComponent == "messages" {
            if !released { await withCheckedContinuation { waiter = $0 } }
            data = Data("{}".utf8)
        } else if url.lastPathComponent == "messages" {
            data = try JSONEncoder().encode(MessagesResponse(messages: [], page: MessagesPage(
                direction: .latest, limit: 200, epoch: 1, reset: false,
                nextBeforeSeq: nil, nextBeforeAt: nil, nextAfterSeq: nil, nextAfterAt: nil,
                snapshotHeadSeq: nil, snapshotHeadAt: nil, hasMore: false)))
        } else if url.lastPathComponent == "feedback" {
            data = try JSONEncoder().encode(SessionResponse(session: Session(id: "feedback", namespace: "test", seq: 1,
                createdAt: 0, updatedAt: 0, active: true, activeAt: 0, metadataVersion: 0, agentStateVersion: 0,
                thinking: startedAt != nil, thinkingAt: startedAt ?? 0, activeTurnStartedAt: startedAt)))
        } else { data = Data("{}".utf8) }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
