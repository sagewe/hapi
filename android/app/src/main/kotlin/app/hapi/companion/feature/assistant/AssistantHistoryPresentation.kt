package app.hapi.companion.feature.assistant
import java.time.Instant
import java.time.ZoneId
internal fun historyGroup(at: Long, now: Long, zone: ZoneId = ZoneId.systemDefault()): String {
    if(at<=0) return "更早"
    val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
    val date = Instant.ofEpochMilli(at).atZone(zone).toLocalDate()
    val days = java.time.temporal.ChronoUnit.DAYS.between(date,today)
    return when { days <= 0 -> "今天"; days <= 6 -> "近 7 天"; else -> "更早" }
}
internal fun historyRelativeTime(at: Long, now: Long, zone: ZoneId = ZoneId.systemDefault()): String {
    if(at<=0) return "时间未知"
    val minutes = ((now-at)/60000).coerceAtLeast(0)
    val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
    val date = Instant.ofEpochMilli(at).atZone(zone).toLocalDate()
    val days = java.time.temporal.ChronoUnit.DAYS.between(date,today)
    return when { minutes < 1 -> "刚刚"; days == 1L -> "昨天"; days >= 2 -> if(days < 7) "${days} 天前" else date.format(java.time.format.DateTimeFormatter.ofPattern("M月d日")); minutes < 60 -> "${minutes} 分钟前"; else -> "${minutes/60} 小时前" }
}
