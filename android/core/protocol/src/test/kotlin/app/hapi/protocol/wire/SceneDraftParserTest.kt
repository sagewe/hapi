package app.hapi.protocol.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SceneDraftParserTest {

    @Test
    fun extractsSceneDraftAndStripsFence() {
        val input = """
            好的，我已为您梳理了核查要点：

            ```qiqi-scene-draft
            {
              "id": "custom-lc-audit",
              "title": "信用证单据审核",
              "subtitle": "上传信用证与发票…",
              "icon": "banknote",
              "opensAttachment": true,
              "skillSlug": "custom-lc-audit",
              "referenceDocIds": ["ref-1"],
              "summaryPoints": ["核对金额与币种", "比对最迟装运期"],
              "prompt": "按 UCP600 逐项核对信用证单据"
            }
            ```

            点击下方卡片即可保存到工作台。
        """.trimIndent()

        val result = SceneDraftParser.extract(input)
        assertEquals(1, result.drafts.size)
        val draft = result.drafts.first()
        assertEquals("custom-lc-audit", draft.id)
        assertEquals("信用证单据审核", draft.title)
        assertEquals("banknote", draft.icon)
        assertTrue(draft.opensAttachment)
        assertEquals(listOf("ref-1"), draft.referenceDocIds)
        assertEquals(2, draft.summaryPoints.size)
        assertTrue(!result.markdown.contains("qiqi-scene-draft"))
        assertTrue(result.markdown.contains("好的，我已为您梳理了核查要点"))
        assertTrue(result.markdown.contains("点击下方卡片即可保存到工作台"))

        val action = draft.toQuickAction()
        assertNotNull(action)
        assertEquals("custom-lc-audit", action.id)
        assertEquals(true, action.isCustom)
        assertEquals(true, action.opensAttachment)
    }

    @Test
    fun leavesRegularMarkdownUntouched() {
        val input = "这是普通回复\n```json\n{\"a\":1}\n```"
        val result = SceneDraftParser.extract(input)
        assertTrue(result.drafts.isEmpty())
        assertEquals(input, result.markdown)
    }
}
