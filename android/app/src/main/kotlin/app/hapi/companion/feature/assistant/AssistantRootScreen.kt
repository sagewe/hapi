package app.hapi.companion.feature.assistant

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import app.hapi.companion.di.*
import app.hapi.companion.feature.chat.attachments.*
import app.hapi.companion.feature.chat.composer.*
import app.hapi.protocol.wire.*
import kotlinx.coroutines.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import java.io.File
import java.util.Base64
import java.util.UUID

@Serializable private data class Draft(val text: String = "", val scene: String? = null, val preset: String? = null, val session: String? = null, val localId: String = UUID.randomUUID().toString(), val files: List<DraftFile> = emptyList())
@Serializable private data class DraftFile(val id: String, val filename: String, val mime: String, val size: Long, val path: String? = null)
internal val assistantSceneColors = listOf(Color(0xFF3478BD), Color(0xFF8B5FC1), Color(0xFF238B80), Color(0xFFC48132))
private val sceneTitles = listOf("企业穿透", "自然人", "单据审核", "制裁筛查")

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun AssistantRootScreen(hub: HubGraph, profile: ClientProfile, onOpenSession: (String) -> Unit, onSettings: () -> Unit) {
    val context = LocalContext.current
    val appGraph = LocalAppGraph.current
    val scope = rememberCoroutineScope()
    val root = remember(hub.hubUrl) { File(context.noBackupFilesDir, "investigation/" + Base64.getUrlEncoder().withoutPadding().encodeToString(hub.hubUrl.toByteArray())).apply { mkdirs() } }
    val journal = remember(root) { File(root, "draft.json") }
    var draft by remember(root) { mutableStateOf(runCatching { HapiJson.decodeFromString<Draft>(journal.readText()) }.getOrDefault(Draft())) }
    fun save(value: Draft) { draft = value; val temp = File(root, "draft.tmp"); temp.writeText(HapiJson.encodeToString(value)); check(temp.renameTo(journal)) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var picker by remember { mutableStateOf(false) }
    var search by remember { mutableStateOf("") }
    var archived by remember { mutableStateOf(false) }
    var tag by remember { mutableStateOf<String?>(null) }
    val sessions by hub.sessionStore.sessions.collectAsState()
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val preparer = remember { AttachmentPreparer(context) }
    suspend fun add(prepared: PrepareResult) {
        when (prepared) {
            is PrepareResult.Ready -> { val a = prepared.attachment; File(root, a.id).writeBytes(a.bytes); save(draft.copy(files = draft.files + DraftFile(a.id, a.filename, a.mimeType, a.sizeBytes))) }
            else -> error = "无法读取附件，或文件超过 50 MB"
        }
    }
    val documents = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris -> scope.launch { uris.forEach { add(preparer.prepare(it)) } } }
    var cameraUri by remember { mutableStateOf<Uri?>(null) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok -> if (ok) cameraUri?.let { scope.launch { add(preparer.prepare(it)) } } }
    fun takePhoto() {
        try { val capture = preparer.newCameraCapture(); cameraUri = capture.uri; camera.launch(capture.uri) }
        catch (_: Exception) { error = "无法启动相机，请使用相册或选择 PDF" }
    }
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted -> if(granted) takePhoto() else error = "请允许使用相机" }
    val dictation = remember(hub) { DictationController(HapiDictationApi(hub.session.api), MediaRecorderDictation(context), scope) }
    val micAvailable by dictation.isAvailable.collectAsState()
    val micState by dictation.state.collectAsState()
    val microphone = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { if (it) dictation.toggle() else error = "请允许使用麦克风" }
    LaunchedEffect(dictation) { dictation.refreshAvailability(); dictation.events.collect { if (it is DictationEvent.Transcribed) save(draft.copy(text = (draft.text + " " + it.text).trim())) else error = "语音转写失败，请重试" } }
    DisposableEffect(dictation) { onDispose { dictation.cancel() } }
    val shares by appGraph.shareInbox.batches.collectAsState()
    LaunchedEffect(shares) {
        shares.filter { it.canImport }.forEach { batch ->
            batch.files.forEach { f -> if (draft.files.none { it.id == f.id }) add(preparer.prepare(appGraph.shareInbox.file(batch.id, f.id), f.filename, f.mimeType, f.id)) }
            save(draft.copy(text = listOf(draft.text, batch.text).filter { it.isNotBlank() }.joinToString("\n"), scene = if (batch.files.isNotEmpty()) "单据审核" else draft.scene))
            appGraph.shareInbox.discard(batch.id)
        }
    }
    val preset = profile.modelPresets.find { it.id == draft.preset } ?: profile.modelPresets.find { it.isDefault } ?: profile.modelPresets.firstOrNull()
    fun send() { if (busy || (draft.text.isBlank() && draft.files.isEmpty()) || micState != DictationState.Idle) return
        busy = true; error = null
        scope.launch {
            try {
                var id = draft.session
                if (id == null) {
                    val machine = hub.session.api.getMachines().machines.firstOrNull { it.active } ?: error("调查服务暂未连接，请稍后重试")
                    val result = hub.session.api.spawnSession(machine.id, SpawnSessionRequest(directory = requireNotNull(profile.defaultDirectory), agent = profile.defaultAgent, model = preset?.model ?: profile.defaultModel, effort = preset?.effort, permissionMode = if (profile.defaultAgent == "codex" && profile.defaultPermissionMode == "always-proceed") "yolo" else profile.defaultPermissionMode))
                    id = result.sessionId?.takeIf { result.type == "success" } ?: error(result.message ?: "创建调查失败")
                    save(draft.copy(session = id))
                }
                val sessionId = requireNotNull(id)
                draft.files.forEach { f -> if (f.path == null) {
                    val uploaded = hub.session.api.uploadFile(sessionId, f.filename, Base64.getEncoder().encodeToString(File(root, f.id).readBytes()), f.mime)
                    save(draft.copy(files = draft.files.map { if (it.id == f.id) it.copy(path = uploaded.path) else it }))
                } }
                val attachments = draft.files.map { AttachmentMetadata(id = it.id, filename = it.filename, mimeType = it.mime, size = it.size, path = requireNotNull(it.path)) }
                val action = profile.quickActions.find { it.id == listOf("company", "individual", "document", "sanctions").getOrNull(sceneTitles.indexOf(draft.scene)) }
                val text = listOfNotNull(action?.prompt ?: draft.scene?.let { "调查场景：$it" }, draft.text.takeIf { it.isNotBlank() } ?: "请审核所附资料").joinToString("\n\n")
                hub.session.api.sendMessage(sessionId, SendMessageRequest(text, draft.localId, attachments.ifEmpty { null }))
                draft.files.forEach { File(root, it.id).delete() }; save(Draft(preset = preset?.id)); onOpenSession(sessionId)
            } catch (e: Exception) { error = "发送未完成，可重试：${e.message}" }
            finally { busy = false }
        }
    }
    ModalNavigationDrawer(drawerState = drawer, drawerContent = {
        AssistantHistoryDrawer(hub, { id -> scope.launch { drawer.close() }; onOpenSession(id) }, onSettings)
    }) {
        Scaffold(topBar = { TopAppBar(title = { Text("新调查", style = MaterialTheme.typography.titleLarge) }, navigationIcon = { IconButton({ scope.launch { drawer.open() } }) { Icon(Icons.Default.Menu, "历史调查") } }, actions = { IconButton({ if (!busy) save(Draft(preset = preset?.id)) }) { Icon(Icons.Default.Add, "新建调查") } }) }, bottomBar = {
            Surface(shape = RoundedCornerShape(20.dp), border = BorderStroke(.5.dp, MaterialTheme.colorScheme.outlineVariant), modifier = Modifier.padding(12.dp).navigationBarsPadding().imePadding()) {
                Column(Modifier.padding(8.dp)) {
                    draft.scene?.let { InputChip(true, { save(draft.copy(scene = null)) }, { Text(it) }, trailingIcon = { Icon(Icons.Default.Close, "取消场景", Modifier.size(16.dp)) }) }
                    Row(Modifier.horizontalScroll(rememberScrollState())) { draft.files.forEach { f -> InputChip(false, { if (!busy) { save(draft.copy(files = draft.files - f)); File(root, f.id).delete() } }, { Text(f.filename, maxLines = 2) }, trailingIcon = { Icon(Icons.Default.Close, "移除附件", Modifier.size(16.dp)) }) } }
                    TextField(draft.text, { save(draft.copy(text = it)) }, enabled = !busy, placeholder = { Text(when(draft.scene) { "企业穿透" -> "输入企业名称、注册地或线索"; "自然人" -> "输入姓名、国籍或身份线索"; "单据审核" -> "添加单据图片或 PDF，说明核验重点"; "制裁筛查" -> "输入主体名称、国家或名单线索"; else -> "输入调查对象或添加资料" }) }, modifier = Modifier.fillMaxWidth().heightIn(max = 180.dp), colors = TextFieldDefaults.colors(focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent, focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        IconButton({ picker = true }, enabled = !busy) { Icon(Icons.Default.Add, "添加资料") }
                        profile.modelPresets.forEachIndexed { index, p -> FilterChip(p.id == preset?.id, { save(draft.copy(preset = p.id)) }, { Text((if(index == 0) "⚡ " else "✦ ") + p.label) }, enabled = !busy) }
                        Spacer(Modifier.weight(1f))
                        if (micAvailable) IconButton({ if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) dictation.toggle() else microphone.launch(Manifest.permission.RECORD_AUDIO) }) { Icon(if (micState is DictationState.Recording) Icons.Default.Stop else Icons.Default.Mic, "语音听写") }
                        IconButton(::send, enabled = !busy && micState == DictationState.Idle) { if(busy) CircularProgressIndicator(Modifier.size(22.dp)) else Icon(Icons.Default.ArrowUpward, "发送") }
                    }
                }
            }
        }) { padding ->
            Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.Center) {
                app.hapi.companion.feature.updates.AndroidUpdateHint(hub)
                Text(profile.appTitle ?: "琪琪工作", style = MaterialTheme.typography.headlineMedium)
                Spacer(Modifier.height(28.dp))
                sceneTitles.chunked(2).forEachIndexed { row, titles ->
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { titles.forEachIndexed { col, title -> val i = row * 2 + col
                        Surface(onClick = { save(draft.copy(scene = if (draft.scene == title) null else title)); if (i == 2) picker = true }, shape = RoundedCornerShape(16.dp), border = BorderStroke(.5.dp, if(draft.scene == title) assistantSceneColors[i] else MaterialTheme.colorScheme.outlineVariant), modifier = Modifier.weight(1f)) {
                            Column(Modifier.padding(16.dp)) { Surface(color = assistantSceneColors[i].copy(alpha = .12f), shape = RoundedCornerShape(8.dp), modifier = Modifier.size(32.dp)) { Icon(listOf(Icons.Default.Business, Icons.Default.PersonSearch, Icons.Default.Description, Icons.Default.Policy)[i], null, tint = assistantSceneColors[i], modifier = Modifier.padding(6.dp)) }; Spacer(Modifier.height(14.dp)); Text(title, style = MaterialTheme.typography.titleSmall) }
                        }
                    } }; Spacer(Modifier.height(12.dp))
                }
                shares.filter { !it.canImport }.forEach { batch ->
                    batch.files.forEach { file -> Text(file.filename + " · " + if(file.status == app.hapi.companion.feature.share.SharedFileStatus.Copying) "正在接收…" else "读取失败，请从原应用重新分享", color = MaterialTheme.colorScheme.error) }
                    TextButton({ scope.launch { appGraph.shareInbox.discard(batch.id) } }) { Text("移除") }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }
            }
        }
    }
    if (picker) ModalBottomSheet({ picker = false }) {
        listOf("拍照", "相册", "选择 PDF").forEachIndexed { index, title -> TextButton({ picker = false; if(index == 0) { if(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) takePhoto() else cameraPermission.launch(Manifest.permission.CAMERA) } else documents.launch(arrayOf(if(index == 1) "image/*" else "application/pdf")) }, Modifier.fillMaxWidth()) { Text(title) } }
        Spacer(Modifier.navigationBarsPadding())
    }
}
