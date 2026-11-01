import Foundation
import HapiProtocol
import Testing
@testable import HapiClient

@Suite("SessionMentions")
struct SessionMentionsTests {
    func row(_ id: String, title: String = "Demo", active: Bool = false, updated: Int = 0,
             content: Bool? = true, archived: Bool = false, agent: String? = nil) -> SessionSummary {
        var value = storeSummary(id, updatedAt: updated)
        value.active = active
        value.hasConversationContent = content
        value.metadata = SessionSummaryMetadata(name: title, path: "/repo", flavor: "codex",
                                               agentSessionId: agent, lifecycleState: archived ? "archived" : nil)
        return value
    }
    func query(_ text: String) -> SessionMentions.Query? {
        SessionMentions.query(in: text, selection: NSRange(location: text.utf16.count, length: 0))
    }

    @Test func webTriggerBoundariesAndMultiwordQueries() {
        #expect(query("@")?.text == "")
        #expect(query("Compare @家庭")?.text == "家庭")
        #expect(query("@Home Assistant")?.text == "Home Assistant")
        for value in ["name@example", "hi(@demo", "@demo ", "@one two three", "@demo\nnext", "@demo,more", "@demo.more"] {
            #expect(query(value) == nil, "\(value)")
        }
        #expect(SessionMentions.query(in: "@中文", selection: NSRange(location: 3, length: 0), composing: true) == nil)
        #expect(SessionMentions.query(in: "@demo", selection: NSRange(location: 1, length: 2)) == nil)
    }

    @Test func insertionReplacesFullTokenAtUnicodeCaretAndPreservesSuffix() throws {
        let text = "😀 请看 @demorest 然后比较"
        let caret = (text as NSString).range(of: "@demo").location + 5
        let result = try #require(SessionMentions.inserting(row("abc", title: "家庭 [A]"), into: text,
                                                           selection: NSRange(location: caret, length: 0)))
        #expect(result.text == "😀 请看 [家庭 \\[A\\]](/sessions/abc) 然后比较")
        #expect(result.selection.location == "😀 请看 [家庭 \\[A\\]](/sessions/abc)".utf16.count)
        let second = result.text + " @"
        let multiple = try #require(SessionMentions.inserting(row("def"), into: second,
                          selection: NSRange(location: second.utf16.count, length: 0)))
        #expect(multiple.text.contains("/sessions/abc"))
        #expect(multiple.text.hasSuffix("[Demo](/sessions/def) "))
    }

    @Test func serializationEscapesLabelsAndNormalizesWhitespace() {
        #expect(SessionMentions.reference(row("abc", title: "  a\n[b]\\  ")) == "[a \\[b\\]\\\\](/sessions/abc)")
        #expect(SessionMentions.reference(row("abc", title: String(repeating: "👨‍👩‍👧‍👦", count: 121))).filter { $0 == "👨‍👩‍👧‍👦" }.count == 120)
    }

    @Test func eligibilityArchiveSearchAndRankingMatchWeb() {
        let rows = [row("self"), row("empty", content: false), row("unknown", content: nil),
                    row("old", title: "Archive", archived: true), row("recent", updated: 100),
                    row("live", active: true)]
        #expect(SessionMentions.matches(rows, query: "", excluding: "self").map(\.id) == ["live", "recent"])
        #expect(SessionMentions.matches(rows, query: "Archive", excluding: "self").map(\.id) == ["old"])
        let ranked = [row("partial", title: "Demo project", active: true), row("exact", title: "Demo")]
        #expect(SessionMentions.matches(ranked, query: "Demo", excluding: "self").first?.id == "exact")
    }

    @Test func dedupUsesLiveConnectionAndExcludesCurrentAlias() {
        let rows = [row("stale", agent: "native"), row("self", active: true, agent: "native"), row("other")]
        #expect(SessionMentions.matches(rows, query: "", excluding: "self").map(\.id) == ["other"])
        let many = (0..<25).map { row("\($0)", updated: $0) }
        #expect(SessionMentions.matches(many, query: "", excluding: "self").count == 20)
    }

    @Test func contentFlagSurvivesWireProjectionAndSSE() throws {
        var summary = row("abc", content: false)
        let patch = try JSONDecoder().decode(SessionPatch.self, from: Data(#"{"hasConversationContent":true}"#.utf8))
        let updated = SummaryPatching.applySessionSummaryPatch(summary, patch)
        #expect(updated.hasConversationContent == true)
        #expect(!SummaryPatching.isRenderIrrelevantPatch(current: summary, next: updated))
        var detail = storeSession("abc")
        detail.hasConversationContent = true
        let wire = try JSONEncoder().encode(detail)
        let decoded = try JSONDecoder().decode(Session.self, from: wire)
        #expect(SummaryPatching.toSessionSummary(decoded).hasConversationContent == true)
        detail.hasConversationContent = false
        #expect(!isRenderIrrelevantSessionPatch(session: detail, patch: patch))
        #expect(applySessionDetailPatch(session: detail, patch: patch)?.hasConversationContent == true)
        summary.hasConversationContent = true
        let encoded = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(SessionSummary.self, from: encoded).hasConversationContent == true)
    }
}
