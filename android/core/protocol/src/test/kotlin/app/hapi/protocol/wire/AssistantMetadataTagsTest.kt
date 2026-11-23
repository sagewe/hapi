package app.hapi.protocol.wire
import kotlin.test.*
class AssistantMetadataTagsTest {
    @Test fun openingSessionDetailMustNotEraseHistoryTags() {
        val full=HapiJson.decodeFromString<SessionMetadata>("""{"path":"/qa","host":"qa","tags":["部署验收","多标签不折行","单据审核"]}""")
        assertEquals(listOf("部署验收","多标签不折行","单据审核"),SummaryPatching.toSessionSummaryMetadata(full)?.tags)
    }
    @Test fun tagOnlyChangesAreVisibleToSummaryObservers() {
        val old=SessionSummaryMetadata(path="/qa",tags=listOf("旧标签"))
        assertFalse(SummaryPatching.sameSessionSummaryMetadata(old,old.copy(tags=listOf("新标签"))))
    }
}
