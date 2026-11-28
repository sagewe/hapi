package app.hapi.companion.feature.assistant

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountBalance
import androidx.compose.material.icons.filled.Badge
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.GppMaybe
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.hapi.protocol.wire.ClientQuickAction
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalTime

/**
 * Design system for standalone 「琪琪工作」 / assistant mode on Android.
 * Mirrors iOS `AssistantDesign.swift` (MyDots warm paper-and-ink neutrals +
 * QiqiWork Emerald Jade accent, restrained single-accent hierarchy).
 */
@Immutable
internal data class AssistantPalette(
    val isDark: Boolean,
    val background: Color,
    val surface: Color,
    val surfaceMuted: Color,
    val border: Color,
    val ink: Color,
    val inkOnSolid: Color,
    val inkSecondary: Color,
    val inkMuted: Color,
    val accent: Color,
    val accentSolidFill: Color,
    val accentSoft: Color,
    val accentBorder: Color,
    val accentGradientStart: Color,
    val accentGradientEnd: Color,
    val risk: Color,
    val report: Color,
) {
    val accentGradient: Brush
        get() = Brush.linearGradient(listOf(accentGradientStart, accentGradientEnd))
}

internal val LightAssistantPalette = AssistantPalette(
    isDark = false,
    background = Color(0xFFF6F6F4),
    surface = Color(0xFFFFFFFF),
    surfaceMuted = Color(0xFFF1F1EE),
    border = Color(0xFFE5E4E0),
    ink = Color(0xFF1C1C1A),
    inkOnSolid = Color(0xFFFFFFFF),
    inkSecondary = Color(0xFF4B4A45),
    inkMuted = Color(0xFF84837D),
    accent = Color(0xFF0F8F76),
    accentSolidFill = Color(0xFF0F8F76),
    accentSoft = Color(0xFFE7F5F1),
    accentBorder = Color(0x420F8F76),
    accentGradientStart = Color(0xFF11977C),
    accentGradientEnd = Color(0xFF0B7460),
    risk = Color(0xFFD97706),
    report = Color(0xFFD1334F),
)

internal val DarkAssistantPalette = AssistantPalette(
    isDark = true,
    background = Color(0xFF111214),
    surface = Color(0xFF1C1D1F),
    surfaceMuted = Color(0xFF26272A),
    border = Color(0xFF323336),
    ink = Color(0xFFF3F3F1),
    inkOnSolid = Color(0xFF111214),
    inkSecondary = Color(0xFFB0AFA8),
    inkMuted = Color(0xFF828387),
    accent = Color(0xFF2CC5A3),
    accentSolidFill = Color(0xFF199076),
    accentSoft = Color(0xFF17332D),
    accentBorder = Color(0x572CC5A3),
    accentGradientStart = Color(0xFF1EA889),
    accentGradientEnd = Color(0xFF14846C),
    risk = Color(0xFFFBBF24),
    report = Color(0xFFFB7185),
)

@Composable
internal fun assistantPalette(): AssistantPalette =
    if (MaterialTheme.colorScheme.surface.luminance() < 0.5f) DarkAssistantPalette else LightAssistantPalette

internal data class AssistantSceneSpec(
    val id: String,
    val kind: Int,
    val title: String,
    val placeholder: String,
    val icon: ImageVector,
    val prompt: String?,
) {
    fun buildMessage(userText: String): String {
        val body = userText.trim().ifEmpty { "请审核所附资料" }
        val instructions = prompt?.trim().orEmpty()
        return if (instructions.isEmpty()) {
            "【调查场景：$title】\n\n$body"
        } else {
            "【调查场景：$title】\n\n$body\n\n<investigation-instructions>\n$instructions\n</investigation-instructions>"
        }
    }
}

internal fun resolveAssistantScenes(quickActions: List<ClientQuickAction>): List<AssistantSceneSpec> {
    if (quickActions.isEmpty()) {
        return defaultAssistantScenes
    }
    return quickActions.map { action ->
        val probe = (action.id + " " + action.title).lowercase()
        val kind = when {
            probe.contains("document") || probe.contains("单据") -> 2
            probe.contains("individual") || probe.contains("自然人") -> 1
            probe.contains("sanction") || probe.contains("制裁") -> 3
            else -> 0
        }
        val base = defaultAssistantScenes[kind]
        base.copy(id = action.id, prompt = action.prompt)
    }
}

internal val defaultAssistantScenes = listOf(
    AssistantSceneSpec(
        id = "company",
        kind = 0,
        title = "企业股权穿透",
        placeholder = "输入公司名称、税号或注册号…",
        icon = Icons.Default.AccountBalance,
        prompt = null,
    ),
    AssistantSceneSpec(
        id = "individual",
        kind = 1,
        title = "自然人核查",
        placeholder = "输入姓名、国籍或关联企业…",
        icon = Icons.Default.Badge,
        prompt = null,
    ),
    AssistantSceneSpec(
        id = "document",
        kind = 2,
        title = "单据审核",
        placeholder = "添加单据，或补充需要核对的内容…",
        icon = Icons.Default.Description,
        prompt = null,
    ),
    AssistantSceneSpec(
        id = "sanctions",
        kind = 3,
        title = "制裁与风险",
        placeholder = "输入主体、国家或交易线索…",
        icon = Icons.Default.GppMaybe,
        prompt = null,
    ),
)

/**
 * Strips `<investigation-instructions>...</investigation-instructions>` suffix
 * from assistant user prompts so iOS and Android render each other's messages cleanly.
 */
internal fun assistantVisibleUserText(text: String): String {
    if (!text.startsWith("【调查场景：")) return text
    val marker = "\n\n<investigation-instructions>"
    val idx = text.indexOf(marker)
    return if (idx >= 0) text.substring(0, idx) else text
}

internal fun assistantGreeting(hour: Int = LocalTime.now().hour): String = when (hour) {
    in 5..10 -> "早上好"
    in 11..13 -> "中午好"
    in 14..17 -> "下午好"
    in 18..22 -> "晚上好"
    else -> "夜深了"
}

internal fun assistantCalmDateCaption(date: LocalDate = LocalDate.now()): String {
    val week = when (date.dayOfWeek) {
        DayOfWeek.MONDAY -> "周一"
        DayOfWeek.TUESDAY -> "周二"
        DayOfWeek.WEDNESDAY -> "周三"
        DayOfWeek.THURSDAY -> "周四"
        DayOfWeek.FRIDAY -> "周五"
        DayOfWeek.SATURDAY -> "周六"
        DayOfWeek.SUNDAY -> "周日"
    }
    return "${date.monthValue}月${date.dayOfMonth}日 · $week"
}

/** MyDots signature asymmetric two-capsule drawer icon (16dp top bar, 10.5dp bottom bar). */
@Composable
internal fun AssistantMenuIcon(
    tint: Color = assistantPalette().ink,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(5.5.dp),
    ) {
        Box(
            Modifier
                .size(width = 16.dp, height = 2.dp)
                .clip(CircleShape)
                .background(tint),
        )
        Box(
            Modifier
                .size(width = 10.5.dp, height = 2.dp)
                .clip(CircleShape)
                .background(tint),
        )
    }
}

/** MyDots signature orbiting ring indicator for running investigation header / drawer / phase card. */
@Composable
internal fun AssistantOrbitingRing(
    color: Color = assistantPalette().accent,
    strokeWidth: Dp = 1.6.dp,
    modifier: Modifier = Modifier.size(14.dp),
) {
    val transition = rememberInfiniteTransition(label = "assistant-orbit")
    val angle by transition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 950, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "assistant-orbit-angle",
    )
    Canvas(modifier) {
        val strokePx = strokeWidth.toPx()
        drawArc(
            color = color.copy(alpha = 0.24f),
            startAngle = 0f,
            sweepAngle = 360f,
            useCenter = false,
            style = Stroke(width = strokePx),
        )
        drawArc(
            color = color,
            startAngle = angle - 90f,
            sweepAngle = 223f,
            useCenter = false,
            style = Stroke(width = strokePx, cap = StrokeCap.Round),
        )
    }
}

internal fun formatByteSize(bytes: Long): String {
    if (bytes < 1024) return "${bytes.coerceAtLeast(1)} B"
    val kb = bytes / 1024.0
    if (kb < 1024.0) return "${kb.toInt().coerceAtLeast(1)} KB"
    val mb = kb / 1024.0
    return String.format(java.util.Locale.US, "%.1f MB", mb)
}
