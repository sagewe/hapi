package app.hapi.companion.feature.chat
import app.hapi.protocol.chat.*
import kotlin.test.*
class AssistantStageTest {
    private fun summary(running: Int) = ToolGroupSummary(7, mapOf(ToolGroupActionKind.SEARCH to 7), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), 0, running, 0)
    @Test fun compactRunningGroupUsesAuthoritativeSummary() {
        assertEquals("正在检索公开线索…", assistantStageText(emptyList(), summary(2)))
    }
    @Test fun compactCompletedGroupRetainsStepCount() {
        assertEquals("已完成 7 步查证", assistantStageText(emptyList(), summary(0)))
        assertNull(assistantStageText(emptyList()))
    }
}
