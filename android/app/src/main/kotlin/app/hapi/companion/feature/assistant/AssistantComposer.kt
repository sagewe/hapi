package app.hapi.companion.feature.assistant

import androidx.compose.animation.core.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.hapi.companion.feature.chat.composer.DictationState
import app.hapi.protocol.wire.ClientModelPreset
import coil.compose.AsyncImage
import kotlinx.coroutines.delay

@Composable internal fun assistantPaper(): Color = if(MaterialTheme.colorScheme.surface.luminance() < .5f) Color(0xFF1C1E23) else Color(0xFFFFFCF8)

data class AssistantAttachment(val id: String, val filename: String, val mime: String, val thumbnail: Any? = null, val status: String? = null)

@Composable fun AssistantPresetSwitch(presets: List<ClientModelPreset>, selected: (ClientModelPreset) -> Boolean, onSelect: (ClientModelPreset) -> Unit, enabled: Boolean = true) {
    if(presets.isEmpty()) return
    Surface(shape = CircleShape, color = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Row(Modifier.padding(3.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            presets.take(2).forEachIndexed { index, preset ->
                val active = selected(preset)
                Surface(onClick = { onSelect(preset) }, enabled = enabled, shape = CircleShape,
                    color = if(active) MaterialTheme.colorScheme.surface else Color.Transparent,
                    contentColor = if(active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    shadowElevation = if(active) 1.dp else 0.dp) {
                    Row(Modifier.padding(horizontal = 9.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                        Icon(if(index == 0) Icons.Default.Bolt else Icons.Default.AutoAwesome, null, Modifier.size(14.dp))
                        Text(preset.label, fontSize = 12.sp, maxLines = 1, softWrap = false)
                    }
                }
            }
        }
    }
}

@Composable internal fun PulseDot(color: Color, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "recording-pulse")
    val alpha by transition.animateFloat(.35f,1f,infiniteRepeatable(tween(800),RepeatMode.Reverse),label = "pulse-alpha")
    Box(modifier.size(8.dp).background(color.copy(alpha = alpha), CircleShape))
}

@Composable fun AssistantRecordingPanel(startedAt: Long, onCancel: () -> Unit, onComplete: () -> Unit) {
    var seconds by remember(startedAt) { mutableLongStateOf(0L) }
    LaunchedEffect(startedAt) { while(true) { seconds = ((System.currentTimeMillis()-startedAt)/1000).coerceAtLeast(0); delay(250) } }
    Surface(color = MaterialTheme.colorScheme.errorContainer.copy(alpha = .35f), shape = RoundedCornerShape(12.dp)) {
        Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            PulseDot(MaterialTheme.colorScheme.error)
            Text("录音中 ${recordingDuration(seconds)}", Modifier.padding(start = 8.dp).weight(1f), style = MaterialTheme.typography.labelMedium)
            TextButton(onCancel) { Text("取消") }
            TextButton(onComplete) { Text("完成转写") }
        }
    }
}
internal fun recordingDuration(seconds: Long) = "%02d:%02d".format(seconds / 60, seconds % 60)

@Composable fun AssistantComposer(
    text: String, onTextChange: (String, Int, Int) -> Unit, onSend: () -> Unit,
    onAdd: () -> Unit, onMic: () -> Unit, onCancelRecording: () -> Unit,
    modifier: Modifier = Modifier, placeholder: String = "输入调查对象或补充线索",
    attachments: List<AssistantAttachment> = emptyList(), onRemove: (String) -> Unit = {},
    onRetry: (String) -> Unit = {}, busy: Boolean = false, running: Boolean = false, onStop: () -> Unit = {},
    dictation: DictationState? = null, caretPosition: Int = -1,
    leading: @Composable () -> Unit = {}, presets: @Composable () -> Unit = {},
) {
    var field by remember { mutableStateOf(TextFieldValue(text)) }
    LaunchedEffect(text) { if(field.text != text) field = TextFieldValue(text,TextRange(if(caretPosition >= 0) caretPosition.coerceIn(0,text.length) else text.length)) }
    val idle = dictation == null || dictation == DictationState.Idle
    val hasDraft = text.isNotBlank() || attachments.isNotEmpty()
    val canSend = hasDraft && !busy && idle && attachments.none { it.status != null }
    Surface(modifier.fillMaxWidth(), color = assistantPaper(), shape = RoundedCornerShape(22.dp),
        border = BorderStroke(.5.dp,MaterialTheme.colorScheme.outlineVariant), tonalElevation = 1.dp, shadowElevation = 1.dp) {
        CompositionLocalProvider(LocalMinimumInteractiveComponentSize provides 44.dp) {
            Column(Modifier.padding(10.dp)) {
                leading()
                if(attachments.isNotEmpty()) LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth().padding(bottom = 6.dp)) {
                    items(attachments,key = { it.id }) { item ->
                        Surface(onClick = { if(item.status != null) onRetry(item.id) }, shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = .65f)) {
                            Row(Modifier.padding(6.dp).widthIn(max = 190.dp), verticalAlignment = Alignment.CenterVertically) {
                                if(item.thumbnail != null) AsyncImage(model = item.thumbnail, contentDescription = "图片附件", contentScale = ContentScale.Crop, modifier = Modifier.size(36.dp))
                                else FormatBadge(item.filename,item.mime)
                                Column(Modifier.padding(horizontal = 8.dp).weight(1f,fill = false)) { Text(item.filename,maxLines = 1,overflow = TextOverflow.Ellipsis,style = MaterialTheme.typography.labelMedium); item.status?.let { Text(it,style=MaterialTheme.typography.labelSmall) } }
                                IconButton({ onRemove(item.id) },Modifier.size(28.dp), enabled = !busy) { Icon(Icons.Default.Close,"移除附件",Modifier.size(16.dp)) }
                            }
                        }
                    }
                }
                if(dictation is DictationState.Recording) AssistantRecordingPanel(dictation.startedAtMs,onCancelRecording,onMic)
                if(dictation == DictationState.Starting || dictation == DictationState.Transcribing) Row(Modifier.padding(8.dp),verticalAlignment=Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(14.dp),strokeWidth=2.dp); Text(if(dictation == DictationState.Starting) "正在准备录音…" else "正在转写，请稍候…",Modifier.padding(start=8.dp),style=MaterialTheme.typography.labelMedium)
                }
                BasicTextField(value = field, onValueChange = { value -> field = value; onTextChange(value.text,value.selection.start,value.selection.end) }, enabled = !busy,
                    maxLines = 6, textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface), cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 5.dp,vertical = 12.dp), decorationBox = { inner -> Box { if(text.isEmpty()) Text(placeholder,color=MaterialTheme.colorScheme.onSurfaceVariant,style=MaterialTheme.typography.bodyLarge); inner() } })
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    AssistantCircleAction(Icons.Default.Add,"添加资料",onAdd,enabled = !busy)
                    presets()
                    Spacer(Modifier.weight(1f))
                    if(dictation != null && dictation !is DictationState.Recording) AssistantCircleAction(Icons.Default.Mic,"语音听写",onMic,enabled = idle && !busy)
                    if(busy) Box(Modifier.size(44.dp),contentAlignment=Alignment.Center) { CircularProgressIndicator(Modifier.size(22.dp),strokeWidth=2.dp) }
                    else AssistantCircleAction(if(running && !hasDraft) Icons.Default.Stop else Icons.Default.ArrowUpward,
                        if(running && !hasDraft) "停止调查" else "发送", if(running && !hasDraft) onStop else onSend,
                        enabled = running && !hasDraft || canSend, primary = true, danger = running && !hasDraft)
                }
            }
        }
    }
}
@Composable private fun AssistantCircleAction(icon: ImageVector, label: String, onClick: () -> Unit, enabled: Boolean = true, primary: Boolean = false, danger: Boolean = false) {
    FilledIconButton(onClick,Modifier.size(44.dp),enabled=enabled,colors=IconButtonDefaults.filledIconButtonColors(
        containerColor = if(danger) MaterialTheme.colorScheme.error else if(primary) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceContainerHigh,
        contentColor = if(primary) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant,
        disabledContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha=.55f),disabledContentColor=MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha=.35f))) { Icon(icon,label,Modifier.size(22.dp)) }
}
