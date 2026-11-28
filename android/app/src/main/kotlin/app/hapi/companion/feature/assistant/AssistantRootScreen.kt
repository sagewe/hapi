package app.hapi.companion.feature.assistant

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CompareArrows
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import app.hapi.companion.di.HubGraph
import app.hapi.companion.di.LocalAppGraph
import app.hapi.companion.feature.chat.attachments.AttachmentPreparer
import app.hapi.companion.feature.chat.attachments.PrepareResult
import app.hapi.companion.feature.chat.composer.DictationController
import app.hapi.companion.feature.chat.composer.DictationEvent
import app.hapi.companion.feature.chat.composer.DictationState
import app.hapi.companion.feature.chat.composer.HapiDictationApi
import app.hapi.companion.feature.chat.composer.MediaRecorderDictation
import app.hapi.protocol.wire.AttachmentMetadata
import app.hapi.protocol.wire.ClientProfile
import app.hapi.protocol.wire.HapiJson
import app.hapi.protocol.wire.SendMessageRequest
import app.hapi.protocol.wire.SpawnSessionRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import java.io.File
import java.util.Base64
import java.util.UUID

@Serializable
private data class Draft(
    val text: String = "",
    val scene: String? = null,
    val preset: String? = null,
    val useCodex: Boolean = false,
    val session: String? = null,
    val localId: String = UUID.randomUUID().toString(),
    val files: List<DraftFile> = emptyList(),
)

@Serializable
private data class DraftFile(
    val id: String,
    val filename: String,
    val mime: String,
    val size: Long,
    val path: String? = null,
)

@Composable
fun AssistantRootScreen(
    hub: HubGraph,
    profile: ClientProfile,
    onOpenSession: (String) -> Unit,
    onSettings: () -> Unit,
) {
    val palette = assistantPalette()
    val context = LocalContext.current
    val appGraph = LocalAppGraph.current
    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val density = LocalDensity.current

    val root = remember(hub.hubUrl) {
        File(
            context.noBackupFilesDir,
            "investigation/" + Base64.getUrlEncoder().withoutPadding().encodeToString(hub.hubUrl.toByteArray()),
        ).apply { mkdirs() }
    }
    val journal = remember(root) { File(root, "draft.json") }
    var draft by remember(root) {
        mutableStateOf(runCatching { HapiJson.decodeFromString<Draft>(journal.readText()) }.getOrDefault(Draft()))
    }
    fun save(value: Draft) {
        draft = value
        val temp = File(root, "draft.tmp")
        temp.writeText(HapiJson.encodeToString(value))
        check(temp.renameTo(journal))
    }

    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var picker by remember { mutableStateOf(false) }
    var drawerOpen by remember { mutableStateOf(false) }
    var composerFocused by remember { mutableStateOf(false) }
    var voiceOverlayActive by remember { mutableStateOf(false) }
    var focusRequestKey by remember { mutableIntStateOf(0) }

    val imeOpen = WindowInsets.ime.getBottom(density) > 0
    val editing = composerFocused || imeOpen

    val brandTitle = profile.appTitle?.takeIf { it.isNotBlank() } ?: "琪琪工作"
    val scenes = remember(profile.quickActions) { resolveAssistantScenes(profile.quickActions) }
    val selectedScene = remember(draft.scene, scenes) {
        draft.scene?.let { key ->
            scenes.find { it.id == key || it.title == key }
                ?: when (key) {
                    "企业穿透" -> scenes.find { it.kind == 0 }
                    "自然人" -> scenes.find { it.kind == 1 }
                    "单据审核" -> scenes.find { it.kind == 2 }
                    "制裁筛查" -> scenes.find { it.kind == 3 }
                    else -> null
                }
        }
    }

    val sessions by hub.sessionStore.sessions.collectAsState()
    val needsAttention = remember(sessions) {
        sessions.any { s ->
            s.hasConversationContent &&
                s.metadata?.lifecycleState != "archived" &&
                (s.thinking ||
                    s.readState?.manualUnread == true ||
                    (s.contentRevision ?: 0) > (s.readState?.readRevision ?: 0))
        }
    }

    val preparer = remember { AttachmentPreparer(context) }
    suspend fun add(prepared: PrepareResult) {
        when (prepared) {
            is PrepareResult.Ready -> {
                val a = prepared.attachment
                withContext(Dispatchers.IO) { File(root, a.id).writeBytes(a.bytes) }
                save(draft.copy(files = draft.files + DraftFile(a.id, a.filename, a.mimeType, a.sizeBytes)))
            }
            else -> error = "无法读取附件，或文件超过 50 MB"
        }
    }

    val documents = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        scope.launch { uris.forEach { add(preparer.prepare(it)) } }
    }
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris ->
        scope.launch { uris.forEach { add(preparer.prepare(it)) } }
    }
    var cameraUri by rememberSaveable { mutableStateOf<String?>(null) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        if (ok) cameraUri?.let { scope.launch { add(preparer.prepare(Uri.parse(it))) } }
    }
    fun takePhoto() {
        try {
            val capture = preparer.newCameraCapture()
            cameraUri = capture.uri.toString()
            camera.launch(capture.uri)
        } catch (_: Exception) {
            error = "无法启动相机，请使用相册或选择 PDF"
        }
    }
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) takePhoto() else error = "请允许使用相机"
    }

    val dictation = remember(hub) {
        DictationController(HapiDictationApi(hub.session.api), MediaRecorderDictation(context), scope)
    }
    val micAvailable by dictation.isAvailable.collectAsState()
    val micState by dictation.state.collectAsState()
    val microphone = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) dictation.toggle() else error = "请允许使用麦克风"
    }
    LaunchedEffect(dictation) {
        dictation.refreshAvailability()
        dictation.events.collect {
            if (it is DictationEvent.Transcribed) {
                save(draft.copy(text = (draft.text + " " + it.text).trim()))
            } else {
                error = "语音转写失败，请重试"
            }
        }
    }
    DisposableEffect(dictation) { onDispose { dictation.cancel() } }

    val shares by appGraph.shareInbox.batches.collectAsState()
    LaunchedEffect(shares) {
        shares.filter { it.canImport }.forEach { batch ->
            batch.files.forEach { f ->
                if (draft.files.none { it.id == f.id }) {
                    add(preparer.prepare(appGraph.shareInbox.file(batch.id, f.id), f.filename, f.mimeType, f.id))
                }
            }
            val docSceneId = scenes.find { it.kind == 2 }?.id ?: "document"
            save(
                draft.copy(
                    text = listOf(draft.text, batch.text).filter { it.isNotBlank() }.joinToString("\n"),
                    scene = if (batch.files.isNotEmpty()) docSceneId else draft.scene,
                ),
            )
            appGraph.shareInbox.discard(batch.id)
        }
    }

    val preset = profile.modelPresets.find { it.id == draft.preset }
        ?: profile.modelPresets.find { it.isDefault }
        ?: profile.modelPresets.firstOrNull()

    fun clearDraft(useCodex: Boolean = false) {
        if (busy) return
        draft.files.forEach { File(root, it.id).delete() }
        save(Draft(preset = preset?.id, useCodex = useCodex))
        error = null
    }

    fun selectScene(scene: AssistantSceneSpec) {
        if (busy || draft.session != null) return
        if (selectedScene?.id == scene.id) {
            save(draft.copy(scene = null))
            return
        }
        save(draft.copy(scene = scene.id))
        if (scene.kind == 2) {
            picker = true
        } else {
            focusRequestKey++
        }
    }

    fun send() {
        if (busy || (draft.text.isBlank() && draft.files.isEmpty()) || micState != DictationState.Idle) return
        busy = true
        error = null
        scope.launch {
            try {
                var id = draft.session
                if (id == null) {
                    val machine = hub.session.api.getMachines().machines.firstOrNull { it.active }
                        ?: error("调查服务暂未连接，请稍后重试")
                    val agent = if (draft.useCodex) "codex" else profile.defaultAgent
                    val permissionMode = if (agent == "codex" && profile.defaultPermissionMode == "always-proceed") {
                        "yolo"
                    } else {
                        profile.defaultPermissionMode
                    }
                    val result = hub.session.api.spawnSession(
                        machine.id,
                        SpawnSessionRequest(
                            directory = requireNotNull(profile.defaultDirectory),
                            agent = agent,
                            model = if (draft.useCodex) null else (preset?.model ?: profile.defaultModel),
                            effort = if (draft.useCodex) null else preset?.effort,
                            permissionMode = permissionMode,
                        ),
                    )
                    id = result.sessionId?.takeIf { result.type == "success" } ?: error(result.message ?: "创建调查失败")
                    save(draft.copy(session = id))
                }
                val sessionId = requireNotNull(id)
                draft.files.forEach { f ->
                    if (f.path == null) {
                        val uploaded = hub.session.api.uploadFile(
                            sessionId,
                            f.filename,
                            Base64.getEncoder().encodeToString(File(root, f.id).readBytes()),
                            f.mime,
                        )
                        save(draft.copy(files = draft.files.map { if (it.id == f.id) it.copy(path = uploaded.path) else it }))
                    }
                }
                val attachments = draft.files.map {
                    AttachmentMetadata(
                        id = it.id,
                        filename = it.filename,
                        mimeType = it.mime,
                        size = it.size,
                        path = requireNotNull(it.path),
                    )
                }
                val messageText = selectedScene?.buildMessage(draft.text)
                    ?: draft.text.trim().ifEmpty { "请审核所附资料" }
                hub.session.api.sendMessage(
                    sessionId,
                    SendMessageRequest(messageText, draft.localId, attachments.ifEmpty { null }),
                )
                draft.files.forEach { File(root, it.id).delete() }
                save(Draft(preset = preset?.id))
                onOpenSession(sessionId)
            } catch (e: Exception) {
                error = "发送未完成，可重试：${e.message}"
            } finally {
                busy = false
            }
        }
    }

    val hasResettableDraft = draft.text.isNotEmpty() || draft.files.isNotEmpty() || selectedScene != null || draft.useCodex

    AssistantPushDrawerStage(
        open = drawerOpen,
        onOpenChange = { drawerOpen = it },
        gesturesEnabled = !voiceOverlayActive,
        drawerContent = {
            AssistantHistoryDrawer(
                hub = hub,
                brandTitle = brandTitle,
                selectedSessionId = null,
                onOpen = { id ->
                    drawerOpen = false
                    onOpenSession(id)
                },
                onSettings = {
                    drawerOpen = false
                    onSettings()
                },
                onNew = {
                    drawerOpen = false
                    clearDraft(false)
                },
            )
        },
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(palette.background)
                .statusBarsPadding(),
        ) {
            // Floating MyDots-style workbench header: asymmetric menu circle + minimal reset circle.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 14.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box {
                    Surface(
                        onClick = {
                            focusManager.clearFocus(force = true)
                            keyboard?.hide()
                            drawerOpen = true
                        },
                        shape = CircleShape,
                        color = palette.surface,
                        border = BorderStroke(0.5.dp, palette.border),
                        shadowElevation = 2.dp,
                        modifier = Modifier.size(44.dp),
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            AssistantMenuIcon(tint = palette.ink)
                        }
                    }
                    if (needsAttention) {
                        Box(
                            modifier = Modifier
                                .align(Alignment.TopEnd)
                                .offset(x = (-3).dp, y = 4.dp)
                                .size(9.dp)
                                .clip(CircleShape)
                                .background(palette.background)
                                .padding(1.5.dp)
                                .clip(CircleShape)
                                .background(palette.accent),
                        )
                    }
                }

                Spacer(Modifier.weight(1f))

                AnimatedVisibility(
                    visible = hasResettableDraft,
                    enter = fadeIn() + scaleIn(initialScale = 0.9f),
                    exit = fadeOut() + scaleOut(targetScale = 0.9f),
                ) {
                    Surface(
                        onClick = {
                            focusManager.clearFocus(force = true)
                            keyboard?.hide()
                            clearDraft(false)
                        },
                        shape = CircleShape,
                        color = palette.surface,
                        border = BorderStroke(0.5.dp, palette.border),
                        shadowElevation = 2.dp,
                        modifier = Modifier.size(44.dp),
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(
                                imageVector = Icons.Default.Refresh,
                                contentDescription = "清空当前草稿",
                                tint = palette.inkSecondary,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }
            }

            // Center canvas: calm greeting + thumb-zone 2x2 scenario grid when browsing;
            // collapses cleanly to a dismissable canvas + horizontal scenario pills when keyboard is open.
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
            ) {
                if (!editing) {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(top = 14.dp),
                    ) {
                        app.hapi.companion.feature.updates.AndroidUpdateHint(hub)

                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 22.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text(
                                text = "${assistantCalmDateCaption()} · $brandTitle",
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Medium,
                                color = palette.inkMuted,
                            )
                            Text(
                                text = assistantGreeting(),
                                fontSize = 32.sp,
                                fontWeight = FontWeight.Bold,
                                color = palette.ink,
                            )
                        }

                        Spacer(Modifier.weight(1f))

                        // Unready incoming shares / error banner above the grid.
                        shares.filter { !it.canImport }.forEach { batch ->
                            Column(Modifier.padding(horizontal = 20.dp, vertical = 4.dp)) {
                                batch.files.forEach { file ->
                                    Text(
                                        text = file.filename + " · " + if (file.status == app.hapi.companion.feature.share.SharedFileStatus.Copying) {
                                            "正在接收…"
                                        } else {
                                            "读取失败，请从原应用重新分享"
                                        },
                                        fontSize = 12.sp,
                                        color = palette.report,
                                    )
                                }
                                TextButton({ scope.launch { appGraph.shareInbox.discard(batch.id) } }) {
                                    Text("移除", color = palette.inkSecondary)
                                }
                            }
                        }

                        // Restrained single-accent 2x2 Scenario Grid in thumb zone.
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 18.dp)
                                .padding(bottom = 12.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            scenes.chunked(2).forEach { row ->
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                                ) {
                                    row.forEach { scene ->
                                        val isSelected = selectedScene?.id == scene.id
                                        Surface(
                                            onClick = { selectScene(scene) },
                                            enabled = !busy && draft.session == null,
                                            shape = RoundedCornerShape(16.dp),
                                            color = if (isSelected) palette.accent.copy(alpha = 0.09f) else palette.surface,
                                            border = BorderStroke(
                                                width = if (isSelected) 1.1.dp else 0.5.dp,
                                                color = if (isSelected) palette.accent.copy(alpha = 0.45f) else palette.border,
                                            ),
                                            modifier = Modifier.weight(1f),
                                        ) {
                                            Column(
                                                modifier = Modifier.padding(14.dp),
                                                verticalArrangement = Arrangement.spacedBy(12.dp),
                                            ) {
                                                Row(
                                                    modifier = Modifier.fillMaxWidth(),
                                                    verticalAlignment = Alignment.CenterVertically,
                                                ) {
                                                    Box(
                                                        modifier = Modifier
                                                            .size(30.dp)
                                                            .clip(RoundedCornerShape(9.dp))
                                                            .background(
                                                                if (isSelected) palette.accent.copy(alpha = 0.16f) else palette.surfaceMuted,
                                                            ),
                                                        contentAlignment = Alignment.Center,
                                                    ) {
                                                        Icon(
                                                            imageVector = scene.icon,
                                                            contentDescription = null,
                                                            tint = if (isSelected) palette.accent else palette.inkSecondary,
                                                            modifier = Modifier.size(16.dp),
                                                        )
                                                    }
                                                    Spacer(Modifier.weight(1f))
                                                    Icon(
                                                        imageVector = if (isSelected) Icons.Default.CheckCircle else Icons.Default.ChevronRight,
                                                        contentDescription = null,
                                                        tint = if (isSelected) palette.accent else palette.inkMuted,
                                                        modifier = Modifier.size(if (isSelected) 17.dp else 15.dp),
                                                    )
                                                }
                                                Text(
                                                    text = scene.title,
                                                    fontSize = 15.sp,
                                                    fontWeight = FontWeight.SemiBold,
                                                    color = palette.ink,
                                                    maxLines = 1,
                                                    overflow = TextOverflow.Ellipsis,
                                                )
                                            }
                                        }
                                    }
                                    if (row.size == 1) Spacer(Modifier.weight(1f))
                                }
                            }
                        }
                    }
                } else {
                    // Keyboard open: tap blank area to dismiss + horizontal compact scenario pills.
                    Column(modifier = Modifier.fillMaxSize()) {
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .fillMaxWidth()
                                .clickable(
                                    interactionSource = remember { MutableInteractionSource() },
                                    indication = null,
                                    onClick = {
                                        focusManager.clearFocus(force = true)
                                        keyboard?.hide()
                                    },
                                ),
                        )
                        if (draft.session == null) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .horizontalScroll(rememberScrollState())
                                    .padding(horizontal = 16.dp, vertical = 8.dp),
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                scenes.forEach { scene ->
                                    val active = selectedScene?.id == scene.id
                                    Surface(
                                        onClick = {
                                            save(draft.copy(scene = if (active) null else scene.id))
                                            if (!active && scene.kind == 2) picker = true
                                        },
                                        shape = CircleShape,
                                        color = if (active) palette.accent else palette.surface,
                                        border = if (active) null else BorderStroke(0.5.dp, palette.border),
                                    ) {
                                        Row(
                                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(5.5.dp),
                                        ) {
                                            Icon(
                                                imageVector = scene.icon,
                                                contentDescription = null,
                                                tint = if (active) Color.White else palette.accent,
                                                modifier = Modifier.size(13.dp),
                                            )
                                            Text(
                                                text = scene.title,
                                                fontSize = 12.5.sp,
                                                fontWeight = FontWeight.Medium,
                                                color = if (active) Color.White else palette.accent,
                                                maxLines = 1,
                                                softWrap = false,
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            error?.let { msg ->
                Text(
                    text = msg,
                    fontSize = 12.sp,
                    color = palette.report,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
                )
            }

            // Floating bottom composer over subtle gradient backdrop.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(
                        Brush.verticalGradient(
                            colors = listOf(palette.background.copy(alpha = 0f), palette.background),
                        ),
                    )
                    .navigationBarsPadding()
                    .imePadding()
                    .padding(horizontal = 12.dp)
                    .padding(top = 4.dp, bottom = 8.dp),
            ) {
                AssistantComposer(
                    text = draft.text,
                    onTextChange = { text, _, _ -> save(draft.copy(text = text)) },
                    onSend = ::send,
                    onAdd = { picker = true },
                    onMic = {
                        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                            dictation.toggle()
                        } else {
                            microphone.launch(Manifest.permission.RECORD_AUDIO)
                        }
                    },
                    onCancelRecording = dictation::cancel,
                    placeholder = selectedScene?.placeholder,
                    attachments = draft.files.map {
                        AssistantAttachment(
                            id = it.id,
                            filename = it.filename,
                            mime = it.mime,
                            thumbnail = if (it.mime.startsWith("image/")) File(root, it.id) else null,
                            sizeBytes = it.size,
                        )
                    },
                    onRemove = { id ->
                        draft.files.find { it.id == id }?.let { file ->
                            save(draft.copy(files = draft.files - file))
                            File(root, file.id).delete()
                        }
                    },
                    busy = busy,
                    dictation = if (micAvailable) micState else null,
                    focusRequestKey = focusRequestKey,
                    onFocusChanged = { composerFocused = it },
                    onVoiceOverlayActiveChanged = { voiceOverlayActive = it },
                    leading = {
                        selectedScene?.let { scene ->
                            Surface(
                                onClick = {
                                    if (draft.session == null) {
                                        save(draft.copy(scene = null))
                                        focusManager.clearFocus(force = true)
                                    }
                                },
                                shape = CircleShape,
                                color = palette.accent.copy(alpha = 0.12f),
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.5.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(5.5.dp),
                                ) {
                                    Icon(
                                        imageVector = scene.icon,
                                        contentDescription = null,
                                        tint = palette.accent,
                                        modifier = Modifier.size(13.dp),
                                    )
                                    Text(
                                        text = scene.title,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = palette.accent,
                                    )
                                    Icon(
                                        imageVector = Icons.Default.Close,
                                        contentDescription = "取消${scene.title}",
                                        tint = palette.accent.copy(alpha = 0.75f),
                                        modifier = Modifier.size(12.dp),
                                    )
                                }
                            }
                        }
                    },
                    presets = {
                        if (draft.useCodex) {
                            Surface(
                                onClick = { clearDraft(useCodex = false) },
                                shape = CircleShape,
                                color = palette.risk.copy(alpha = 0.14f),
                                modifier = Modifier.height(32.dp),
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                                ) {
                                    Icon(
                                        imageVector = Icons.Default.CompareArrows,
                                        contentDescription = null,
                                        tint = palette.risk,
                                        modifier = Modifier.size(13.dp),
                                    )
                                    Text(
                                        text = "交叉核验",
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = palette.risk,
                                    )
                                    Icon(
                                        imageVector = Icons.Default.Close,
                                        contentDescription = "退出交叉核验",
                                        tint = palette.risk.copy(alpha = 0.7f),
                                        modifier = Modifier.size(12.dp),
                                    )
                                }
                            }
                        } else {
                            AssistantPresetSwitch(
                                presets = profile.modelPresets,
                                selected = { it.id == preset?.id },
                                onSelect = { save(draft.copy(preset = it.id)) },
                                enabled = !busy && draft.session == null,
                            )
                        }
                    },
                )
            }
        }
    }

    if (picker) {
        AssistantAttachmentSheet(
            onDismiss = { picker = false },
            onCamera = {
                if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                    takePhoto()
                } else {
                    cameraPermission.launch(Manifest.permission.CAMERA)
                }
            },
            onPhotos = {
                photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            },
            onPdf = { documents.launch(arrayOf("*/*")) },
            useCodex = draft.useCodex,
            onToggleCodex = { clearDraft(useCodex = !draft.useCodex) },
        )
    }
}
