package app.hapi.companion.feature.assistant

import android.Manifest
import android.content.pm.PackageManager
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.GenericShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import app.hapi.companion.di.LocalAppGraph
import app.hapi.companion.feature.chat.composer.appendTranscript
import kotlin.math.abs

internal enum class HoldVoiceZone { SEND, CANCEL, EDIT }

/**
 * Pure geometry resolver matching MyDots / WeChat lower-screen hold-to-dictate:
 * - Drag upward (`dy < -42dp`) and left (`dx < -16dp`) or strong upward drag (`dy < -72dp` & `dx <= 16dp`) -> CANCEL
 * - Drag right (`dx > 28dp`) and upward (`dy < -24dp`) -> EDIT (insert into composer for editing)
 * - Otherwise -> SEND (release to send immediately)
 */
internal fun resolveHoldVoiceZone(dxDp: Float, dyDp: Float): HoldVoiceZone = when {
    dyDp < -24f && dxDp > 28f -> HoldVoiceZone.EDIT
    dyDp < -42f && dxDp < -16f -> HoldVoiceZone.CANCEL
    dyDp < -76f && dxDp <= 16f -> HoldVoiceZone.CANCEL
    else -> HoldVoiceZone.SEND
}

internal class HoldVoiceController(
    val available: Boolean,
    val state: HoldVoiceState,
    val zone: HoldVoiceZone,
    val audioLevels: List<Float>,
    val start: () -> Unit,
    val updateDrag: (dxDp: Float, dyDp: Float) -> Unit,
    val finish: () -> Unit,
    val cancel: () -> Unit,
) {
    val overlayVisible: Boolean get() = state.active || state.finishing
}

@Composable
internal fun rememberHoldVoiceController(
    text: String,
    onTextChange: (String, Int, Int) -> Unit,
    onVoiceSend: (String) -> Unit,
    onVoiceEdit: (String) -> Unit,
): HoldVoiceController {
    val hub = LocalAppGraph.current.activeHubGraph.collectAsState().value
    val context = LocalContext.current
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val latestText = rememberUpdatedState(text)
    val latestChange = rememberUpdatedState(onTextChange)
    val latestSend = rememberUpdatedState(onVoiceSend)
    val latestEdit = rememberUpdatedState(onVoiceEdit)

    var pendingZone by remember { mutableStateOf(HoldVoiceZone.SEND) }
    val pendingZoneState = rememberUpdatedState(pendingZone)

    val controller = remember(hub) {
        hub?.let {
            HoldDictation(
                api = it.session.api,
                scope = scope,
                result = { transcript ->
                    val merged = appendTranscript(latestText.value, transcript)
                    when (pendingZoneState.value) {
                        HoldVoiceZone.EDIT -> {
                            latestChange.value(merged, merged.length, merged.length)
                            latestEdit.value(merged)
                        }
                        HoldVoiceZone.SEND -> {
                            latestChange.value(merged, merged.length, merged.length)
                            latestSend.value(merged)
                        }
                        HoldVoiceZone.CANCEL -> Unit
                    }
                },
                error = { msg -> Toast.makeText(context, msg, Toast.LENGTH_LONG).show() },
            )
        }
    }

    var available by remember(hub) { mutableStateOf(false) }
    LaunchedEffect(hub) {
        available = runCatching { hub?.session?.api?.streamingAsrAvailable() == true }.getOrDefault(false)
    }
    DisposableEffect(controller) { onDispose { controller?.cancel() } }

    val lifecycle = LocalLifecycleOwner.current
    DisposableEffect(controller, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) controller?.cancel()
        }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer) }
    }

    val voice = controller?.state?.collectAsState()?.value ?: HoldVoiceState()
    val levels = remember { mutableStateListOf<Float>().apply { repeat(17) { add(0.14f) } } }
    LaunchedEffect(voice.level, voice.active) {
        if (!voice.active) {
            for (i in levels.indices) levels[i] = 0.14f
        } else {
            levels.removeAt(0)
            levels.add(voice.level.coerceIn(0.10f, 1.0f))
        }
    }

    var zone by remember { mutableStateOf(HoldVoiceZone.SEND) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        Toast.makeText(
            context,
            if (granted) "已允许麦克风，请按住说话" else "请在系统设置中允许琪琪工作使用麦克风",
            Toast.LENGTH_LONG,
        ).show()
    }

    return HoldVoiceController(
        available = available,
        state = voice,
        zone = zone,
        audioLevels = levels.toList(),
        start = {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                zone = HoldVoiceZone.SEND
                pendingZone = HoldVoiceZone.SEND
                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                controller?.start(latestText.value)
            } else {
                permission.launch(Manifest.permission.RECORD_AUDIO)
            }
        },
        updateDrag = { dxDp, dyDp ->
            val next = resolveHoldVoiceZone(dxDp, dyDp)
            if (next != zone) {
                zone = next
                pendingZone = next
                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            }
        },
        finish = {
            val target = zone
            pendingZone = target
            controller?.finish(cancelled = target == HoldVoiceZone.CANCEL)
        },
        cancel = {
            zone = HoldVoiceZone.SEND
            pendingZone = HoldVoiceZone.CANCEL
            controller?.cancel()
        },
    )
}

/**
 * Full-screen MyDots / WeChat Hold-to-Dictate overlay mirroring iOS `WeChatHoldDictationOverlay`:
 * - Translucent paper/charcoal scrim across the full screen.
 * - Floating speech bubble with live streaming transcript + 17-bar audio waveform.
 * - Angled `✕ 取消` (left, -10°) and `文 编辑` (right, +10°) circular zone badges.
 * - Dynamic hint (`松手 发送` / `松开 取消` / `松开 编辑文字` / `正在识别文字…`).
 * - Curved bottom emerald-tinted voice arc pad.
 */
@Composable
internal fun WeChatHoldVoiceOverlay(controller: HoldVoiceController) {
    if (!controller.overlayVisible) return
    val palette = assistantPalette()
    val zone = controller.zone
    val isFinalizing = controller.state.finishing

    val scrimColor = if (palette.isDark) {
        Color.Black.opacity(0.68f)
    } else {
        Color(0xFFF6F6F4).copy(alpha = 0.84f)
    }

    val bubbleBg by animateColorAsState(
        targetValue = when (zone) {
            HoldVoiceZone.SEND -> palette.accentSoft
            HoldVoiceZone.CANCEL -> palette.report.copy(alpha = if (palette.isDark) 0.24f else 0.14f)
            HoldVoiceZone.EDIT -> palette.surface
        },
        label = "voice-bubble-bg",
    )
    val bubbleBorder by animateColorAsState(
        targetValue = when (zone) {
            HoldVoiceZone.SEND -> palette.accent.copy(alpha = if (palette.isDark) 0.44f else 0.34f)
            HoldVoiceZone.CANCEL -> palette.report.copy(alpha = 0.48f)
            HoldVoiceZone.EDIT -> palette.ink.copy(alpha = 0.22f)
        },
        label = "voice-bubble-border",
    )
    val waveformColor by animateColorAsState(
        targetValue = when (zone) {
            HoldVoiceZone.SEND -> palette.accent
            HoldVoiceZone.CANCEL -> palette.report.copy(alpha = 0.86f)
            HoldVoiceZone.EDIT -> palette.inkSecondary
        },
        label = "voice-wave-color",
    )
    val arcBg by animateColorAsState(
        targetValue = when (zone) {
            HoldVoiceZone.SEND -> if (palette.isDark) Color(0xFF173029) else Color(0xFFDEF2EC)
            else -> palette.surfaceMuted
        },
        label = "voice-arc-bg",
    )

    val hintTitle = when {
        isFinalizing -> "正在识别文字…"
        zone == HoldVoiceZone.SEND -> "松手 发送"
        zone == HoldVoiceZone.CANCEL -> "松开 取消"
        else -> "松开 编辑文字"
    }

    Popup(
        alignment = Alignment.BottomCenter,
        properties = PopupProperties(
            focusable = false,
            dismissOnBackPress = false,
            dismissOnClickOutside = false,
            clippingEnabled = false,
        ),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(scrimColor),
            contentAlignment = Alignment.BottomCenter,
        ) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Spacer(Modifier.weight(1f))

                // Speech bubble with live transcript & 17-bar waveform.
                Surface(
                    shape = RoundedCornerShape(22.dp),
                    color = bubbleBg,
                    border = BorderStroke(1.2.dp, bubbleBorder),
                    shadowElevation = 10.dp,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 28.dp)
                        .padding(bottom = 42.dp),
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 96.dp)
                            .padding(horizontal = 20.dp, vertical = 18.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            val partial = controller.state.text
                            val displayText = when {
                                isFinalizing && partial.isBlank() -> "正在识别…"
                                partial.isNotBlank() -> partial
                                else -> "正在聆听…"
                            }
                            val textColor = when {
                                zone == HoldVoiceZone.CANCEL -> palette.report
                                partial.isNotBlank() -> palette.ink
                                else -> palette.inkSecondary
                            }
                            Text(
                                text = displayText,
                                fontSize = if (partial.isNotBlank()) 17.5.sp else 16.5.sp,
                                fontWeight = FontWeight.Medium,
                                lineHeight = 23.sp,
                                color = textColor,
                                maxLines = 6,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f),
                            )
                            if (isFinalizing) {
                                CircularProgressIndicator(
                                    color = waveformColor,
                                    strokeWidth = 2.dp,
                                    modifier = Modifier.size(16.dp),
                                )
                            }
                        }

                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(26.dp),
                            horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            controller.audioLevels.forEachIndexed { i, raw ->
                                val envelope = 1f - abs(i - 8) / 14f
                                val h = (5f + 22f * raw.coerceIn(0.10f, 1.0f) * envelope).dp
                                Box(
                                    modifier = Modifier
                                        .width(3.2.dp)
                                        .height(h)
                                        .clip(CircleShape)
                                        .background(waveformColor.copy(alpha = if (isFinalizing) 0.45f else 0.90f)),
                                )
                            }
                        }
                    }
                }

                // Action badges row: left ✕ 取消 (-10°), right 文 编辑 (+10°).
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 48.dp)
                        .padding(bottom = 18.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    VoiceZoneBadge(
                        title = "✕",
                        subtitle = "取消",
                        active = zone == HoldVoiceZone.CANCEL,
                        activeBg = palette.report,
                        activeFg = Color.White,
                        activeSubtitleColor = palette.report,
                        angle = -10f,
                    )
                    VoiceZoneBadge(
                        title = "文",
                        subtitle = "编辑",
                        active = zone == HoldVoiceZone.EDIT,
                        activeBg = palette.ink,
                        activeFg = palette.inkOnSolid,
                        activeSubtitleColor = palette.ink,
                        angle = 10f,
                    )
                }

                Text(
                    text = hintTitle,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = if (zone == HoldVoiceZone.CANCEL) palette.report else palette.inkSecondary,
                    modifier = Modifier.padding(bottom = 14.dp),
                )

                // Curved bottom arc pad.
                val arcShape = remember {
                    GenericShape { size, _ ->
                        moveTo(0f, size.height * 0.28f)
                        quadraticTo(size.width * 0.5f, -size.height * 0.14f, size.width, size.height * 0.28f)
                        lineTo(size.width, size.height)
                        lineTo(0f, size.height)
                        close()
                    }
                }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(104.dp)
                        .clip(arcShape)
                        .background(arcBg)
                        .navigationBarsPadding(),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Default.GraphicEq,
                        contentDescription = null,
                        tint = if (zone == HoldVoiceZone.SEND) palette.accent else palette.inkMuted,
                        modifier = Modifier
                            .padding(top = 12.dp)
                            .size(28.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun VoiceZoneBadge(
    title: String,
    subtitle: String,
    active: Boolean,
    activeBg: Color,
    activeFg: Color,
    activeSubtitleColor: Color,
    angle: Float,
) {
    val palette = assistantPalette()
    val size by animateDpAsState(
        targetValue = if (active) 68.dp else 56.dp,
        animationSpec = spring(dampingRatio = 0.82f, stiffness = Spring.StiffnessMedium),
        label = "voice-badge-size",
    )
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Surface(
            shape = CircleShape,
            color = if (active) activeBg else palette.surface.copy(alpha = 0.94f),
            border = if (active) null else BorderStroke(0.8.dp, palette.border),
            shadowElevation = if (active) 8.dp else 3.dp,
            modifier = Modifier.size(size),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Text(
                    text = title,
                    fontSize = if (active) 22.sp else 18.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = if (active) activeFg else palette.inkSecondary,
                    modifier = Modifier.rotate(angle),
                )
            }
        }
        Text(
            text = subtitle,
            fontSize = 12.5.sp,
            fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
            color = if (active) activeSubtitleColor else palette.inkSecondary,
        )
    }
}

private fun Color.opacity(alpha: Float): Color = copy(alpha = alpha)
