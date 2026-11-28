import Foundation
import Testing
@testable import HapiProtocol

@Suite("SceneDraftParser")
struct SceneDraftParserTests {
    @Test("Extracts valid qiqi-scene-draft block and removes raw fence from prose")
    func extractsDraft() {
        let markdown = """
        已整理为场景草案：

        ```qiqi-scene-draft
        {
          "id": "custom-lc-review",
          "title": "信用证审单",
          "subtitle": "上传信用证与提单…",
          "icon": "checklist",
          "opensAttachment": true,
          "skillSlug": "custom-lc-review",
          "referenceDocIds": ["ref_1"],
          "summaryPoints": ["核对装船期与效期", "输出表格版 PDF"],
          "prompt": "按信用证审单清单核查"
        }
        ```

        满意即可保存。
        """
        let result = SceneDraftParser.extract(from: markdown)
        #expect(result.drafts.count == 1)
        #expect(result.drafts[0].id == "custom-lc-review")
        #expect(result.drafts[0].title == "信用证审单")
        #expect(result.drafts[0].opensAttachment == true)
        #expect(result.drafts[0].referenceDocIds == ["ref_1"])
        #expect(result.drafts[0].summaryPoints.count == 2)
        #expect(!result.markdown.contains("qiqi-scene-draft"))
        #expect(result.markdown.contains("已整理为场景草案"))
        #expect(result.markdown.contains("满意即可保存"))
    }

    @Test("Leaves malformed JSON fence intact without crashing")
    func ignoresMalformedFence() {
        let markdown = "前文\n```qiqi-scene-draft\n{not-json}\n```"
        let result = SceneDraftParser.extract(from: markdown)
        #expect(result.drafts.isEmpty)
        #expect(result.markdown == markdown)
    }
}
