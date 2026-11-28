package app.hapi.companion.feature.assistant

import android.content.ClipData
import android.content.ComponentName
import android.content.ContentValues
import android.content.Intent
import android.os.Build
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.FolderZip
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.TableChart
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import app.hapi.companion.MainActivity
import app.hapi.data.api.HapiApi
import app.hapi.data.casefiles.SafeCaseZip
import app.hapi.data.casefiles.needsSelectionZip
import app.hapi.data.casefiles.packageSelection
import app.hapi.data.casefiles.safeCaseName
import app.hapi.data.casefiles.selectionZipName
import app.hapi.protocol.wire.CaseFile
import coil.compose.AsyncImage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

internal data class CaseFilesAccess(val files: List<CaseFile>, val open: () -> Unit)
internal val LocalCaseFiles = staticCompositionLocalOf { CaseFilesAccess(emptyList(), {}) }

@Composable
internal fun CaseFilesCapsule(
    files: List<CaseFile>,
    open: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = assistantPalette()
    Surface(
        onClick = open,
        modifier = modifier
            .padding(bottom = 6.dp)
            .pointerInput(open) {
                var drag = 0f
                detectVerticalDragGestures(
                    onDragStart = { drag = 0f },
                    onVerticalDrag = { change, dy ->
                        change.consume()
                        drag += dy
                    },
                    onDragEnd = { if (drag < -24.dp.toPx()) open() },
                )
            },
        shape = CircleShape,
        color = palette.surface,
        border = BorderStroke(0.7.dp, palette.accentBorder),
        shadowElevation = if (palette.isDark) 4.dp else 2.dp,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp),
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
        ) {
            Icon(
                imageVector = Icons.Default.Folder,
                contentDescription = null,
                tint = palette.accent,
                modifier = Modifier.size(15.dp),
            )
            Text(
                text = "本案资料 · ${files.size}" + (if (files.any { !it.isUpload && it.isPdf }) " 含报告" else "") + " ▴",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = palette.ink,
                maxLines = 1,
            )
        }
    }
}

internal fun primaryReport(files: List<CaseFile>) =
    files.filter { !it.isUpload && it.isPdf }
        .sortedBy { if (it.fileName.contains("报告") || it.fileName.contains("尽调")) 0 else 1 }
        .firstOrNull()

private fun mimeFor(name: String) =
    MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.').lowercase())
        ?: "application/octet-stream"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CaseFilesPanel(
    api: HapiApi,
    sessionId: String,
    title: String,
    files: List<CaseFile>,
    dismiss: () -> Unit,
) {
    val palette = assistantPalette()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val root = remember(sessionId) { File(context.cacheDir, "case-files/${UUID.randomUUID()}").apply { mkdirs() } }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var filter by remember { mutableIntStateOf(0) }
    var archive by remember { mutableStateOf<Pair<CaseFile, SafeCaseZip>?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var image by remember { mutableStateOf<File?>(null) }
    val cache = remember { mutableMapOf<String, File>() }

    // Material 1.3.2 hides before invoking onDismissRequest for system back.
    // Veto that hide while browsing ZIP so the callback can pop the inner page.
    val zipOpen = rememberUpdatedState(archive != null)
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = { value -> value != SheetValue.Hidden || !zipOpen.value },
    )

    val deliverablesCount = remember(files) { files.count { !it.isUpload } }
    val uploadsCount = remember(files) { files.count { it.isUpload } }
    val shown = remember(files, filter) { files.filter { filter == 0 || (filter == 2) == it.isUpload } }
    val allShownSelected = shown.isNotEmpty() && shown.all { it.key in selected }
    val mainReport = remember(files) { primaryReport(files) }

    suspend fun materialize(file: CaseFile): File = cache[file.key] ?: withContext(Dispatchers.IO) {
        val dir = File(root, UUID.randomUUID().toString()).apply { mkdirs() }
        File(dir, safeCaseName(file.fileName)).apply {
            writeBytes(api.getCaseFile(sessionId, file).bytes)
        }.also { cache[file.key] = it }
    }

    fun task(action: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = null
        scope.launch {
            try {
                action()
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                error = e.message ?: "操作未完成，请重试"
            } finally {
                busy = false
            }
        }
    }

    fun preview(file: File, mime: String) {
        if (mime.startsWith("image/")) {
            image = file
            return
        }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.attachments", file, file.name)
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val chooser = Intent.createChooser(view, "预览资料")
            .putExtra(Intent.EXTRA_EXCLUDE_COMPONENTS, arrayOf(ComponentName(context, MainActivity::class.java)))
        context.startActivity(chooser)
    }

    suspend fun share(items: List<Pair<File, String>>) {
        if (items.isEmpty()) error("请先选择资料")
        val output = withContext(Dispatchers.IO) {
            if (needsSelectionZip(items.map { it.second })) {
                listOf(
                    packageSelection(
                        items.map { it.first },
                        File(File(root, UUID.randomUUID().toString()).apply { mkdirs() }, selectionZipName(title, items.size)),
                    ) to "application/zip",
                )
            } else {
                items
            }
        }
        val uris = ArrayList(output.map { FileProvider.getUriForFile(context, "${context.packageName}.attachments", it.first, it.first.name) })
        val intent = Intent(if (output.size > 1) Intent.ACTION_SEND_MULTIPLE else Intent.ACTION_SEND).apply {
            type = if (output.all { it.second.startsWith("image/") }) "image/*" else output.first().second
            if (output.size > 1) putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris) else putExtra(Intent.EXTRA_STREAM, uris.first())
            clipData = ClipData.newRawUri("本案资料", uris.first()).also { clip ->
                uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, "转发本案资料"))
    }

    suspend fun chosen(): List<Pair<File, String>> {
        val zip = archive
        return if (zip != null) {
            withContext(Dispatchers.IO) {
                zip.second.members.filter { it.name in selected }.map { member ->
                    zip.second.extract(member, File(root, UUID.randomUUID().toString())) to mimeFor(member.name)
                }
            }
        } else {
            files.filter { it.key in selected }.map { materialize(it) to it.mimeType }
        }
    }

    suspend fun save(items: List<Pair<File, String>>) {
        require(items.isNotEmpty()) { "没有可保存的资料" }
        if (Build.VERSION.SDK_INT < 29) error("此系统请使用转发后选择文件应用保存")
        withContext(Dispatchers.IO) {
            items.forEach { (file, mime) ->
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, safeCaseName(file.name))
                    put(MediaStore.Downloads.MIME_TYPE, mime)
                    put(MediaStore.Downloads.RELATIVE_PATH, "Download/琪琪工作/")
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = requireNotNull(context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values))
                try {
                    requireNotNull(context.contentResolver.openOutputStream(uri)).use { out ->
                        file.inputStream().use { it.copyTo(out) }
                    }
                    context.contentResolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                } catch (e: Exception) {
                    context.contentResolver.delete(uri, null, null)
                    throw e
                }
            }
        }
        Toast.makeText(context, "已保存 ${items.size} 份至 Download/琪琪工作/", Toast.LENGTH_LONG).show()
    }

    fun back() {
        archive = null
        selected = emptySet()
        error = null
    }

    ModalBottomSheet(
        onDismissRequest = {
            if (archive != null) {
                back()
                scope.launch { sheetState.show() }
            } else {
                dismiss()
            }
        },
        sheetState = sheetState,
        containerColor = palette.background,
        contentColor = palette.ink,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .fillMaxHeight(0.90f)
                .navigationBarsPadding(),
        ) {
            // Header
            Column(modifier = Modifier.padding(horizontal = 18.dp)) {
                val zip = archive
                if (zip == null) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(
                                text = "本案资料",
                                fontSize = 20.sp,
                                fontWeight = FontWeight.Bold,
                                color = palette.ink,
                            )
                            Text(
                                text = "${files.size}",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = palette.inkSecondary,
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(palette.surfaceMuted)
                                    .padding(horizontal = 8.dp, vertical = 2.5.dp),
                            )
                        }
                        Spacer(Modifier.weight(1f))
                        if (shown.isNotEmpty()) {
                            Surface(
                                onClick = {
                                    selected = if (allShownSelected) {
                                        selected - shown.map { it.key }.toSet()
                                    } else {
                                        selected + shown.map { it.key }
                                    }
                                },
                                shape = CircleShape,
                                color = palette.surfaceMuted,
                            ) {
                                Text(
                                    text = if (allShownSelected) "取消全选" else "全选",
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Medium,
                                    color = palette.ink,
                                    modifier = Modifier.padding(horizontal = 11.dp, vertical = 6.dp),
                                )
                            }
                        }
                    }

                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 12.dp, bottom = 12.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        CaseFilterPill("全部", files.size, active = filter == 0) { filter = 0 }
                        CaseFilterPill("报告与证据", deliverablesCount, active = filter == 1) { filter = 1 }
                        CaseFilterPill("送审原件", uploadsCount, active = filter == 2) { filter = 2 }
                    }
                } else {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier.padding(bottom = 12.dp),
                    ) {
                        FormatBadge(zip.first.fileName, "application/zip")
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = zip.first.fileName,
                                fontSize = 16.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = palette.ink,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                text = "共 ${zip.second.members.size} 份资料",
                                fontSize = 12.sp,
                                color = palette.inkMuted,
                            )
                        }
                    }
                }
            }

            if (busy) {
                LinearProgressIndicator(
                    color = palette.accent,
                    trackColor = palette.surfaceMuted,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            error?.let {
                Text(
                    text = it,
                    color = palette.report,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 6.dp),
                )
            }

            LazyColumn(
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                val zip = archive
                if (zip != null) {
                    item(key = "zip-card") {
                        Surface(
                            shape = RoundedCornerShape(16.dp),
                            color = palette.surface,
                            border = BorderStroke(0.5.dp, palette.border),
                        ) {
                            Column {
                                zip.second.members.forEachIndexed { idx, member ->
                                    if (idx > 0) {
                                        HorizontalDivider(
                                            modifier = Modifier.padding(start = 56.dp),
                                            thickness = 0.5.dp,
                                            color = palette.border,
                                        )
                                    }
                                    CaseFileListRow(
                                        name = member.name,
                                        mime = mimeFor(member.name),
                                        detail = formatByteSize(member.size),
                                        isPrimaryReport = false,
                                        checked = member.name in selected,
                                        isContainer = false,
                                        onToggle = {
                                            selected = if (member.name in selected) selected - member.name else selected + member.name
                                        },
                                        onOpen = {
                                            task {
                                                val extracted = withContext(Dispatchers.IO) {
                                                    zip.second.extract(member, File(root, UUID.randomUUID().toString()))
                                                }
                                                preview(extracted, mimeFor(member.name))
                                            }
                                        },
                                    )
                                }
                            }
                        }
                    }
                } else {
                    val groups = if (filter == 0) listOf(false, true) else listOf(filter == 2)
                    groups.forEach { uploads ->
                        val visible = files.filter { it.isUpload == uploads }
                        if (visible.isNotEmpty()) {
                            item(key = "group-$uploads") {
                                Text(
                                    text = if (uploads) "送审原件" else "报告与证据",
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = palette.inkMuted,
                                    modifier = Modifier.padding(start = 4.dp, top = 4.dp),
                                )
                            }
                            val docs = visible
                                .filter { !it.isImage }
                                .sortedBy { if (it.key == mainReport?.key) 0 else 1 }
                            if (docs.isNotEmpty()) {
                                item(key = "docs-$uploads") {
                                    Surface(
                                        shape = RoundedCornerShape(16.dp),
                                        color = palette.surface,
                                        border = BorderStroke(0.5.dp, palette.border),
                                    ) {
                                        Column {
                                            docs.forEachIndexed { idx, file ->
                                                if (idx > 0) {
                                                    HorizontalDivider(
                                                        modifier = Modifier.padding(start = 56.dp),
                                                        thickness = 0.5.dp,
                                                        color = palette.border,
                                                    )
                                                }
                                                CaseFileListRow(
                                                    name = file.fileName,
                                                    mime = file.mimeType,
                                                    detail = formatByteSize(file.size),
                                                    isPrimaryReport = file.key == mainReport?.key,
                                                    checked = file.key in selected,
                                                    isContainer = file.isZip,
                                                    onToggle = {
                                                        selected = if (file.key in selected) selected - file.key else selected + file.key
                                                    },
                                                    onOpen = {
                                                        task {
                                                            val local = materialize(file)
                                                            if (file.isZip) {
                                                                val parsed = withContext(Dispatchers.IO) { SafeCaseZip(local) }
                                                                archive = file to parsed
                                                                selected = emptySet()
                                                            } else {
                                                                preview(local, file.mimeType)
                                                            }
                                                        }
                                                    },
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                            items(
                                visible.filter { it.isImage }.chunked(3),
                                key = { "images-" + it.first().key },
                            ) { row ->
                                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    row.forEach { file ->
                                        val isChecked = file.key in selected
                                        var thumb by remember(file.key) { mutableStateOf<File?>(null) }
                                        LaunchedEffect(file.key) {
                                            runCatching { materialize(file) }.onSuccess { thumb = it }
                                        }
                                        Surface(
                                            shape = RoundedCornerShape(12.dp),
                                            color = palette.surfaceMuted,
                                            border = BorderStroke(
                                                width = if (isChecked) 1.5.dp else 0.5.dp,
                                                color = if (isChecked) palette.accent else palette.border,
                                            ),
                                            modifier = Modifier
                                                .weight(1f)
                                                .aspectRatio(1.12f),
                                        ) {
                                            Box {
                                                AsyncImage(
                                                    model = thumb,
                                                    contentDescription = "预览 ${file.fileName}",
                                                    contentScale = ContentScale.Crop,
                                                    modifier = Modifier
                                                        .fillMaxSize()
                                                        .clickable { task { image = materialize(file) } },
                                                )
                                                CaseCheckBadge(
                                                    checked = isChecked,
                                                    onToggle = {
                                                        selected = if (isChecked) selected - file.key else selected + file.key
                                                    },
                                                    onImage = true,
                                                    modifier = Modifier
                                                        .align(Alignment.TopEnd)
                                                        .padding(4.dp),
                                                )
                                            }
                                        }
                                    }
                                    repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                                }
                            }
                        }
                    }
                }
            }

            // Bottom action bar
            HorizontalDivider(thickness = 0.5.dp, color = palette.border)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(palette.background)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (archive != null) {
                    CompactSheetButton("返回", Icons.Default.ChevronLeft, enabled = !busy) { back() }
                }
                CompactSheetButton("存文件", Icons.Default.ArrowDownward, enabled = !busy && files.isNotEmpty()) {
                    task {
                        save(
                            if (selected.isNotEmpty()) chosen()
                            else if (archive != null) listOf(materialize(archive!!.first) to "application/zip")
                            else shown.map { materialize(it) to it.mimeType },
                        )
                    }
                }
                if (selected.isEmpty() && archive == null) {
                    files.firstOrNull { it.isZip }?.let { zipFile ->
                        CompactSheetButton("整包 ZIP", Icons.Default.FolderZip, enabled = !busy) {
                            task { share(listOf(materialize(zipFile) to "application/zip")) }
                        }
                    }
                }

                val primaryEnabled = !busy && (selected.isNotEmpty() || archive != null || mainReport != null)
                val primaryLabel = when {
                    selected.isNotEmpty() -> "转发已选 (${selected.size})"
                    archive != null -> "整包转发"
                    else -> "转发尽调报告"
                }
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(44.dp)
                        .clip(CircleShape)
                        .then(
                            if (primaryEnabled) Modifier.background(palette.accentGradient)
                            else Modifier.background(palette.surfaceMuted),
                        )
                        .clickable(enabled = primaryEnabled) {
                            task {
                                share(
                                    if (selected.isNotEmpty()) chosen()
                                    else if (archive != null) listOf(materialize(archive!!.first) to "application/zip")
                                    else listOfNotNull(mainReport).map { materialize(it) to it.mimeType },
                                )
                            }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        modifier = Modifier.padding(horizontal = 12.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Default.Share,
                            contentDescription = null,
                            tint = if (primaryEnabled) Color.White else palette.inkMuted,
                            modifier = Modifier.size(16.dp),
                        )
                        Text(
                            text = primaryLabel,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = if (primaryEnabled) Color.White else palette.inkMuted,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }

    image?.let { file ->
        Dialog(
            onDismissRequest = { image = null },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            var scale by remember { mutableFloatStateOf(1f) }
            var x by remember { mutableFloatStateOf(0f) }
            var y by remember { mutableFloatStateOf(0f) }
            Box(Modifier.fillMaxSize().background(Color.Black)) {
                AsyncImage(
                    model = file,
                    contentDescription = "双指缩放图片",
                    modifier = Modifier
                        .fillMaxSize()
                        .pointerInput(file) {
                            detectTransformGestures { _, pan, zoom, _ ->
                                scale = (scale * zoom).coerceIn(1f, 8f)
                                x += pan.x
                                y += pan.y
                            }
                        }
                        .graphicsLayer(scaleX = scale, scaleY = scale, translationX = x, translationY = y),
                )
                TextButton(
                    onClick = { image = null },
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding(),
                ) {
                    Text("关闭图片", color = Color.White)
                }
            }
        }
    }
}

@Composable
private fun CaseFilterPill(
    title: String,
    count: Int,
    active: Boolean,
    onClick: () -> Unit,
) {
    val palette = assistantPalette()
    Surface(
        onClick = onClick,
        shape = CircleShape,
        color = if (active) palette.ink else palette.surfaceMuted,
        contentColor = if (active) palette.inkOnSolid else palette.inkSecondary,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = title,
                fontSize = 12.5.sp,
                fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
                maxLines = 1,
            )
            if (count > 0) {
                Text(
                    text = "$count",
                    fontSize = 12.sp,
                    color = (if (active) palette.inkOnSolid else palette.inkSecondary).copy(alpha = if (active) 0.85f else 0.65f),
                )
            }
        }
    }
}

@Composable
private fun CompactSheetButton(
    title: String,
    icon: ImageVector,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val palette = assistantPalette()
    Surface(
        onClick = onClick,
        enabled = enabled,
        shape = CircleShape,
        color = palette.surface,
        border = BorderStroke(0.5.dp, palette.border),
        modifier = Modifier.height(44.dp),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (enabled) palette.ink else palette.inkMuted,
                modifier = Modifier.size(15.dp),
            )
            Text(
                text = title,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = if (enabled) palette.ink else palette.inkMuted,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun CaseFileListRow(
    name: String,
    mime: String,
    detail: String,
    isPrimaryReport: Boolean,
    checked: Boolean,
    isContainer: Boolean,
    onToggle: () -> Unit,
    onOpen: () -> Unit,
) {
    val palette = assistantPalette()
    val extTag = name.substringAfterLast('.', "").uppercase().let {
        when {
            it.isEmpty() -> ""
            it == "DOCX" -> "DOC"
            it == "XLSX" -> "XLS"
            else -> it.take(4)
        }
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(if (checked) palette.accent.copy(alpha = 0.05f) else Color.Transparent)
            .clickable(onClick = onOpen)
            .padding(horizontal = 10.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        CaseCheckBadge(checked = checked, onToggle = onToggle, onImage = false)
        FormatBadge(name, mime, highlighted = isPrimaryReport)
        Column(
            modifier = Modifier
                .weight(1f)
                .heightIn(min = 38.dp),
            verticalArrangement = Arrangement.Center,
        ) {
            Text(
                text = name,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = palette.ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.padding(top = 2.dp),
            ) {
                if (isPrimaryReport) {
                    Text(
                        text = "主报告",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = palette.accent,
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(palette.accentSoft)
                            .padding(horizontal = 6.dp, vertical = 1.dp),
                    )
                } else if (extTag.isNotEmpty()) {
                    Text(
                        text = extTag,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = palette.inkMuted,
                    )
                }
                Text(
                    text = detail,
                    fontSize = 11.5.sp,
                    color = palette.inkMuted,
                    maxLines = 1,
                )
            }
        }
        if (isContainer) {
            Icon(
                imageVector = Icons.Default.ChevronRight,
                contentDescription = "展开",
                tint = palette.inkMuted,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
internal fun FormatBadge(
    name: String,
    mime: String,
    compact: Boolean = false,
    highlighted: Boolean = false,
) {
    val palette = assistantPalette()
    val ext = name.substringAfterLast('.', "").lowercase()
    val icon = when {
        ext in listOf("zip", "rar", "7z", "tar", "gz") -> Icons.Default.FolderZip
        ext in listOf("xls", "xlsx", "csv") -> Icons.Default.TableChart
        ext in listOf("jpg", "jpeg", "png", "heic", "webp") || mime.startsWith("image/") -> Icons.Default.Image
        ext == "pdf" -> Icons.Default.PictureAsPdf
        else -> Icons.Default.Description
    }
    Box(
        modifier = Modifier
            .size(if (compact) 32.dp else 36.dp)
            .clip(RoundedCornerShape(if (compact) 8.dp else 10.dp))
            .background(if (highlighted) palette.accentSoft else palette.surfaceMuted),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (highlighted) palette.accent else palette.inkSecondary,
            modifier = Modifier.size(if (compact) 16.dp else 18.dp),
        )
    }
}

@Composable
private fun CaseCheckBadge(
    checked: Boolean,
    onToggle: () -> Unit,
    onImage: Boolean,
    modifier: Modifier = Modifier,
) {
    val palette = assistantPalette()
    Box(
        modifier = modifier
            .size(if (onImage) 30.dp else 34.dp)
            .clickable(role = Role.Checkbox, onClick = onToggle),
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            shape = CircleShape,
            color = when {
                checked -> palette.accent
                onImage -> Color.Black.copy(alpha = 0.35f)
                else -> Color.Transparent
            },
            border = BorderStroke(
                width = 1.6.dp,
                color = when {
                    checked -> palette.accent
                    onImage -> Color.White.copy(alpha = 0.9f)
                    else -> palette.inkMuted.copy(alpha = 0.45f)
                },
            ),
            modifier = Modifier.size(21.dp),
        ) {
            if (checked) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = Icons.Default.Check,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
        }
    }
}
