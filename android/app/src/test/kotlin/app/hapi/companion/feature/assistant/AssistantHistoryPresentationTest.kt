package app.hapi.companion.feature.assistant
import java.time.Instant
import java.time.ZoneId
import kotlin.test.*
class AssistantHistoryPresentationTest {
    private val zone=ZoneId.of("Asia/Shanghai")
    private val now=Instant.parse("2026-11-24T02:00:00Z").toEpochMilli()
    @Test fun historyGroupsUseCalendarDaysInsteadOfElapsed24Hours() {
        assertEquals("今天",historyGroup(now-60000,now,zone))
        assertEquals("近 7 天",historyGroup(now-12*3600000,now,zone))
        assertEquals("更早",historyGroup(now-7*86400000,now,zone))
    }
    @Test fun timeLabelsRespectYesterdayAndUnknownValues() {
        assertEquals("刚刚",historyRelativeTime(now-15000,now,zone))
        assertEquals("12 分钟前",historyRelativeTime(now-12*60000,now,zone))
        assertEquals("昨天",historyRelativeTime(now-12*3600000,now,zone))
        assertEquals("时间未知",historyRelativeTime(0,now,zone))
    }
    @Test fun recordingCounterDoesNotWrapAfterOneHour() {
        assertEquals("00:05",recordingDuration(5));assertEquals("61:01",recordingDuration(3661))
    }
}
