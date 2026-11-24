package app.hapi.companion.feature.assistant
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
internal enum class IncomingCaseRoute { Draft, AskCurrentCase }
internal fun incomingCaseRoute(currentSessionId: String?) = if(currentSessionId.isNullOrBlank()) IncomingCaseRoute.Draft else IncomingCaseRoute.AskCurrentCase
@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun IncomingCaseGuard(files: List<app.hapi.companion.feature.share.SharedFile>,title: String?,newCase: () -> Unit,currentCase: () -> Unit,dismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest=dismiss,containerColor=assistantPaper(),contentColor=MaterialTheme.colorScheme.onSurface) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
            Text("收到分享的 ${files.size} 份资料",style=MaterialTheme.typography.titleLarge)
            files.take(3).forEach { Text("${it.filename} · " + when(it.status) { app.hapi.companion.feature.share.SharedFileStatus.Ready -> "${(it.size / 1024).coerceAtLeast(1)} KB";app.hapi.companion.feature.share.SharedFileStatus.Copying -> "正在读取";else -> "读取失败，请重新分享" },maxLines=2,overflow=androidx.compose.ui.text.style.TextOverflow.Ellipsis,style=MaterialTheme.typography.bodyMedium) }
            if(files.size>3) Text("等共 ${files.size} 份",style=MaterialTheme.typography.bodySmall)
            Button(newCase,Modifier.fillMaxWidth()) { Text("新建尽调送审") }
            OutlinedButton(currentCase,Modifier.fillMaxWidth(),enabled=title!=null && files.all { it.status==app.hapi.companion.feature.share.SharedFileStatus.Ready }) { Text(if(title==null) "正在确认当前案件…" else "补传到「$title」",maxLines=1,overflow=androidx.compose.ui.text.style.TextOverflow.Ellipsis) }
        }
    }
}
