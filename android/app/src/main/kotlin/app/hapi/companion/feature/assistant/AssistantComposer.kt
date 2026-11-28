package app.hapi.companion.feature.assistant

import android.widget.Toast
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalMinimumInteractiveComponentSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.hapi.companion.feature.chat.composer.DictationState
import app.hapi.protocol.wire.ClientModelPreset
import coil.compose.AsyncImage
import kotlinx.coroutines.delay

@Composable
internal fun assistantPaper(): Color = assistantPalette().surface

data class AssistantAttachment(
    val id: String,
    val filename: String,
    val mime: String,
    val thumbnail: Any? = null,
    val status: String? = null,
    val sizeBytes: Long? = null,
)

/**
 * Single compact mode capsule (`✦ 深度` ↔ `⚡ 快速`) inside the composer bottom-left tool row,
 * matching iOS `AssistantPresetCapsule`. Tapping cycles to the alternate preset.
 */
@Composable
fun AssistantPresetSwitch(
    presets: List<ClientModelPreset>,
    selected: (ClientModelPreset) -> Boolean,
    onSelect: (ClientModelPreset) -> Unit,
    enabled: Boolean = true,
) {
    if (presets.isEmpty()) return
    val palette = assistantPalette()
    val current = presets.firstOrNull(selected)
        ?: presets.firstOrNull { it.isDefault }
        ?: presets.first()
    val isDeep = current.label != "快速"

    Surface(
        onClick = {
            if (presets.size > 1) {
                val idx = presets.indexOfFirst { it.id == current.id }.coerceAtLeast(0)
                onSelect(presets[(idx + 1) % presets.size])
            }
        },
        enabled = enabled && presets.size > 1,
        shape = CircleShape,
        color = if (isDeep) palette.accentSoft else palette.surfaceMuted,
        border = BorderStroke(0.5.dp, if (isDeep) palette.accentBorder else palette.border),
        modifier = Modifier.height(32.dp),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.5.dp),
        ) {
            Icon(
                imageVector = if (isDeep) Icons.Default.AutoAwesome else Icons.Default.Bolt,
                contentDescription = null,
                tint = if (isDeep) palette.accent else palette.inkSecondary,
                modifier = Modifier.size(12.dp),
            )
            Text(
                text = current.label,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (isDeep) palette.accent else palette.inkSecondary,
                maxLines = 1,
                softWrap = false,
            )
        }
    }
}

@Composable
internal fun PulseDot(color: Color, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "recording-pulse")
    val alpha by transition.animateFloat(
        initialValue = 0.35f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(800), RepeatMode.Reverse),
        label = "pulse-alpha",
    )
    Box(modifier.size(8.dp).background(color.copy(alpha = alpha), CircleShape))
}

@Composable
fun AssistantRecordingPanel(startedAt: Long, onCancel: () -> Unit, onComplete: () -> Unit) {
    val palette = assistantPalette()
    var seconds by remember(startedAt) { mutableLongStateOf(0L) }
    LaunchedEffect(startedAt) {
        while (true) {
            seconds = ((System.currentTimeMillis() - startedAt) / 1000).coerceAtLeast(0)
            delay(250)
        }
    }
    Surface(
        color = palette.report.copy(alpha = 0.14f),
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.padding(horizontal = 6.dp, vertical = 4.dp),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(start = 12.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PulseDot(palette.report)
            Text(
                text = "录音中 ${recordingDuration(seconds)}",
                modifier = Modifier
                    .padding(start = 8.dp)
                    .weight(1f),
                fontSize = 13.sp,
                color = palette.ink,
            )
            TextButton(onCancel) { Text("取消", color = palette.inkSecondary) }
            TextButton(onComplete) { Text("完成转写", color = palette.accent) }
        }
    }
}

internal fun recordingDuration(seconds: Long) = "%02d:%02d".format(seconds / 60, seconds % 60)

/**
 * Floating frosted-paper composer aligned with iOS `AssistantDraftComposer`:
 * - Clean `24.dp` card with hairline border (`accentBorder` when focused) and soft shadow.
 * - Top: optional selected scene chip + compact attachment strip (`48.dp` thumbnails / file cards).
 * - Text input (`16.sp`); holding the voice circle (or holding empty input) opens the full-screen
 *   WeChat/MyDots Hold-to-Dictate overlay.
 * - Bottom tool row: `+` attach + single compact `✦ 深度`/`⚡ 快速` capsule + hold-to-dictate voice
 *   circle + solid-ink send (or stop) circle.
 */
@Composable
fun AssistantComposer(
    text: String,
    onTextChange: (String, Int, Int) -> Unit,
    onSend: () -> Unit,
    onAdd: () -> Unit,
    onMic: () -> Unit,
    onCancelRecording: () -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    attachments: List<AssistantAttachment> = emptyList(),
    onRemove: (String) -> Unit = {},
    onRetry: (String) -> Unit = {},
    busy: Boolean = false,
    running: Boolean = false,
    onStop: () -> Unit = {},
    dictation: DictationState? = null,
    caretPosition: Int = -1,
    focusRequestKey: Int = 0,
    onFocusChanged: (Boolean) -> Unit = {},
    onVoiceOverlayActiveChanged: (Boolean) -> Unit = {},
    leading: @Composable () -> Unit = {},
    presets: @Composable () -> Unit = {},
) {
    val palette = assistantPalette()
    val context = LocalContext.current
    val density = LocalDensity.current
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val focusRequester = remember { FocusRequester() }
    var focused by remember { mutableStateOf(false) }

    val holdVoice = rememberHoldVoiceController(
        text = text,
        onTextChange = onTextChange,
        onVoiceSend = { _ -> onSend() },
        onVoiceEdit = {
            runCatching { focusRequester.requestFocus() }
            keyboard?.show()
        },
    )

    LaunchedEffect(holdVoice.overlayVisible) {
        onVoiceOverlayActiveChanged(holdVoice.overlayVisible)
    }
    LaunchedEffect(focusRequestKey) {
        if (focusRequestKey > 0) {
            runCatching { focusRequester.requestFocus() }
            keyboard?.show()
        }
    }

    var field by remember { mutableStateOf(TextFieldValue(text)) }
    LaunchedEffect(text) {
        if (field.text != text) {
            field = TextFieldValue(
                text = text,
                selection = TextRange(
                    if (caretPosition >= 0) caretPosition.coerceIn(0, text.length) else text.length,
                ),
            )
        }
    }

    val idle = dictation == null || dictation == DictationState.Idle
    LaunchedEffect(busy) { if (busy) holdVoice.cancel() }

    val hasDraft = text.isNotBlank() || attachments.isNotEmpty()
    val canSend = hasDraft && !busy && idle && !holdVoice.overlayVisible && attachments.none { it.status != null }
    val showSendOrStop = hasDraft || running || busy
    val resolvedPlaceholder = placeholder ?: if (!focused && holdVoice.available) {
        "可按住说话，或输入线索…"
    } else {
        "输入调查线索，或添加单据…"
    }

    Surface(
        modifier = modifier.fillMaxWidth(),
        color = palette.surface,
        shape = RoundedCornerShape(24.dp),
        border = BorderStroke(
            width = if (focused) 1.dp else 0.7.dp,
            color = if (focused) palette.accentBorder else palette.border,
        ),
        shadowElevation = if (palette.isDark) 8.dp else 4.dp,
    ) {
        CompositionLocalProvider(LocalMinimumInteractiveComponentSize provides 36.dp) {
            Column(
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 7.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                leading()

                if (attachments.isNotEmpty()) {
                    LazyRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 4.dp, vertical = 2.dp),
                    ) {
                        items(attachments, key = { it.id }) { item ->
                            AssistantAttachmentChip(
                                item = item,
                                busy = busy,
                                onRetry = { onRetry(item.id) },
                                onRemove = { onRemove(item.id) },
                            )
                        }
                    }
                }

                if (dictation is DictationState.Recording) {
                    AssistantRecordingPanel(dictation.startedAtMs, onCancelRecording, onMic)
                }
                if (dictation == DictationState.Starting || dictation == DictationState.Transcribing) {
                    Row(
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        CircularProgressIndicator(
                            color = palette.accent,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(14.dp),
                        )
                        Text(
                            text = if (dictation == DictationState.Starting) "正在准备录音…" else "正在转写，请稍候…",
                            fontSize = 12.sp,
                            color = palette.inkMuted,
                            modifier = Modifier.padding(start = 8.dp),
                        )
                    }
                }

                // Input field: tap to focus keyboard; long-press on empty unfocused field triggers hold-to-dictate.
                val holdOnFieldModifier = if (holdVoice.available && text.isEmpty() && !focused && !busy) {
                    Modifier.pointerInput(holdVoice.available, density) {
                        var dx = 0f
                        var dy = 0f
                        detectDragGesturesAfterLongPress(
                            onDragStart = {
                                dx = 0f
                                dy = 0f
                                focusManager.clearFocus(force = true)
                                keyboard?.hide()
                                holdVoice.start()
                            },
                            onDrag = { change, amount ->
                                change.consume()
                                dx += amount.x
                                dy += amount.y
                                holdVoice.updateDrag(dx / density.density, dy / density.density)
                            },
                            onDragEnd = { holdVoice.finish() },
                            onDragCancel = { holdVoice.cancel() },
                        )
                    }
                } else {
                    Modifier
                }

                BasicTextField(
                    value = field,
                    onValueChange = { value ->
                        field = value
                        onTextChange(value.text, value.selection.start, value.selection.end)
                    },
                    enabled = !busy,
                    maxLines = 6,
                    textStyle = TextStyle(
                        fontSize = 16.sp,
                        lineHeight = 22.sp,
                        color = palette.ink,
                    ),
                    cursorBrush = SolidColor(palette.accent),
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 32.dp)
                        .padding(horizontal = 10.dp, vertical = 6.dp)
                        .focusRequester(focusRequester)
                        .onFocusChanged { st ->
                            if (focused != st.isFocused) {
                                focused = st.isFocused
                                onFocusChanged(st.isFocused)
                            }
                        }
                        .then(holdOnFieldModifier),
                    decorationBox = { inner ->
                        Box(contentAlignment = Alignment.TopStart) {
                            if (text.isEmpty()) {
                                Text(
                                    text = resolvedPlaceholder,
                                    fontSize = 16.sp,
                                    color = palette.inkMuted,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            inner()
                        }
                    },
                )

                // Bottom tool row: + attach | mode capsule | spacer | voice circle | send/stop circle
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .clickable(enabled = !busy, onClick = onAdd),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Default.Add,
                            contentDescription = "添加图片或文件",
                            tint = palette.ink,
                            modifier = Modifier.size(22.dp),
                        )
                    }

                    presets()

                    Spacer(Modifier.weight(1f))

                    if (holdVoice.available) {
                        val compact = showSendOrStop
                        val holding = holdVoice.overlayVisible
                        Box(
                            modifier = Modifier
                                .size(36.dp)
                                .clip(CircleShape)
                                .then(
                                    if (holding) {
                                        Modifier.background(palette.accentGradient)
                                    } else if (!compact) {
                                        Modifier.background(palette.ink)
                                    } else {
                                        Modifier.background(palette.surfaceMuted)
                                    },
                                )
                                .pointerInput(holdVoice.available, busy, density) {
                                    if (busy) return@pointerInput
                                    var dx = 0f
                                    var dy = 0f
                                    detectDragGesturesAfterLongPress(
                                        onDragStart = {
                                            dx = 0f
                                            dy = 0f
                                            focusManager.clearFocus(force = true)
                                            keyboard?.hide()
                                            holdVoice.start()
                                        },
                                        onDrag = { change, amount ->
                                            change.consume()
                                            dx += amount.x
                                            dy += amount.y
                                            holdVoice.updateDrag(dx / density.density, dy / density.density)
                                        },
                                        onDragEnd = { holdVoice.finish() },
                                        onDragCancel = { holdVoice.cancel() },
                                    )
                                }
                                .pointerInput(busy) {
                                    if (busy) return@pointerInput
                                    detectTapGestures(
                                        onTap = {
                                            Toast.makeText(
                                                context,
                                                "按住输入框或右侧语音键即可说话",
                                                Toast.LENGTH_SHORT,
                                            ).show()
                                        },
                                    )
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = if (holding || !compact) Icons.Default.GraphicEq else Icons.Default.Mic,
                                contentDescription = "按住说话",
                                tint = when {
                                    holding -> Color.White
                                    !compact -> palette.inkOnSolid
                                    else -> palette.inkSecondary
                                },
                                modifier = Modifier.size(if (compact) 17.dp else 18.dp),
                            )
                        }
                    } else if (dictation != null && dictation !is DictationState.Recording) {
                        Surface(
                            onClick = onMic,
                            enabled = idle && !busy,
                            shape = CircleShape,
                            color = if (showSendOrStop) palette.surfaceMuted else palette.ink,
                            modifier = Modifier.size(36.dp),
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(
                                    imageVector = Icons.Default.Mic,
                                    contentDescription = "语音听写",
                                    tint = if (showSendOrStop) palette.inkSecondary else palette.inkOnSolid,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                        }
                    }

                    AnimatedVisibility(
                        visible = showSendOrStop,
                        enter = scaleIn(initialScale = 0.85f) + fadeIn(),
                        exit = scaleOut(targetScale = 0.85f) + fadeOut(),
                    ) {
                        if (busy) {
                            Box(
                                modifier = Modifier
                                    .size(36.dp)
                                    .clip(CircleShape)
                                    .background(palette.ink),
                                contentAlignment = Alignment.Center,
                            ) {
                                CircularProgressIndicator(
                                    color = palette.inkOnSolid,
                                    strokeWidth = 2.dp,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                        } else {
                            val isStop = running && !hasDraft
                            val enabled = isStop || canSend
                            Surface(
                                onClick = { if (isStop) onStop() else onSend() },
                                enabled = enabled,
                                shape = CircleShape,
                                color = when {
                                    isStop -> palette.report
                                    enabled -> palette.ink
                                    else -> palette.surfaceMuted
                                },
                                modifier = Modifier.size(36.dp),
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Icon(
                                        imageVector = if (isStop) Icons.Default.Stop else Icons.Default.ArrowUpward,
                                        contentDescription = if (isStop) "停止调查" else "发送调查",
                                        tint = when {
                                            isStop -> Color.White
                                            enabled -> palette.inkOnSolid
                                            else -> palette.inkMuted.copy(alpha = 0.65f)
                                        },
                                        modifier = Modifier.size(18.dp),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    WeChatHoldVoiceOverlay(holdVoice)
}

@Composable
private fun AssistantAttachmentChip(
    item: AssistantAttachment,
    busy: Boolean,
    onRetry: () -> Unit,
    onRemove: () -> Unit,
) {
    val palette = assistantPalette()
    if (item.thumbnail != null && item.status == null) {
        Box(modifier = Modifier.padding(top = 4.dp, end = 4.dp)) {
            AsyncImage(
                model = item.thumbnail,
                contentDescription = "图片附件",
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(48.dp)
                    .clip(RoundedCornerShape(11.dp))
                    .background(palette.surfaceMuted),
            )
            Surface(
                onClick = onRemove,
                enabled = !busy,
                shape = CircleShape,
                color = Color.Black.copy(alpha = 0.65f),
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .offset(x = 4.dp, y = (-4).dp)
                    .size(18.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = "移除 ${item.filename}",
                        tint = Color.White,
                        modifier = Modifier.size(11.dp),
                    )
                }
            }
        }
    } else {
        val ext = item.filename.substringAfterLast('.', "").uppercase().let {
            when {
                it.isEmpty() -> "文件"
                it == "DOCX" -> "DOC"
                it == "XLSX" -> "XLS"
                else -> it.take(4)
            }
        }
        val subtitle = item.status ?: buildString {
            append(ext)
            item.sizeBytes?.let { append(" · "); append(formatByteSize(it)) }
        }
        Surface(
            onClick = { if (item.status != null) onRetry() },
            shape = RoundedCornerShape(12.dp),
            color = if (item.status != null) palette.report.copy(alpha = 0.08f) else palette.surface,
            border = BorderStroke(0.5.dp, if (item.status != null) palette.report.copy(alpha = 0.4f) else palette.border),
        ) {
            Row(
                modifier = Modifier
                    .height(48.dp)
                    .padding(horizontal = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FormatBadge(item.filename, item.mime, compact = true)
                Column(modifier = Modifier.widthIn(max = 136.dp)) {
                    Text(
                        text = item.filename,
                        fontSize = 12.5.sp,
                        fontWeight = FontWeight.Medium,
                        color = palette.ink,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = subtitle,
                        fontSize = 10.5.sp,
                        color = if (item.status != null) palette.report else palette.inkMuted,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Surface(
                    onClick = onRemove,
                    enabled = !busy,
                    shape = CircleShape,
                    color = palette.surfaceMuted,
                    modifier = Modifier.size(22.dp),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(
                            imageVector = Icons.Default.Close,
                            contentDescription = "移除附件",
                            tint = palette.inkMuted,
                            modifier = Modifier.size(12.dp),
                        )
                    }
                }
            }
        }
    }
}
