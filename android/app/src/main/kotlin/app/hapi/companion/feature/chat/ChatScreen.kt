package app.hapi.companion.feature.chat

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.items
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import android.content.Context
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import app.hapi.companion.R
import app.hapi.companion.feature.chat.composer.DictationErrorKind
import app.hapi.companion.feature.chat.attachments.AttachmentPickerSheet
import app.hapi.companion.feature.chat.attachments.AttachmentPreparer
import app.hapi.companion.feature.chat.attachments.CameraCapture
import app.hapi.companion.feature.chat.attachments.PrepareResult
import app.hapi.companion.feature.chat.composer.ChatComposer
import app.hapi.companion.feature.chat.composer.DictationController
import app.hapi.companion.feature.chat.composer.DictationEvent
import app.hapi.companion.feature.chat.composer.DictationState
import app.hapi.companion.feature.chat.composer.QueuedMessagesBar
import app.hapi.companion.feature.files.FolderGlyph
import app.hapi.companion.feature.sessions.DeleteSessionDialog
import app.hapi.companion.feature.sessions.RenameSessionDialog
import app.hapi.companion.ui.markdown.LocalMarkdownRenderCache
import app.hapi.companion.ui.markdown.LocalMarkdownLinkHandler
import app.hapi.companion.ui.theme.hapi
import app.hapi.protocol.chat.VisibleChatBlock
import app.hapi.protocol.chat.buildMessageMetadataLabels
import app.hapi.protocol.chat.messageMetadataForBlock
import java.io.File
import kotlinx.coroutines.launch

/** Pending camera capture across rotation/process death: uri + scratch path. */
private val CameraCaptureSaver = listSaver<CameraCapture?, String>(
    save = { capture ->
        if (capture == null) emptyList() else listOf(capture.uri.toString(), capture.file.absolutePath)
    },
    restore = { saved ->
        if (saved.size < 2) null else CameraCapture(Uri.parse(saved[0]), File(saved[1]))
    },
)

/** Conversation destination. ChatHost owns the shared session and reader navigation. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ChatScreen(
    viewModel: ChatViewModel,
    media: ChatMedia,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    snackbarHostState: SnackbarHostState = remember { SnackbarHostState() },
    /** null ⇒ mic button hidden (tests / previews without a controller). */
    dictation: DictationController? = null,
    /** Top-bar folder icon → session files browser (B-M4c). */
    onOpenFiles: () -> Unit = {},
    /** Markdown file citations → file viewer (full mode; optional line hint). */
    onOpenFile: (path: String, line: Int?) -> Unit = { _, _ -> },
    /** null ⇒ no scratchlist top-bar entry (tests / previews). */
    onOpenScratchlist: (() -> Unit)? = null,
    transcriptList: androidx.compose.foundation.lazy.LazyListState = androidx.compose.foundation.lazy.rememberLazyListState(),
    readingState: TranscriptReadingState = rememberTranscriptReadingState(viewModel.sessionId),
) {
    val state by viewModel.uiState.collectAsState()
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateFlow.collectAsState()
    val foreground = lifecycleState.isAtLeast(Lifecycle.State.RESUMED)
    val reconnecting by viewModel.reconnecting.collectAsState()
    val historyPaging by viewModel.historyPaging.collectAsState()
    val jumpToken by viewModel.jumpToken.collectAsState()
    val jumpingLatest by viewModel.jumpingLatest.collectAsState()
    val composerState by viewModel.composer.collectAsState()
    val pendingSchedule by viewModel.pendingSchedule.collectAsState()
    val codexPlanActions by viewModel.codexPlanActions.collectAsState()
    val queuedRows by viewModel.queuedRows.collectAsState()
    val configState by viewModel.config.collectAsState()
    val toolbarHeight = maxOf(64.dp, with(LocalDensity.current) { 24.sp.toDp() + 16.sp.toDp() } + 16.dp)
    var configSheetOpen by remember { mutableStateOf(false) }
    var renameDialogOpen by remember { mutableStateOf(false) }
    var deleteDialogOpen by remember { mutableStateOf(false) }
    var messageInfoBlock by remember { mutableStateOf<VisibleChatBlock?>(null) }

    DisposableEffect(viewModel) {
        viewModel.setTranscriptVisible(true)
        onDispose { viewModel.setTranscriptVisible(false) }
    }

    LaunchedEffect(foreground, state.readThroughRevision, state.isSyncingTail, state.warning) {
        if (foreground && state.blocks.isEmpty() && !state.hasMore) {
            viewModel.markDisplayed(state.readThroughRevision, state.renderedReadState)
        }
    }

    val context = LocalContext.current
    // ------------------------------------------------------------ dictation --
    val dictationState = dictation?.state?.collectAsState()?.value ?: DictationState.Idle
    val dictationAvailable = dictation?.isAvailable?.collectAsState()?.value ?: false
    LaunchedEffect(dictation) {
        dictation?.refreshAvailability()
    }
    LaunchedEffect(dictation, context) {
        dictation?.events?.collect { event ->
            when (event) {
                is DictationEvent.Transcribed -> viewModel.appendDictatedText(event.text)
                DictationEvent.NoProvider -> snackbarHostState.showSnackbar(
                    context.getString(R.string.chat_notice_no_transcription),
                )
                is DictationEvent.Error -> snackbarHostState.showSnackbar(
                    event.detail ?: context.getString(
                        when (event.kind) {
                            DictationErrorKind.StartFailed -> R.string.chat_dictation_start_failed
                            DictationErrorKind.HubUnreachable -> R.string.chat_dictation_hub_unreachable
                            DictationErrorKind.RecordingFailed -> R.string.chat_dictation_recording_failed
                            DictationErrorKind.NoAudio -> R.string.chat_dictation_no_audio
                            DictationErrorKind.TranscriptionFailed -> R.string.chat_dictation_failed
                        },
                    ),
                )
            }
        }
    }
    val scope = rememberCoroutineScope()
    val micPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            dictation?.toggle()
        } else {
            scope.launch {
                snackbarHostState.showSnackbar(context.getString(R.string.chat_notice_mic_permission))
            }
        }
    }
    val onDictationToggle: () -> Unit = toggle@{
        val controller = dictation ?: return@toggle
        // Stopping never needs the permission; starting checks + requests it.
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        when {
            dictationState !is DictationState.Idle -> controller.toggle()
            granted -> controller.toggle()
            else -> micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }
    val slashSuggestions by viewModel.slashSuggestions.collectAsState()
    val mentionSuggestions by viewModel.mentionSuggestions.collectAsState()

    // --------------------------------------------------------- attachments --
    val attachmentItems by viewModel.attachments.items.collectAsState()
    var attachmentSheetOpen by remember { mutableStateOf(false) }
    val preparer = remember { AttachmentPreparer(context) }

    /** Read + policy-apply one pick, then hand it to the upload tray. */
    suspend fun ingestUri(uri: Uri) {
        when (val result = preparer.prepare(uri)) {
            is PrepareResult.Ready -> viewModel.attachments.add(result.attachment)
            is PrepareResult.TooLarge -> snackbarHostState.showSnackbar(
                context.getString(R.string.chat_notice_attachment_too_large, result.filename),
            )
            is PrepareResult.Unreadable -> snackbarHostState.showSnackbar(
                context.getString(R.string.chat_notice_attachment_unreadable, result.filename),
            )
        }
    }

    fun ingestUris(uris: List<Uri>) {
        if (uris.isEmpty()) return
        scope.launch { uris.forEach { ingestUri(it) } }
    }

    val photoPickerLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(),
    ) { uris -> ingestUris(uris) }
    val documentPickerLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris -> ingestUris(uris) }

    // The camera app may rotate/kill us while open — keep the scratch target.
    var pendingCapture by rememberSaveable(stateSaver = CameraCaptureSaver) {
        mutableStateOf<CameraCapture?>(null)
    }
    val takePictureLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.TakePicture(),
    ) { success ->
        val capture = pendingCapture
        pendingCapture = null
        if (capture == null) return@rememberLauncherForActivityResult
        if (!success) {
            capture.discard()
            return@rememberLauncherForActivityResult
        }
        scope.launch {
            ingestUri(capture.uri)
            capture.discard()
        }
    }

    fun launchCamera() {
        val capture = preparer.newCameraCapture()
        pendingCapture = capture
        takePictureLauncher.launch(capture.uri)
    }

    val cameraPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            launchCamera()
        } else {
            scope.launch {
                snackbarHostState.showSnackbar(context.getString(R.string.chat_notice_camera_permission))
            }
        }
    }
    val onTakePhoto: () -> Unit = {
        // The manifest declares CAMERA (QR pairing), which makes the runtime
        // grant mandatory for ACTION_IMAGE_CAPTURE too.
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) launchCamera() else cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
    }

    val interactions = remember(state.flavor, state.permissionOverrides, codexPlanActions, viewModel) {
        ChatInteractions(
            flavor = state.flavor,
            permissionOverrides = state.permissionOverrides,
            resolvePermission = viewModel::resolvePermission,
            retryFailedMessage = viewModel::retryFailedMessage,
            codexPlanActions = codexPlanActions,
            implementCodexPlan = viewModel::implementCodexPlan,
            continueCodexPlan = viewModel::continueCodexPlan,
            sendQuickMessage = viewModel::sendQuickMessage,
        )
    }

    val assistantProfile = app.hapi.companion.di.LocalClientProfile.current?.takeIf { it.mode == "assistant" }
    val caseHub = if (assistantProfile != null) app.hapi.companion.di.LocalAppGraph.current.activeHubGraph.collectAsState().value else null
    var caseFiles by remember(viewModel.sessionId) { mutableStateOf(emptyList<app.hapi.protocol.wire.CaseFile>()) }
    var rightDrawerOpen by remember(viewModel.sessionId) { mutableStateOf(false) }
    var pendingOpenZipMediaId by remember(viewModel.sessionId) { mutableStateOf<String?>(null) }
    var isRightZipOpen by remember(viewModel.sessionId) { mutableStateOf(false) }
    var popZipSignal by remember(viewModel.sessionId) { mutableIntStateOf(0) }
    var editingSceneDraft by remember(viewModel.sessionId) { mutableStateOf<app.hapi.protocol.wire.SceneDraft?>(null) }
    LaunchedEffect(caseHub, assistantProfile, foreground, state.blocks.size, rightDrawerOpen, attachmentItems.isEmpty()) {
        if (assistantProfile != null && foreground && caseHub != null) {
            runCatching { caseHub.session.api.getCaseFiles(viewModel.sessionId).files }.onSuccess { caseFiles = it }
        }
    }
    val assistantNavigation = app.hapi.companion.feature.assistant.AssistantNavigation.current
    val assistantDrawer = androidx.compose.material3.rememberDrawerState(androidx.compose.material3.DrawerValue.Closed)
    val assistantScope = rememberCoroutineScope()
    val assistantColors = if (assistantProfile != null) app.hapi.companion.feature.assistant.assistantPalette() else null
    val sessionSummaries = caseHub?.sessionStore?.sessions?.collectAsState()?.value.orEmpty()
    val currentSummary = remember(sessionSummaries, viewModel.sessionId) { sessionSummaries.find { it.id == viewModel.sessionId } }
    val isSceneStudio = state.header.title.contains("场景工坊") ||
        (currentSummary?.metadata?.tags?.contains("场景工坊") == true)

    suspend fun saveQuickAction(action: app.hapi.protocol.wire.ClientQuickAction) {
        val hub = caseHub ?: return
        val profile = assistantProfile ?: return
        val current = profile.quickActions.ifEmpty {
            app.hapi.companion.feature.assistant.defaultAssistantScenes.map {
                app.hapi.protocol.wire.ClientQuickAction(
                    id = it.id,
                    title = it.title,
                    prompt = it.prompt.orEmpty(),
                    subtitle = it.placeholder,
                    icon = it.iconKey,
                    opensAttachment = it.opensAttachment,
                    isCustom = false,
                    hidden = false,
                )
            }
        }
        val exists = current.any { it.id == action.id }
        val merged = if (exists) current.map { if (it.id == action.id) action else it } else current + action
        hub.session.api.saveLibraryScenarios(merged)
        hub.refreshProfile()
    }

    val promoteCaseToScenario: () -> Unit = promote@{
        val hub = caseHub ?: return@promote
        val profile = assistantProfile ?: return@promote
        rightDrawerOpen = false
        assistantScope.launch {
            runCatching {
                val machine = hub.session.api.getMachines().machines.firstOrNull { it.active }
                    ?: error("调查服务暂未连接")
                val defaultPreset = profile.modelPresets.find { it.isDefault } ?: profile.modelPresets.firstOrNull()
                val created = hub.session.api.spawnSession(
                    machine.id,
                    app.hapi.protocol.wire.SpawnSessionRequest(
                        directory = requireNotNull(profile.defaultDirectory),
                        agent = profile.defaultAgent,
                        model = defaultPreset?.model ?: profile.defaultModel,
                        effort = defaultPreset?.effort,
                        permissionMode = profile.defaultPermissionMode,
                    ),
                )
                val id = created.sessionId?.takeIf { created.type == "success" } ?: error("无法创建场景工坊")
                hub.session.api.sendMessage(
                    id,
                    app.hapi.protocol.wire.SendMessageRequest(
                        app.hapi.companion.feature.assistant.SceneStudioPrompts.promoteFromCase(state.header.title, caseFiles),
                        java.util.UUID.randomUUID().toString(),
                    ),
                )
                assistantNavigation.chat(id)
            }.onFailure {
                snackbarHostState.showSnackbar("无法进入场景工坊：${it.message ?: "请重试"}")
            }
        }
    }

    val sceneDraftHandler = remember(caseHub, assistantProfile) {
        if (caseHub != null && assistantProfile != null) {
            app.hapi.companion.feature.assistant.SceneDraftHandler(
                onSave = { draft -> saveQuickAction(draft.toQuickAction()) },
                onEdit = { draft -> editingSceneDraft = draft },
            )
        } else null
    }

    app.hapi.companion.feature.assistant.AssistantConversationShell(
        drawer = assistantDrawer,
        selectedSessionId = viewModel.sessionId,
        rightDrawerOpen = rightDrawerOpen,
        onRightDrawerChange = { rightDrawerOpen = it },
        isRightZipOpen = isRightZipOpen,
        onPopRightZip = { popZipSignal++ },
        rightDrawerContent = if (caseHub != null) {
            {
                app.hapi.companion.feature.assistant.CaseDossierDrawer(
                    api = caseHub.session.api,
                    sessionId = viewModel.sessionId,
                    title = state.header.title,
                    files = caseFiles,
                    pendingOpenZipMediaId = pendingOpenZipMediaId,
                    onConsumePendingZip = { pendingOpenZipMediaId = null },
                    onZipOpenChanged = { isRightZipOpen = it },
                    popZipSignal = popZipSignal,
                    onQuoteFile = { name ->
                        rightDrawerOpen = false
                        val prefix = "关于「$name」："
                        val next = if (composerState.text.isBlank()) prefix else "${composerState.text.trimEnd()}\n$prefix"
                        viewModel.onComposerChange(next, next.length, next.length)
                    },
                    onAddFiles = {
                        rightDrawerOpen = false
                        attachmentSheetOpen = true
                    },
                    onPromoteToScenario = promoteCaseToScenario,
                )
            }
        } else null,
    ) {
    CompositionLocalProvider(
        app.hapi.companion.feature.assistant.LocalCaseFiles provides app.hapi.companion.feature.assistant.CaseFilesAccess(
            files = caseFiles,
            open = { rightDrawerOpen = true },
            openZip = { id ->
                pendingOpenZipMediaId = id
                rightDrawerOpen = true
            },
        ),
        app.hapi.companion.feature.assistant.LocalSceneDraftHandler provides sceneDraftHandler,
    ) {
    Scaffold(
        modifier = modifier.fillMaxSize(),
        containerColor = assistantColors?.background ?: MaterialTheme.colorScheme.background,
        topBar = {
            if (assistantProfile != null && assistantColors != null) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(assistantColors.background)
                        .statusBarsPadding(),
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 14.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Surface(
                            onClick = { assistantScope.launch { assistantDrawer.open() } },
                            shape = androidx.compose.foundation.shape.CircleShape,
                            color = assistantColors.surface,
                            border = androidx.compose.foundation.BorderStroke(0.5.dp, assistantColors.border),
                            shadowElevation = 2.dp,
                            modifier = Modifier.size(44.dp),
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                app.hapi.companion.feature.assistant.AssistantMenuIcon(tint = assistantColors.ink)
                            }
                        }
                        Column(
                            modifier = Modifier.weight(1f),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(
                                text = state.header.title,
                                style = MaterialTheme.typography.titleSmall,
                                color = assistantColors.ink,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            if (reconnecting) {
                                Text(
                                    text = stringResource(R.string.chat_reconnecting_retry),
                                    style = app.hapi.companion.ui.theme.HapiTypography.caption,
                                    color = assistantColors.report,
                                    maxLines = 1,
                                    modifier = Modifier.clickable(onClick = viewModel::retry),
                                )
                            } else if (state.header.thinking) {
                                Row(
                                    modifier = Modifier
                                        .clip(androidx.compose.foundation.shape.CircleShape)
                                        .background(assistantColors.accentSoft)
                                        .padding(horizontal = 8.dp, vertical = 2.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                                ) {
                                    app.hapi.companion.feature.assistant.AssistantOrbitingRing(
                                        color = assistantColors.accent,
                                        strokeWidth = 1.4.dp,
                                        modifier = Modifier.size(10.dp),
                                    )
                                    Text(
                                        text = "调查中",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = assistantColors.accent,
                                    )
                                }
                            } else if (isSceneStudio) {
                                Row(
                                    modifier = Modifier
                                        .clip(androidx.compose.foundation.shape.CircleShape)
                                        .background(assistantColors.accentSoft)
                                        .padding(horizontal = 8.dp, vertical = 2.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                                ) {
                                    Icon(
                                        imageVector = Icons.Filled.AutoAwesome,
                                        contentDescription = null,
                                        tint = assistantColors.accent,
                                        modifier = Modifier.size(11.dp),
                                    )
                                    Text(
                                        text = "创造模式",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = assistantColors.accent,
                                    )
                                }
                            }
                        }
                        Box {
                            Surface(
                                onClick = { rightDrawerOpen = true },
                                shape = androidx.compose.foundation.shape.CircleShape,
                                color = assistantColors.surface,
                                border = androidx.compose.foundation.BorderStroke(0.5.dp, assistantColors.border),
                                shadowElevation = 2.dp,
                                modifier = Modifier.size(40.dp),
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Icon(
                                        imageVector = Icons.Filled.Folder,
                                        contentDescription = "本案卷宗",
                                        tint = if (caseFiles.isNotEmpty()) assistantColors.accent else assistantColors.ink,
                                        modifier = Modifier.size(19.dp),
                                    )
                                }
                            }
                            if (caseFiles.isNotEmpty()) {
                                Box(
                                    modifier = Modifier
                                        .align(Alignment.TopEnd)
                                        .offset(x = 3.dp, y = (-3).dp)
                                        .clip(androidx.compose.foundation.shape.CircleShape)
                                        .background(assistantColors.accent)
                                        .padding(horizontal = 5.dp, vertical = 1.dp),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Text(
                                        text = "${minOf(caseFiles.size, 99)}",
                                        fontSize = 10.sp,
                                        fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
                                        color = androidx.compose.ui.graphics.Color.White,
                                    )
                                }
                            }
                        }
                        app.hapi.companion.feature.assistant.AssistantCaseMenu(
                            sessionId = viewModel.sessionId,
                            title = state.header.title,
                            onDelete = { deleteDialogOpen = true },
                            onReopen = viewModel::reopenSession,
                            onPromoteToScenario = if (!isSceneStudio) promoteCaseToScenario else null,
                        )
                    }
                    HorizontalDivider(thickness = 0.5.dp, color = assistantColors.border)
                }
            } else {
                TopAppBar(
                    expandedHeight = toolbarHeight,
                    navigationIcon = {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.chat_back))
                        }
                    },
                    title = { ChatTitle(state.header, reconnecting, viewModel::retry) },
                    actions = {
                        // Two icons max (device feedback: four icons squeezed the
                        // title out) — gear for the frequent config switches,
                        // everything else in the overflow menu.
                        IconButton(onClick = { configSheetOpen = true }) {
                            Icon(Icons.Filled.Settings, contentDescription = stringResource(R.string.chat_open_settings))
                        }
                        val scratchlistCount by viewModel.scratchlistCount.collectAsState()
                        SessionOverflowMenu(
                            active = state.header.active,
                            onOpenFiles = onOpenFiles,
                            scratchlistCount = scratchlistCount,
                            onOpenScratchlist = if (viewModel.scratchlistEnabled) onOpenScratchlist else null,
                            onRename = { renameDialogOpen = true },
                            onReopen = viewModel::reopenSession,
                            onDelete = { deleteDialogOpen = true },
                            // Draft-level action, relocated from the composer's
                            // own overflow (one less button in the input bar).
                            onParkDraft = if (viewModel.scratchlistEnabled && composerState.text.isNotBlank()) {
                                viewModel::parkComposerDraft
                            } else {
                                null
                            },
                        )
                    },
                )
            }
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
        bottomBar = {
            app.hapi.companion.ui.theme.ReadingColumn(horizontalPadding=if(assistantProfile!=null) 0.dp else 16.dp) {
                // Edge-to-edge (enforced by targetSdk 35+): the bar owns its own
                // system insets — nav-bar padding when the keyboard is closed,
                // IME padding when open (inset consumption prevents doubling).
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .imePadding(),
                ) {
                    if (!state.header.active && !state.isInitialLoading && !state.loadFailed) {
                        InactiveSessionBar(onReopen = viewModel::reopenSession)
                    }
                    QueuedMessagesBar(
                        rows = queuedRows,
                        onSteer = viewModel::steerQueuedMessage,
                        onRetry = viewModel::retryIndeterminateMessage,
                        onEdit = viewModel::editQueuedMessage,
                        onCancel = viewModel::cancelQueuedMessage,
                    )
                    // Context-remaining readout; rides the same strip as the
                    // mode chip and hides until the thread reports usage.
                    if (assistantProfile == null) ContextUsageChip(indicator = state.contextUsage)
                    // Web StatusBar parity: the current permission mode rides
                    // directly above the composer; tapping opens the config
                    // sheet that hosts the switcher (the web span itself is
                    // not clickable).
                    if (assistantProfile == null) PermissionModeChip(
                        config = configState,
                        onClick = { configSheetOpen = true },
                    )
                    ChatComposer(
                        presetControls = {
                            if (assistantProfile != null && state.header.flavor != "codex") {
                                val selected by viewModel.config.collectAsState()
                                app.hapi.companion.feature.assistant.AssistantPresetSwitch(assistantProfile.modelPresets,
                                    { preset -> selected.model == preset.model || (selected.model != null && preset.model.startsWith(selected.model + "-") && selected.effort == preset.effort) },
                                    { viewModel.setModelPreset(it.model,it.effort) })
                            }
                        },
                        state = composerState,
                        onTextChange = viewModel::onComposerChange,
                        onSend = { viewModel.sendMessage(steer = assistantProfile != null && composerState.canSteer) },
                        onSendSteer = { viewModel.sendMessage(steer = true) },
                        onAbort = viewModel::abortSession,
                        attachments = attachmentItems,
                        onAddAttachment = { attachmentSheetOpen = true },
                        onAttachmentRetry = viewModel.attachments::retry,
                        onAttachmentRemove = viewModel.attachments::remove,
                        slashSuggestions = slashSuggestions,
                        onSlashCommandSelected = viewModel::selectSlashCommand,
                        mentionSuggestions = mentionSuggestions,
                        onMentionSelected = viewModel::selectMentionSuggestion,
                        pendingSchedule = pendingSchedule,
                        onScheduleSelected = viewModel::setPendingSchedule,
                        onClearSchedule = { viewModel.setPendingSchedule(null) },
                        dictation = if (dictationAvailable) dictationState else null,
                        onDictationToggle = onDictationToggle,
                        onDictationCancel = { dictation?.cancel() },
                    )
                }
            }
        },
    ) { padding ->
        CompositionLocalProvider(
            LocalMarkdownRenderCache provides viewModel.markdownCache,
            LocalChatMedia provides media,
            LocalMarkdownLinkHandler provides rememberChatLinkHandler(onOpenFile = onOpenFile),
            LocalChatInteractions provides interactions,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                Box(modifier = Modifier.weight(1f)) {
                    when {
                        state.isInitialLoading -> InitialLoading()
                        state.loadFailed -> LoadFailed(onRetry = viewModel::retry)
                        state.blocks.isEmpty() && !state.hasMore -> EmptyChat()
                        else -> ChatTranscript(
                            state = state, paging = historyPaging, jumpToken = jumpToken,
                            jumpingLatest = jumpingLatest,
                            onViewport = viewModel::readingViewportChanged,
                            onLayout = viewModel::historyLaidOut,
                            foreground = foreground, onTailDisplayed = viewModel::markDisplayed,
                            onRetryHistory = viewModel::loadOlder,
                            onJumpToLatest = viewModel::jumpToLatest,
                            listState = transcriptList, readingState = readingState,
                            messageAggregates = state.messageAggregates,
                            onShowMessageInfo = { messageInfoBlock = it },
                        )
                    }
                    if (!state.loadFailed) state.warning?.let { warning ->
                        Box(Modifier.align(Alignment.TopCenter).padding(8.dp)) {
                            DegradedBanner(warning, viewModel::retry)
                        }
                    }
                }
            }
        }
    }

    }
    if (attachmentSheetOpen) {
        AttachmentPickerSheet(
            onDismiss = { attachmentSheetOpen = false },
            onPickPhotos = {
                photoPickerLauncher.launch(
                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo),
                )
            },
            onTakePhoto = onTakePhoto,
            onPickFiles = { documentPickerLauncher.launch(arrayOf("*/*")) },
        )
    }
    if (configSheetOpen) {
        SessionConfigSheet(
            config = configState,
            onDismiss = { configSheetOpen = false },
            onSetPermissionMode = viewModel::setPermissionMode,
            onSetModel = viewModel::setModel,
            onSetEffort = viewModel::setEffort,
            onLoadModelOptions = viewModel::loadModelOptions,
        )
    }
    if (renameDialogOpen) {
        RenameSessionDialog(
            initialName = state.header.name ?: state.header.title,
            onConfirm = { name ->
                renameDialogOpen = false
                viewModel.renameSession(name)
            },
            onDismiss = { renameDialogOpen = false },
        )
    }
    if (deleteDialogOpen) {
        DeleteSessionDialog(
            sessionTitle = state.header.title,
            onConfirm = {
                deleteDialogOpen = false
                viewModel.deleteSession()
            },
            onDismiss = { deleteDialogOpen = false },
        )
    }
    messageInfoBlock?.let { infoBlock ->
        val labels = remember(infoBlock, state.messageAggregates) {
            messageMetadataForBlock(infoBlock, state.messageAggregates)
                ?.let(::buildMessageMetadataLabels)
                .orEmpty()
        }
        if (labels.isNotEmpty()) {
            MessageMetadataDialog(
                labels = labels,
                onDismiss = { messageInfoBlock = null },
            )
        }
    }
    editingSceneDraft?.let { draft ->
        app.hapi.companion.feature.assistant.ScenarioEditorDialog(
            initial = draft.toQuickAction(),
            onDismiss = { editingSceneDraft = null },
            onSave = { updated -> saveQuickAction(updated) },
        )
    }
    }
}

/**
 * Top-bar ⋮ menu: navigation entries first (Files always, Scratchlist with
 * entry count when enabled), then Rename always; Reopen only for inactive
 * sessions; Delete last.
 */
@Composable
private fun SessionOverflowMenu(
    active: Boolean,
    onRename: () -> Unit,
    onReopen: () -> Unit,
    onDelete: () -> Unit,
    onOpenFiles: () -> Unit = {},
    /** Entry-count suffix on the scratchlist row. */
    scratchlistCount: Int = 0,
    /** null ⇒ scratchlist row hidden (feature off / tests). */
    onOpenScratchlist: (() -> Unit)? = null,
    /** null ⇒ hidden (scratchlist off or empty composer). */
    onParkDraft: (() -> Unit)? = null,
) {
    var open by remember { mutableStateOf(false) }
    IconButton(onClick = { open = true }) {
        Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.chat_session_actions))
    }
    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
        DropdownMenuItem(
            text = { Text(stringResource(R.string.chat_open_files)) },
            leadingIcon = { Icon(FolderGlyph, contentDescription = null) },
            onClick = {
                open = false
                onOpenFiles()
            },
        )
        if (onOpenScratchlist != null) {
            DropdownMenuItem(
                text = {
                    Text(
                        if (scratchlistCount > 0) {
                            stringResource(R.string.chat_open_scratchlist_count, scratchlistCount)
                        } else {
                            stringResource(R.string.chat_open_scratchlist)
                        },
                    )
                },
                onClick = {
                    open = false
                    onOpenScratchlist()
                },
            )
        }
        HorizontalDivider()
        DropdownMenuItem(
            text = { Text(stringResource(R.string.sessions_action_rename)) },
            onClick = {
                open = false
                onRename()
            },
        )
        if (onParkDraft != null) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.chat_park_draft)) },
                onClick = {
                    open = false
                    onParkDraft()
                },
            )
        }
        if (!active) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.sessions_action_reopen)) },
                onClick = {
                    open = false
                    onReopen()
                },
            )
        }
        DropdownMenuItem(
            text = { Text(stringResource(R.string.sessions_action_delete), color = MaterialTheme.colorScheme.error) },
            onClick = {
                open = false
                onDelete()
            },
        )
    }
}

/**
 * Inactive-session affordance above the composer: sending auto-resumes
 * (B-M3ab), Reopen is the explicit restart without a message.
 */
@Composable
private fun InactiveSessionBar(onReopen: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = stringResource(R.string.chat_inactive_bar),
                style = MaterialTheme.typography.labelMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .weight(1f)
                    .padding(start = 16.dp, top = 4.dp, bottom = 4.dp),
            )
            TextButton(onClick = onReopen) { Text(stringResource(R.string.sessions_action_reopen)) }
        }
    }
}

@Composable
private fun ChatTitle(header: ChatHeaderUi, reconnecting: Boolean, retry: () -> Unit) {
    Column(Modifier.heightIn(min = 48.dp).then(if (reconnecting) Modifier.clickable(onClick = retry) else Modifier),
        verticalArrangement = Arrangement.Center) {
        Text(header.title, style = MaterialTheme.typography.titleMedium, maxLines = if (app.hapi.companion.di.LocalClientProfile.current?.mode == "assistant") 3 else 1, overflow = TextOverflow.Ellipsis)
        // Developer subtitles keep their existing slot.
        if (app.hapi.companion.di.LocalClientProfile.current?.mode != "assistant" || reconnecting) Text(
            if (reconnecting) stringResource(R.string.chat_reconnecting_retry) else header.subtitle.orEmpty(),
            style = app.hapi.companion.ui.theme.HapiTypography.caption,
            color = if (reconnecting) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun DegradedBanner(warning: String, onRetry: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.errorContainer,
        contentColor = MaterialTheme.colorScheme.onErrorContainer,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = warning,
                style = MaterialTheme.typography.labelMedium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .weight(1f)
                    .padding(start = 16.dp, top = 6.dp, bottom = 6.dp),
            )
            TextButton(onClick = onRetry) { Text(stringResource(R.string.chat_retry)) }
        }
    }
}

// ----------------------------------------------------------------- states --

@Composable
private fun InitialLoading() {
    Column(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CircularProgressIndicator()
        Spacer(modifier = Modifier.size(12.dp))
        Text(
            text = stringResource(R.string.chat_loading_messages),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun LoadFailed(onRetry: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(text = stringResource(R.string.chat_load_failed_title), style = MaterialTheme.typography.titleMedium)
        Spacer(modifier = Modifier.size(8.dp))
        Text(
            text = stringResource(R.string.chat_load_failed_hint),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.size(12.dp))
        TextButton(onClick = onRetry) { Text(stringResource(R.string.chat_retry)) }
    }
}

@Composable
private fun EmptyChat() {
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(text = stringResource(R.string.chat_empty_title), style = MaterialTheme.typography.titleMedium)
        Spacer(modifier = Modifier.size(8.dp))
        Text(
            text = stringResource(R.string.chat_empty_hint),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// ------------------------------------------------------------- notices --

/**
 * Localize a [ChatNotice] (B-M5a). Server/exception detail text, when
 * present, is shown verbatim — matching the pre-i18n `message ?: fallback`
 * behavior — so hub-side wording is never mistranslated.
 */
internal fun chatNoticeText(context: Context, notice: ChatNotice): String = when (notice) {
    ChatNotice.DraftParked -> context.getString(R.string.chat_notice_draft_parked)
    ChatNotice.ScratchlistFull -> context.getString(R.string.chat_notice_scratchlist_full)
    ChatNotice.ScratchlistParkFailed -> context.getString(R.string.chat_notice_park_failed)
    ChatNotice.AttachmentsUploading -> context.getString(R.string.chat_notice_attachments_uploading)
    ChatNotice.ResumeFailed -> context.getString(R.string.chat_notice_resume_failed)
    ChatNotice.QueuedEditKeptDraft -> context.getString(R.string.chat_notice_edit_kept_draft)
    ChatNotice.QueuedEditScheduleDropped -> context.getString(R.string.chat_notice_edit_schedule_dropped)
    ChatNotice.ScheduleAttachmentConflict -> context.getString(R.string.chat_notice_schedule_attachment_conflict)
    ChatNotice.QueuedAlreadyDelivered -> context.getString(R.string.chat_notice_already_delivered)
    ChatNotice.PermissionAlreadyHandled -> context.getString(R.string.chat_notice_request_already_handled)
    ChatNotice.DeleteConflictActive -> context.getString(R.string.sessions_error_delete_active)
    is ChatNotice.AbortFailed -> notice.detail ?: context.getString(R.string.chat_notice_abort_failed)
    is ChatNotice.RenameFailed -> notice.detail ?: context.getString(R.string.chat_notice_rename_failed)
    is ChatNotice.DeleteFailed -> notice.detail ?: context.getString(R.string.chat_notice_delete_failed)
    is ChatNotice.ReopenFailed -> notice.detail ?: context.getString(R.string.sessions_reopen_failed_fallback)
    is ChatNotice.CancelQueuedFailed -> notice.detail ?: context.getString(R.string.chat_notice_cancel_failed)
    is ChatNotice.SteerFailed -> notice.detail ?: context.getString(R.string.chat_notice_steer_failed)
    is ChatNotice.PermissionRequestFailed -> notice.detail ?: context.getString(R.string.chat_notice_request_failed)
    is ChatNotice.ModelsLoadFailed -> notice.detail ?: context.getString(R.string.chat_notice_models_failed)
    is ChatNotice.ReadStateFailed -> notice.detail ?: context.getString(R.string.chat_notice_read_state_failed)
    is ChatNotice.ConfigUpdateFailed -> notice.detail ?: context.getString(R.string.chat_notice_config_failed)
}
