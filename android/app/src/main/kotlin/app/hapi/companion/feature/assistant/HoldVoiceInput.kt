package app.hapi.companion.feature.assistant

import android.Manifest
import android.content.pm.PackageManager
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import app.hapi.companion.di.LocalAppGraph

internal class HoldVoiceAccess(val available: Boolean,val active: Boolean,val input: @Composable ()->Unit,val cancel: ()->Unit)

@Composable internal fun rememberHoldVoice(text: String,onTextChange: (String,Int,Int)->Unit): HoldVoiceAccess {
    val hub=LocalAppGraph.current.activeHubGraph.collectAsState().value
    val context=LocalContext.current
    val scope=rememberCoroutineScope()
    val latestText=rememberUpdatedState(text)
    val latestChange=rememberUpdatedState(onTextChange)
    val controller=remember(hub) { hub?.let { HoldDictation(it.session.api,scope,{ transcript ->
        val next=app.hapi.companion.feature.chat.composer.appendTranscript(latestText.value,transcript);latestChange.value(next,next.length,next.length)
    },{Toast.makeText(context,it,Toast.LENGTH_LONG).show()}) } }
    var available by remember(hub) { mutableStateOf(false) }
    LaunchedEffect(hub) { available=runCatching { hub?.session?.api?.streamingAsrAvailable()==true }.getOrDefault(false) }
    DisposableEffect(controller) { onDispose { controller?.cancel() } }
    val lifecycle=androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(controller,lifecycle) {
        val observer=androidx.lifecycle.LifecycleEventObserver { _,event -> if(event==androidx.lifecycle.Lifecycle.Event.ON_STOP) controller?.cancel() }
        lifecycle.lifecycle.addObserver(observer);onDispose { lifecycle.lifecycle.removeObserver(observer) }
    }
    val voice=controller?.state?.collectAsState()?.value ?: HoldVoiceState()
    var cancelGesture by remember { mutableStateOf(false) }
    val permission=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted -> Toast.makeText(context,if(granted) "已允许麦克风，请按住说话" else "请在系统设置中允许琪琪工作使用麦克风",Toast.LENGTH_LONG).show() }
    return HoldVoiceAccess(available,voice.active || voice.finishing,{
        Surface(shape=RoundedCornerShape(14.dp),color=MaterialTheme.colorScheme.surfaceContainerHigh,modifier=Modifier.fillMaxWidth().padding(vertical=8.dp).pointerInput(controller) {
            var dy=0f
            detectDragGesturesAfterLongPress(onDragStart={
                dy=0f;cancelGesture=false
                if(ContextCompat.checkSelfPermission(context,Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED) controller?.start(latestText.value) else permission.launch(Manifest.permission.RECORD_AUDIO)
            },onDrag={ change,amount -> change.consume();dy+=amount.y;cancelGesture=dy < -64.dp.toPx() },onDragEnd={controller?.finish(cancelGesture)},onDragCancel={controller?.cancel()})
        }) { Box(Modifier.heightIn(min=64.dp).padding(12.dp),contentAlignment=Alignment.Center) { Text(if(voice.finishing) "正在转写…" else "按住说话 · 松手填入草稿",style=MaterialTheme.typography.bodyLarge) } }
        HoldVoiceOverlay(voice,cancelGesture)
    },{controller?.cancel()})
}

@Composable internal fun HoldVoiceOverlay(voice: HoldVoiceState,cancelGesture: Boolean) {
        if(voice.active || voice.finishing) Popup(alignment=Alignment.Center,properties=PopupProperties(focusable=false)) {
            Surface(shape=RoundedCornerShape(28.dp),color=if(cancelGesture) MaterialTheme.colorScheme.errorContainer.copy(alpha=.97f) else MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha=.97f),shadowElevation=12.dp,modifier=Modifier.fillMaxWidth(.88f)) {
                Column(Modifier.padding(24.dp),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(20.dp)) {
                    Text(if(cancelGesture) "松手取消" else if(voice.finishing) "正在整理文字…" else "正在聆听",style=MaterialTheme.typography.titleMedium)
                    Row(horizontalArrangement=Arrangement.spacedBy(5.dp),verticalAlignment=Alignment.CenterVertically,modifier=Modifier.height(52.dp)) {
                        repeat(17) { i -> Box(Modifier.width(4.dp).height((8+voice.level*44*(1f-kotlin.math.abs(i-8)/12f)).dp).background(if(cancelGesture) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,RoundedCornerShape(4.dp))) }
                    }
                    Text(voice.text.ifBlank { "说出调查对象或核验重点" },style=MaterialTheme.typography.bodyLarge,maxLines=6)
                    Text(if(cancelGesture) "↑ 已进入取消区" else "↑ 上滑取消     松手填入草稿",style=MaterialTheme.typography.labelMedium)
                }
            }
        }
}
