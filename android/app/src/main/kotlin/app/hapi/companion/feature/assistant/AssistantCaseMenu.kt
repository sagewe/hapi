package app.hapi.companion.feature.assistant
import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.FileProvider
import app.hapi.companion.di.LocalAppGraph
import app.hapi.protocol.wire.SessionReadStateRequest
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import app.hapi.protocol.wire.HapiJson
import java.io.File

@Composable fun AssistantCaseMenu(sessionId: String, title: String, onDelete: () -> Unit) {
    val hub = LocalAppGraph.current.activeHubGraph.value ?: return
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val navigation = AssistantNavigation.current
    var open by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var name by remember(title) { mutableStateOf(title) }
    val summary = hub.sessionStore.sessions.collectAsState().value.find { it.id == sessionId }
    var tags by remember(summary?.metadata?.tags) { mutableStateOf(summary?.metadata?.tags.orEmpty().joinToString("，")) }
    var failure by remember { mutableStateOf<String?>(null) }
    fun action(block: suspend () -> Unit) { open = false; scope.launch { try { block() } catch (_: Exception) { failure = "操作未完成，请重试" } } }
    IconButton({ open = true }) { Icon(Icons.Default.MoreVert, "调查操作") }
    DropdownMenu(open, { open = false }) {
        DropdownMenuItem({ Text("重命名与标签") }, { open = false; editing = true })
        DropdownMenuItem({ Text("导出") }, { action {
            var result = hub.session.api.getMessages(sessionId, limit = 200)
            var messages = result.messages
            val cursors = mutableSetOf<String>()
            while(result.page.hasMore && result.page.nextBeforeSeq != null && result.page.nextBeforeAt != null) {
                check(cursors.add("${result.page.nextBeforeSeq}:${result.page.nextBeforeAt}"))
                result = hub.session.api.getMessages(sessionId, limit = 200, beforeSeq = result.page.nextBeforeSeq, beforeAt = result.page.nextBeforeAt)
                messages = result.messages + messages
            }
            result = result.copy(messages = messages)
            val root = File(context.cacheDir, "text-exports").apply { mkdirs() }
            val file = File(root, "investigation.json").apply { writeText(HapiJson.encodeToString(result)) }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.attachments", file)
            context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type = "application/json"; putExtra(Intent.EXTRA_STREAM, uri); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION) }, "导出当前调查记录"))
        } })
        DropdownMenuItem({ Text("标为未读") }, { action { hub.session.api.updateSessionReadState(sessionId, SessionReadStateRequest("unread", expectedVersion = summary?.readState?.version ?: 0)); navigation.home() } })
        DropdownMenuItem({ Text("归档") }, { action { hub.session.api.archiveSession(sessionId); navigation.home() } })
        DropdownMenuItem({ Text("删除") }, { open = false; onDelete() })
        HorizontalDivider()
        DropdownMenuItem({ Text("使用 Codex 交叉核验", style = MaterialTheme.typography.bodySmall) }, { action {
            val profile = requireNotNull(hub.clientProfile.value)
            val machine = hub.session.api.getMachines().machines.first { it.active }
            val created = hub.session.api.spawnSession(machine.id, app.hapi.protocol.wire.SpawnSessionRequest(directory = requireNotNull(profile.defaultDirectory), agent = "codex", permissionMode = "yolo"))
            val id = created.sessionId?.takeIf { created.type == "success" } ?: error("spawn failed")
            hub.session.api.sendMessage(id, app.hapi.protocol.wire.SendMessageRequest("请交叉核验调查会话 $sessionId（$title）的结论，独立核对官方来源与证据，并指出分歧。", java.util.UUID.randomUUID().toString()))
            navigation.chat(id)
        } })
    }
    if(editing) AlertDialog(onDismissRequest = { editing = false }, title = { Text("重命名与标签") }, text = { Column { OutlinedTextField(name, { name = it }, label = { Text("调查名称") }); OutlinedTextField(tags, { tags = it }, label = { Text("标签，用逗号分隔") }) } }, confirmButton = { TextButton({ editing = false; action { hub.session.api.renameInvestigation(sessionId, name.trim(), tags.split(',', '，').map { it.trim().removePrefix("#") }.filter { it.isNotEmpty() }.distinct()) } }) { Text("保存") } }, dismissButton = { TextButton({ editing = false }) { Text("取消") } })
    failure?.let { AlertDialog(onDismissRequest = { failure = null }, text = { Text(it) }, confirmButton = { TextButton({ failure = null }) { Text("好") } }) }
}
