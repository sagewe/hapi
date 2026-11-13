import Testing
@testable import HapiProtocol

@Suite("Initial response feedback")
struct InitialResponseTests {
    private func user(_ status: String = "sent", invokedAt: Int? = nil) -> VisibleChatBlock {
        .block(.userText(.init(id: "u", localId: "local", createdAt: 1000, invokedAt: invokedAt,
            text: "hello", attachments: nil, status: status, originalText: nil, meta: nil)))
    }
    private func reply(_ text: String = "First reply", at: Int = 2000) -> VisibleChatBlock {
        .block(.agentText(.init(id: "a", localId: nil, createdAt: at, invokedAt: nil,
            durationMs: nil, usage: nil, model: nil, text: text, meta: nil)))
    }
    @Test func transitionsFromSendToFirstOutput() {
        #expect(initialResponseState([], isSending: true, isRunning: false, isActive: true) == .sending)
        #expect(initialResponseState([user()], isSending: false, isRunning: false, isActive: true) == .waiting)
        #expect(initialResponseState([user("queued")], isSending: false, isRunning: true, isActive: true) == .waiting)
        #expect(initialResponseState([user(invokedAt: 1100)], isSending: false, isRunning: true, isActive: true) == .thinking)
        #expect(initialResponseState([user(invokedAt: 1100), reply()], isSending: false, isRunning: true, isActive: true) == nil)
        #expect(initialResponseState([user(invokedAt: 1100), reply("   ")], isSending: false, isRunning: true, isActive: true) == .thinking)
    }
    @Test func failureCancellationAndNavigationRemoveFeedback() {
        #expect(initialResponseState([user(invokedAt: 1100)], isSending: false, isRunning: false, isActive: true) == nil)
        #expect(initialResponseState([user("failed")], isSending: false, isRunning: false, isActive: true) == nil)
        #expect(initialResponseState([user()], isSending: false, isRunning: false, isActive: true, completedRounds: ["u"]) == nil)
        #expect(initialResponseState([user()], isSending: false, isRunning: true, isActive: false) == nil)
        #expect(initialResponseState([user()], isSending: false, isRunning: true, isActive: true, isHistory: true) == nil)
        #expect(initialResponseState([user()], isSending: false, isRunning: true, isActive: true, isHydrating: true) == nil)
        #expect(initialResponseState([], isSending: false, isRunning: false, isActive: true) == nil)
    }
    @Test func oldOutputDoesNotMaskANewRun() {
        #expect(initialResponseState([user(invokedAt: 100), reply(at: 500)], isSending: false, isRunning: true,
            isActive: true, activeTurnStartedAt: 1000) == .waiting)
    }
}
