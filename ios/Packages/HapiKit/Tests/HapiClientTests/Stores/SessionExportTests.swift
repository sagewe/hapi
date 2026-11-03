import Foundation
@testable import HapiClient
import HapiProtocol
import Testing

/// `GET /sessions/:id/export`: the web download's filename and the hub's
/// warning / too-large answers.
@MainActor
@Suite("Session export")
struct SessionExportTests {
    @Test func payloadBecomesAPrettyJsonFileNamedLikeTheWebDownload() async throws {
        let performer = RecordingPerformer()
        let api = try makeStoreAPIClient(performer: performer)
        await performer.enqueue(json: """
        {"schemaVersion":2,"exportedAt":1793145600000,"scratchlist":[],
         "session":{"id":"abcdef123456","metadata":{"name":"Fix login: bug #2","path":"/repo/app"}},
         "messages":[{"id":"m1"},{"id":"m2"}]}
        """)
        guard case .file(let file) = try await api.exportSession(sessionId: "abcdef123456") else {
            Issue.record("expected a file")
            return
        }
        #expect(file.filename == "fix-login-bug-2-abcdef12-2026-10-28.json")
        #expect(file.messageCount == 2)
        let text = String(decoding: file.data, as: UTF8.self)
        #expect(text.hasSuffix("}\n"))
        #expect(text.contains("\"path\" : \"/repo/app\""))
        let path = await performer.requests.first?.url?.path
        #expect(path == "/api/sessions/abcdef123456/export")
    }

    @Test func markdownIncludesFullPayloadAndScratchlistWithoutChangingJSON() throws {
        let data = Data(#"{"exportedAt":0,"session":{"id":"abcdefgh123","metadata":{"name":"Demo","host":"mac","path":"/repo","flavor":"codex"}},"messages":[{"id":"u","createdAt":0,"content":{"role":"user","content":"Hello **world**"}},{"id":"a","createdAt":1,"content":{"role":"agent","content":"Hi there"}}],"scratchlist":[{"createdAt":0,"text":"Remember","attachments":[{"filename":"a.png","mimeType":"image/png","size":42}]}]}"#.utf8)
        guard case .file(let file) = try SessionExportFormatting.result(from: data) else { Issue.record("file expected"); return }
        let markdown = try file.markdown()
        let text = String(decoding: markdown.data, as: UTF8.self)
        #expect(markdown.filename == "demo-abcdefgh-1970-01-01.md")
        #expect(text.contains("## User\n\n_Time: 1970-01-01T00:00:00.000Z_\n\nHello **world**"))
        #expect(text.contains("## Assistant"))
        #expect(text.contains("Hi there"))
        #expect(text.contains("## Scratchlist"))
        #expect(text.contains("- Attachment: a.png (image/png, 42 bytes)"))
        #expect(text.contains("messageCount: 2"))
        #expect(text.contains("scratchlistCount: 1"))
        #expect(file.filename.hasSuffix(".json"))
        #expect(try JSONSerialization.jsonObject(with: file.data) is [String: Any])
    }

    @Test func markdownEscapesMetadataAndKeepsEmptyExportsValid() throws {
        let data = Data(#"{"exportedAt":0,"session":{"id":"s","metadata":{"name":"Title\nwith\"quote","path":"/repo"}},"messages":[]}"#.utf8)
        guard case .file(let file) = try SessionExportFormatting.result(from: data) else { Issue.record("file expected"); return }
        let text = String(decoding: try file.markdown().data, as: UTF8.self)
        #expect(text.contains(#"title: "Title\nwith\"quote""#))
        #expect(text.contains("scratchlistCount: 0"))
        #expect(!text.contains("## Scratchlist"))
        #expect(text.hasSuffix("\n"))
    }

    @Test func markdownSummarizesToolsAndSkipsInitializationMessages() throws {
        let data = Data(#"{"exportedAt":0,"session":{"id":"s","metadata":null},"messages":[{"id":"skip","createdAt":0,"content":{"role":"agent","content":{"type":"output","data":{"type":"system","subtype":"init","uuid":"sys-init"}}}},{"id":"tool","createdAt":1,"content":{"role":"agent","content":{"type":"output","data":{"type":"assistant","uuid":"a","message":{"content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"bun test"}}]}}}}}]}"#.utf8)
        guard case .file(let file) = try SessionExportFormatting.result(from: data) else { Issue.record("file expected"); return }
        let text = String(decoding: try file.markdown().data, as: UTF8.self)
        #expect(text.contains("- Tool: Bash"))
        #expect(text.contains("bun test"))
        #expect(!text.contains("sys-init"))
    }

    @Test func warningAndTooLargeAnswers() async throws {
        let performer = RecordingPerformer()
        let api = try makeStoreAPIClient(performer: performer)
        await performer.enqueue(json: #"{"type":"warning","count":25000,"limit":20000,"estimatedBytes":9000}"#)
        #expect(try await api.exportSession(sessionId: "s1") == .warning(count: 25000, limit: 20000, estimatedBytes: 9000))

        await performer.enqueue(
            status: 413,
            json: #"{"type":"too-large","error":"x","code":"session_export_too_large","count":9,"estimatedBytes":200,"maxBytes":100}"#
        )
        #expect(try await api.exportSession(sessionId: "s1", force: true) == .tooLarge(count: 9, estimatedBytes: 200, maxBytes: 100))
        let query = await performer.requests.last?.url?.query
        #expect(query == "force=true")
    }

    @Test func untitledSessionsFallBackToThePathTail() throws {
        let data = Data(#"{"exportedAt":0,"session":{"id":"zz","metadata":{"path":"/w/中文 项目"}},"messages":[]}"#.utf8)
        guard case .file(let file) = try SessionExportFormatting.result(from: data) else {
            Issue.record("expected a file")
            return
        }
        #expect(file.filename == "中文-项目-zz-1970-01-01.json")
    }
}
