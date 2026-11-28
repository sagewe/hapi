package app.hapi.companion.feature.assistant

import android.content.ClipData
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.FolderZip
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.TableChart
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
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

internal data class CaseFilesAccess(
    val files: List<CaseFile>,
    val open: () -> Unit,
    val openZip: (String) -> Unit = { open() },
)

internal val LocalCaseFiles = staticCompositionLocalOf { CaseFilesAccess(emptyList(), {}) }

internal fun reportCandidates(files: List<CaseFile>): List<CaseFile> {
    val pdfs = files.filter { !it.isUpload && it.isPdf }
    val named = pdfs.filter { f ->
        listOf("报告", "尽调", "report", "纪要", "核查").any { f.fileName.contains(it, ignoreCase = true) }
    }
    val pool = named.ifEmpty { pdfs }
    return pool.sortedWith(compareByDescending<CaseFile> { it.createdAt }.thenByDescending { it.id })
}

internal fun primaryReport(files: List<CaseFile>): CaseFile? = reportCandidates(files).firstOrNull()

internal fun caseDiskCacheFile(context: Context, sessionId: String, fileId: String, fileName: String): File {
    val safeSess = sessionId.replace(Regex("[^A-Za-z0-9_-]"), "_").take(80).ifEmpty { "case" }
    val safeId = fileId.replace(Regex("[^A-Za-z0-9_-]"), "_").take(80).ifEmpty { "file" }
    val dir = File(context.cacheDir, "qiqi-case-files/$safeSess/$safeId")
    return File(dir, safeCaseName(fileName))
}

internal suspend fun renderPdfCoverBitmap(file: File, width: Int = 120, height: Int = 160): Bitmap? =
    withContext(Dispatchers.IO) {
        runCatching {
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { pfd ->
                PdfRenderer(pfd).use { renderer ->
                    if (renderer.pageCount <= 0) return@runCatching null
                    renderer.openPage(0).use { page ->
                        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                        bitmap.eraseColor(android.graphics.Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        bitmap
                    }
                }
            }
        }.getOrNull()
    }

private fun mimeFor(name: String) =
    MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.').lowercase())
        ?: "application/octet-stream"

private fun cleanImageCaption(name: String): String? {
    val stem = name.substringBeforeLast('.')
    val lower = stem.lowercase()
    if (lower.startsWith("photo-") || lower.startsWith("camera-") || lower.startsWith("img_") || lower.startsWith("pxl_") || lower.startsWith("screenshot_")) {
        return null
    }
    return stem.trim().ifEmpty { null }
}

private data class GalleryImageItem(val id: String, val title: String, val subtitle: String, val file: File, val mime: String)
private data class GalleryState(val items: List<GalleryImageItem>, val startIndex: Int)

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun CaseDossierDrawer(
    api: HapiApi,
    sessionId: String,
    title: String,
    files: List<CaseFile>,
    pendingOpenZipMediaId: String? = null,
    onConsumePendingZip: () -> Unit = {},
    onZipOpenChanged: (Boolean) -> Unit = {},
    popZipSignal: Int = 0,
    onQuoteFile: (String) -> Unit = {},
    onAddFiles: () -> Unit = {},
    onPromoteToScenario: () -> Unit = {},
) {
    val palette = assistantPalette()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val extractRoot = remember(sessionId) { File(context.cacheDir, "case-zip-tmp/$sessionId").apply { mkdirs() } }

    var selecting by remember(sessionId) { mutableStateOf(false) }
    var selected by remember(sessionId) { mutableStateOf(setOf<String>()) }
    var filter by remember(sessionId) { mutableIntStateOf(0) }
    var versionsExpanded by remember(sessionId) { mutableStateOf(false) }
    var archive by remember(sessionId) { mutableStateOf<Pair<CaseFile, SafeCaseZip>?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var gallery by remember { mutableStateOf<GalleryState?>(null) }

    LaunchedEffect(archive != null) { onZipOpenChanged(archive != null) }
    LaunchedEffect(popZipSignal) {
        if (popZipSignal > 0 && archive != null) {
            archive = null
            selecting = false
            selected = emptySet()
            error = null
        }
    }

    val reports = remember(files) { reportCandidates(files) }
    val mainReport = reports.firstOrNull()
    val previousReports = remember(reports) { reports.drop(1) }
    val deliverablesCount = remember(files) { files.count { !it.isUpload } }
    val uploadsCount = remember(files) { files.count { it.isUpload } }
    val shown = remember(files, filter) { files.filter { filter == 0 || (filter == 2) == it.isUpload } }
    val showsHero = !selecting && filter != 2 && mainReport != null
    val heroExcludedKeys = remember(showsHero, reports) {
        if (showsHero) reports.map { it.key }.toSet() else emptySet()
    }

    suspend fun materialize(file: CaseFile): File {
        val target = caseDiskCacheFile(context, sessionId, file.id, file.fileName)
        if (target.isFile && target.length() > 0) return target
        return withContext(Dispatchers.IO) {
            val bytes = api.getCaseFile(sessionId, file).bytes
            target.parentFile?.mkdirs()
            target.writeBytes(bytes)
            target
        }
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

    LaunchedEffect(pendingOpenZipMediaId, files) {
        val targetId = pendingOpenZipMediaId ?: return@LaunchedEffect
        val zipFile = files.firstOrNull { it.id == targetId && it.isZip } ?: files.firstOrNull { it.isZip }
        if (zipFile != null) {
            onConsumePendingZip()
            task {
                val local = materialize(zipFile)
                val parsed = withContext(Dispatchers.IO) { SafeCaseZip(local) }
                archive = zipFile to parsed
                selecting = false
                selected = emptySet()
            }
        }
    }

    fun previewNonImage(file: File, mime: String) {
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
                        File(File(extractRoot, UUID.randomUUID().toString()).apply { mkdirs() }, selectionZipName(title, items.size)),
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

    suspend fun chosen(): List<Pair<File, String>> {
        val zip = archive
        return if (zip != null) {
            withContext(Dispatchers.IO) {
                zip.second.members.filter { it.name in selected }.map { member ->
                    zip.second.extract(member, File(extractRoot, UUID.randomUUID().toString())) to mimeFor(member.name)
                }
            }
        } else {
            files.filter { it.key in selected }.map { materialize(it) to it.mimeType }
        }
    }

    fun openCaseFile(file: CaseFile) {
        task {
            val local = materialize(file)
            if (file.isZip) {
                val parsed = withContext(Dispatchers.IO) { SafeCaseZip(local) }
                archive = file to parsed
                selecting = false
                selected = emptySet()
            } else if (file.isImage) {
                val group = shown.filter { it.isUpload == file.isUpload && it.isImage }
                val idx = group.indexOfFirst { it.key == file.key }.coerceAtLeast(0)
                val items = group.map { f ->
                    GalleryImageItem(f.key, f.fileName, if (f.isUpload) "送审原件" else "交付核验图", materialize(f), f.mimeType)
                }
                gallery = GalleryState(items, idx)
            } else {
                previewNonImage(local, file.mimeType)
            }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(palette.background)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        val zip = archive
        // Header
        Column(modifier = Modifier.padding(horizontal = 14.dp)) {
            if (zip == null) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 10.dp, bottom = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (selecting) {
                        Text(
                            text = if (selected.isEmpty()) "选择资料" else "已选 ${selected.size} 项",
                            fontSize = 19.sp,
                            fontWeight = FontWeight.Bold,
                            color = palette.ink,
                        )
                        Spacer(Modifier.weight(1f))
                        val allShown = shown.isNotEmpty() && shown.all { it.key in selected }
                        Surface(
                            onClick = {
                                selected = if (allShown) selected - shown.map { it.key }.toSet() else selected + shown.map { it.key }
                            },
                            shape = CircleShape,
                            color = palette.surfaceMuted,
                        ) {
                            Text(
                                text = if (allShown) "取消全选" else "全选",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = palette.ink,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.5.dp),
                            )
                        }
                        Spacer(Modifier.width(6.dp))
                        Surface(
                            onClick = { selecting = false; selected = emptySet() },
                            shape = CircleShape,
                            color = palette.ink,
                        ) {
                            Text(
                                text = "完成",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = palette.inkOnSolid,
                                modifier = Modifier.padding(horizontal = 11.dp, vertical = 5.5.dp),
                            )
                        }
                    } else {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                            Text("本案卷宗", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = palette.ink)
                            if (files.isNotEmpty()) {
                                Text(
                                    text = "${files.size}",
                                    fontSize = 11.5.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = palette.inkSecondary,
                                    modifier = Modifier
                                        .clip(CircleShape)
                                        .background(palette.surfaceMuted)
                                        .padding(horizontal = 7.5.dp, vertical = 2.dp),
                                )
                            }
                        }
                        Spacer(Modifier.weight(1f))
                        if (files.isNotEmpty()) {
                            Surface(
                                onClick = { selecting = true },
                                shape = CircleShape,
                                color = palette.surfaceMuted,
                            ) {
                                Text(
                                    text = "选择",
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = palette.ink,
                                    modifier = Modifier.padding(horizontal = 11.dp, vertical = 5.5.dp),
                                )
                            }
                        }
                    }
                }

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    CaseFilterPill("全部", files.size, active = filter == 0) { filter = 0 }
                    CaseFilterPill("交付", deliverablesCount, active = filter == 1) { filter = 1 }
                    CaseFilterPill("原件", uploadsCount, active = filter == 2) { filter = 2 }
                }
            } else {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 10.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (selecting) {
                        Text(
                            text = if (selected.isEmpty()) "选择卷内文件" else "已选 ${selected.size} 项",
                            fontSize = 17.sp,
                            fontWeight = FontWeight.Bold,
                            color = palette.ink,
                        )
                        Spacer(Modifier.weight(1f))
                        val allZip = zip.second.members.isNotEmpty() && zip.second.members.all { it.name in selected }
                        Surface(
                            onClick = {
                                selected = if (allZip) emptySet() else zip.second.members.map { it.name }.toSet()
                            },
                            shape = CircleShape,
                            color = palette.surfaceMuted,
                        ) {
                            Text(if (allZip) "取消全选" else "全选", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = palette.ink, modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.5.dp))
                        }
                        Spacer(Modifier.width(6.dp))
                        Surface(
                            onClick = { selecting = false; selected = emptySet() },
                            shape = CircleShape,
                            color = palette.ink,
                        ) {
                            Text("完成", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = palette.inkOnSolid, modifier = Modifier.padding(horizontal = 11.dp, vertical = 5.5.dp))
                        }
                    } else {
                        Row(
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .clickable { archive = null; selected = emptySet(); selecting = false }
                                .padding(vertical = 4.dp, horizontal = 2.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Default.ChevronLeft, null, tint = palette.accent, modifier = Modifier.size(20.dp))
                            Text("本案卷宗", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = palette.accent)
                        }
                        Spacer(Modifier.weight(1f))
                        Surface(
                            onClick = { selecting = true },
                            shape = CircleShape,
                            color = palette.surfaceMuted,
                        ) {
                            Text("选择", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = palette.ink, modifier = Modifier.padding(horizontal = 11.dp, vertical = 5.5.dp))
                        }
                    }
                }
                Text(
                    text = zip.first.fileName,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    color = palette.ink,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = "共 ${zip.second.members.size} 份 · ${formatByteSize(zip.first.size)}",
                    fontSize = 11.5.sp,
                    color = palette.inkMuted,
                    modifier = Modifier.padding(top = 2.dp, bottom = 10.dp),
                )
            }
            HorizontalDivider(thickness = 0.5.dp, color = palette.border)
        }

        if (busy) {
            LinearProgressIndicator(color = palette.accent, trackColor = palette.surfaceMuted, modifier = Modifier.fillMaxWidth())
        }
        error?.let {
            Text(it, color = palette.report, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp))
        }

        LazyColumn(
            modifier = Modifier.weight(1f),
            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (zip != null) {
                val docMembers = zip.second.members.filter { !mimeFor(it.name).startsWith("image/") }
                val imgMembers = zip.second.members.filter { mimeFor(it.name).startsWith("image/") }
                if (docMembers.isNotEmpty()) {
                    item(key = "zip-docs-hdr") {
                        Text("文档", fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = palette.inkMuted, modifier = Modifier.padding(start = 4.dp))
                    }
                    item(key = "zip-docs") {
                        Surface(shape = RoundedCornerShape(15.dp), color = palette.surface, border = BorderStroke(0.5.dp, palette.border)) {
                            Column {
                                docMembers.forEachIndexed { idx, member ->
                                    if (idx > 0) HorizontalDivider(modifier = Modifier.padding(start = if (selecting) 74.dp else 48.dp), thickness = 0.5.dp, color = palette.border)
                                    var menuOpen by remember { mutableStateOf(false) }
                                    val dirTag = member.name.substringBeforeLast('/', "").takeIf { it.isNotEmpty() }?.let { "$it/" }
                                    val baseName = member.name.substringAfterLast('/')
                                    Box {
                                        CaseFileListRow(
                                            name = baseName,
                                            mime = mimeFor(baseName),
                                            detail = formatByteSize(member.size),
                                            directoryTag = dirTag,
                                            isPrimaryReport = false,
                                            selecting = selecting,
                                            checked = member.name in selected,
                                            isContainer = false,
                                            onToggle = { selected = if (member.name in selected) selected - member.name else selected + member.name },
                                            onOpen = {
                                                if (selecting) selected = if (member.name in selected) selected - member.name else selected + member.name
                                                else task {
                                                    val ex = withContext(Dispatchers.IO) { zip.second.extract(member, File(extractRoot, UUID.randomUUID().toString())) }
                                                    previewNonImage(ex, mimeFor(baseName))
                                                }
                                            },
                                            onLongPress = { menuOpen = true },
                                        )
                                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                                            DropdownMenuItem(text = { Text("引用回对话追问") }, onClick = { menuOpen = false; onQuoteFile(baseName) })
                                            DropdownMenuItem(text = { Text("转发") }, onClick = { menuOpen = false; task { val ex = withContext(Dispatchers.IO) { zip.second.extract(member, File(extractRoot, UUID.randomUUID().toString())) }; share(listOf(ex to mimeFor(baseName))) } })
                                            DropdownMenuItem(text = { Text("存文件") }, onClick = { menuOpen = false; task { val ex = withContext(Dispatchers.IO) { zip.second.extract(member, File(extractRoot, UUID.randomUUID().toString())) }; save(listOf(ex to mimeFor(baseName))) } })
                                            if (!selecting) DropdownMenuItem(text = { Text("进入多选") }, onClick = { menuOpen = false; selecting = true; selected = selected + member.name })
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if (imgMembers.isNotEmpty()) {
                    item(key = "zip-imgs-hdr") {
                        Text("截图与扫描件", fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = palette.inkMuted, modifier = Modifier.padding(start = 4.dp))
                    }
                    items(imgMembers.chunked(3), key = { "zip-img-" + it.first().name }) { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                            row.forEach { member ->
                                val baseName = member.name.substringAfterLast('/')
                                val isChecked = member.name in selected
                                var thumb by remember(member.name) { mutableStateOf<File?>(null) }
                                LaunchedEffect(member.name) {
                                    runCatching {
                                        withContext(Dispatchers.IO) { zip.second.extract(member, File(extractRoot, UUID.randomUUID().toString())) }
                                    }.onSuccess { thumb = it }
                                }
                                CaseImageTileBox(
                                    file = thumb,
                                    caption = cleanImageCaption(baseName),
                                    selecting = selecting,
                                    checked = isChecked,
                                    modifier = Modifier.weight(1f),
                                    onTap = {
                                        if (selecting) selected = if (isChecked) selected - member.name else selected + member.name
                                        else task {
                                            val allItems = imgMembers.map { m ->
                                                val b = m.name.substringAfterLast('/')
                                                val f = withContext(Dispatchers.IO) { zip.second.extract(m, File(extractRoot, UUID.randomUUID().toString())) }
                                                GalleryImageItem("zip:${m.name}", b, zip.first.fileName, f, mimeFor(b))
                                            }
                                            val idx = imgMembers.indexOfFirst { it.name == member.name }.coerceAtLeast(0)
                                            gallery = GalleryState(allItems, idx)
                                        }
                                    },
                                    onToggle = { selected = if (isChecked) selected - member.name else selected + member.name },
                                    onLongPress = { selecting = true; selected = selected + member.name },
                                )
                            }
                            repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
            } else {
                if (shown.isEmpty()) {
                    item(key = "empty") {
                        Text("报告、核验图和送审原件会集中在这里", fontSize = 13.sp, color = palette.inkMuted, modifier = Modifier.padding(top = 36.dp, start = 6.dp))
                    }
                }

                if (showsHero && mainReport != null) {
                    item(key = "hero-report") {
                        var cover by remember(mainReport.key) { mutableStateOf<Bitmap?>(null) }
                        var menuOpen by remember { mutableStateOf(false) }
                        LaunchedEffect(mainReport.key) {
                            runCatching { renderPdfCoverBitmap(materialize(mainReport), 110, 148) }.onSuccess { cover = it }
                        }
                        Box {
                            Surface(
                                shape = RoundedCornerShape(16.dp),
                                color = palette.surface,
                                border = BorderStroke(1.dp, palette.accentBorder),
                            ) {
                                Column(modifier = Modifier.padding(11.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .combinedClickable(
                                                onClick = { openCaseFile(mainReport) },
                                                onLongClick = { menuOpen = true },
                                            ),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                                    ) {
                                        Box(
                                            modifier = Modifier
                                                .size(width = 46.dp, height = 60.dp)
                                                .clip(RoundedCornerShape(7.dp))
                                                .background(palette.surfaceMuted),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            val bmp = cover
                                            if (bmp != null) {
                                                Image(bmp.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                                            } else {
                                                Icon(Icons.Default.PictureAsPdf, null, tint = palette.accent, modifier = Modifier.size(22.dp))
                                            }
                                        }
                                        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                            Text(
                                                text = mainReport.fileName,
                                                fontSize = 13.5.sp,
                                                fontWeight = FontWeight.SemiBold,
                                                color = palette.ink,
                                                maxLines = 2,
                                                overflow = TextOverflow.Ellipsis,
                                            )
                                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                                Text(
                                                    text = if (previousReports.isEmpty()) "主报告" else "最新主报告",
                                                    fontSize = 10.sp,
                                                    fontWeight = FontWeight.SemiBold,
                                                    color = palette.accent,
                                                    modifier = Modifier
                                                        .clip(CircleShape)
                                                        .background(palette.accentSoft)
                                                        .padding(horizontal = 6.dp, vertical = 1.5.dp),
                                                )
                                                Text(formatByteSize(mainReport.size), fontSize = 11.sp, color = palette.inkMuted)
                                            }
                                        }
                                    }

                                    if (previousReports.isNotEmpty()) {
                                        HorizontalDivider(thickness = 0.5.dp, color = palette.border)
                                        Row(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .clickable { versionsExpanded = !versionsExpanded }
                                                .padding(vertical = 2.dp),
                                            verticalAlignment = Alignment.CenterVertically,
                                        ) {
                                            Text("历史初稿（${previousReports.size} 份）", fontSize = 11.5.sp, color = palette.inkMuted)
                                            Spacer(Modifier.weight(1f))
                                            Icon(
                                                if (versionsExpanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                                                null,
                                                tint = palette.inkMuted,
                                                modifier = Modifier.size(16.dp),
                                            )
                                        }
                                        if (versionsExpanded) {
                                            previousReports.forEach { old ->
                                                Row(
                                                    modifier = Modifier
                                                        .fillMaxWidth()
                                                        .clickable { openCaseFile(old) }
                                                        .padding(vertical = 3.dp),
                                                    verticalAlignment = Alignment.CenterVertically,
                                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                                ) {
                                                    Icon(Icons.Default.PictureAsPdf, null, tint = palette.inkMuted, modifier = Modifier.size(14.dp))
                                                    Text(old.fileName, fontSize = 12.sp, color = palette.inkSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                                                    Text(formatByteSize(old.size), fontSize = 11.sp, color = palette.inkMuted)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                                DropdownMenuItem(text = { Text("引用回对话追问") }, onClick = { menuOpen = false; onQuoteFile(mainReport.fileName) })
                                DropdownMenuItem(text = { Text("预览报告") }, onClick = { menuOpen = false; openCaseFile(mainReport) })
                                DropdownMenuItem(text = { Text("转发报告") }, onClick = { menuOpen = false; task { share(listOf(materialize(mainReport) to mainReport.mimeType)) } })
                                DropdownMenuItem(text = { Text("存文件") }, onClick = { menuOpen = false; task { save(listOf(materialize(mainReport) to mainReport.mimeType)) } })
                                DropdownMenuItem(text = { Text("进入多选") }, onClick = { menuOpen = false; selecting = true; selected = selected + mainReport.key })
                            }
                        }
                    }
                }

                val groups = if (filter == 0) listOf(false, true) else listOf(filter == 2)
                groups.forEach { uploads ->
                    val rawVisible = shown.filter { it.isUpload == uploads }
                    val visible = if (uploads) rawVisible else rawVisible.filter { it.key !in heroExcludedKeys }
                    if (visible.isNotEmpty()) {
                        item(key = "group-$uploads") {
                            Text(
                                text = if (uploads) "送审原件" else "交付与核验",
                                fontSize = 11.5.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = palette.inkMuted,
                                modifier = Modifier.padding(start = 4.dp, top = 4.dp),
                            )
                        }
                        val docs = visible.filter { !it.isImage }.sortedByDescending { it.createdAt }
                        if (docs.isNotEmpty()) {
                            item(key = "docs-$uploads") {
                                Surface(shape = RoundedCornerShape(15.dp), color = palette.surface, border = BorderStroke(0.5.dp, palette.border)) {
                                    Column {
                                        docs.forEachIndexed { idx, file ->
                                            if (idx > 0) HorizontalDivider(modifier = Modifier.padding(start = if (selecting) 74.dp else 48.dp), thickness = 0.5.dp, color = palette.border)
                                            var menuOpen by remember { mutableStateOf(false) }
                                            Box {
                                                CaseFileListRow(
                                                    name = file.fileName,
                                                    mime = file.mimeType,
                                                    detail = formatByteSize(file.size),
                                                    isPrimaryReport = file.key == mainReport?.key,
                                                    selecting = selecting,
                                                    checked = file.key in selected,
                                                    isContainer = file.isZip,
                                                    onToggle = { selected = if (file.key in selected) selected - file.key else selected + file.key },
                                                    onOpen = {
                                                        if (selecting) selected = if (file.key in selected) selected - file.key else selected + file.key
                                                        else openCaseFile(file)
                                                    },
                                                    onLongPress = { menuOpen = true },
                                                )
                                                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                                                    DropdownMenuItem(text = { Text("引用回对话追问") }, onClick = { menuOpen = false; onQuoteFile(file.fileName) })
                                                    DropdownMenuItem(text = { Text(if (file.isZip) "浏览卷内" else "预览") }, onClick = { menuOpen = false; openCaseFile(file) })
                                                    DropdownMenuItem(text = { Text("转发") }, onClick = { menuOpen = false; task { share(listOf(materialize(file) to file.mimeType)) } })
                                                    DropdownMenuItem(text = { Text("存文件") }, onClick = { menuOpen = false; task { save(listOf(materialize(file) to file.mimeType)) } })
                                                    if (!selecting) DropdownMenuItem(text = { Text("进入多选") }, onClick = { menuOpen = false; selecting = true; selected = selected + file.key })
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        val imgs = visible.filter { it.isImage }
                        items(imgs.chunked(3), key = { "imgs-$uploads-" + it.first().key }) { row ->
                            Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                                row.forEach { file ->
                                    val isChecked = file.key in selected
                                    var thumb by remember(file.key) { mutableStateOf<File?>(null) }
                                    var menuOpen by remember { mutableStateOf(false) }
                                    LaunchedEffect(file.key) { runCatching { materialize(file) }.onSuccess { thumb = it } }
                                    Box(modifier = Modifier.weight(1f)) {
                                        CaseImageTileBox(
                                            file = thumb,
                                            caption = cleanImageCaption(file.fileName),
                                            selecting = selecting,
                                            checked = isChecked,
                                            modifier = Modifier.fillMaxWidth(),
                                            onTap = {
                                                if (selecting) selected = if (isChecked) selected - file.key else selected + file.key
                                                else openCaseFile(file)
                                            },
                                            onToggle = { selected = if (isChecked) selected - file.key else selected + file.key },
                                            onLongPress = { menuOpen = true },
                                        )
                                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                                            DropdownMenuItem(text = { Text("引用回对话追问") }, onClick = { menuOpen = false; onQuoteFile(file.fileName) })
                                            DropdownMenuItem(text = { Text("转发此图") }, onClick = { menuOpen = false; task { share(listOf(materialize(file) to file.mimeType)) } })
                                            DropdownMenuItem(text = { Text("保存图片") }, onClick = { menuOpen = false; task { save(listOf(materialize(file) to file.mimeType)) } })
                                            if (!selecting) DropdownMenuItem(text = { Text("进入多选") }, onClick = { menuOpen = false; selecting = true; selected = selected + file.key })
                                        }
                                    }
                                }
                                repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                            }
                        }
                    }
                }

                if (!selecting && files.isNotEmpty()) {
                    item(key = "promote-case") {
                        Surface(
                            onClick = onPromoteToScenario,
                            shape = RoundedCornerShape(14.dp),
                            color = palette.surface,
                            border = BorderStroke(0.5.dp, palette.border),
                            modifier = Modifier.padding(top = 6.dp),
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 12.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(30.dp)
                                        .clip(RoundedCornerShape(9.dp))
                                        .background(palette.accentGradient),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Icon(Icons.Default.AutoAwesome, null, tint = Color.White, modifier = Modifier.size(16.dp))
                                }
                                Text("将本案查证方法存为场景", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = palette.ink, modifier = Modifier.weight(1f))
                                Icon(Icons.Default.ChevronRight, null, tint = palette.accent, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                }
            }
        }

        // Bottom Symmetric MyDots Thumb Dock
        HorizontalDivider(thickness = 0.5.dp, color = palette.border)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(palette.background)
                .padding(horizontal = 14.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (selecting) {
                CompactSheetButton("存文件", Icons.Default.ArrowDownward, enabled = !busy && selected.isNotEmpty()) {
                    task { save(chosen()) }
                }
                val allImages = if (zip != null) {
                    zip.second.members.filter { it.name in selected }.all { mimeFor(it.name).startsWith("image/") }
                } else {
                    files.filter { it.key in selected }.all { it.isImage }
                }
                val label = when {
                    selected.isEmpty() -> "选择后转发"
                    selected.size == 1 -> "转发已选 (1)"
                    allImages -> "转发图片 (${selected.size})"
                    else -> "打包转发 (${selected.size})"
                }
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(44.dp)
                        .clip(CircleShape)
                        .background(if (!busy && selected.isNotEmpty()) palette.accentGradient else Brush.horizontalGradient(listOf(palette.surfaceMuted, palette.surfaceMuted)))
                        .clickable(enabled = !busy && selected.isNotEmpty()) { task { share(chosen()) } },
                    contentAlignment = Alignment.Center,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Default.Share, null, tint = if (selected.isNotEmpty()) Color.White else palette.inkMuted, modifier = Modifier.size(16.dp))
                        Text(label, fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold, color = if (selected.isNotEmpty()) Color.White else palette.inkMuted, maxLines = 1)
                    }
                }
            } else if (zip != null) {
                Surface(
                    onClick = { task { share(listOf(materialize(zip.first) to "application/zip")) } },
                    enabled = !busy,
                    shape = CircleShape,
                    color = palette.ink,
                    modifier = Modifier.weight(1f).height(44.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
                        Icon(Icons.Default.Share, null, tint = palette.inkOnSolid, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("整包转发 ZIP", fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold, color = palette.inkOnSolid)
                    }
                }
                CompactSheetButton("存文件", Icons.Default.ArrowDownward, enabled = !busy) {
                    task { save(listOf(materialize(zip.first) to "application/zip")) }
                }
            } else {
                val primaryTarget = mainReport ?: files.firstOrNull { it.isZip } ?: files.firstOrNull()
                val primaryText = when {
                    mainReport != null -> "转发主报告"
                    files.any { it.isZip } -> "整包转发 ZIP"
                    primaryTarget != null -> "转发资料"
                    else -> "暂无可转发资料"
                }
                Surface(
                    onClick = { primaryTarget?.let { target -> task { share(listOf(materialize(target) to target.mimeType)) } } },
                    enabled = !busy && primaryTarget != null,
                    shape = CircleShape,
                    color = if (primaryTarget != null) palette.ink else palette.surfaceMuted,
                    modifier = Modifier.weight(1f).height(44.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
                        Icon(Icons.Default.Share, null, tint = if (primaryTarget != null) palette.inkOnSolid else palette.inkMuted, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(primaryText, fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold, color = if (primaryTarget != null) palette.inkOnSolid else palette.inkMuted)
                    }
                }
                Surface(
                    onClick = onAddFiles,
                    shape = CircleShape,
                    color = palette.surface,
                    border = BorderStroke(0.6.dp, palette.border),
                    shadowElevation = 2.dp,
                    modifier = Modifier.size(44.dp),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(Icons.Default.Add, contentDescription = "补传资料到本案", tint = palette.ink, modifier = Modifier.size(20.dp))
                    }
                }
            }
        }
    }

    gallery?.let { g ->
        FullscreenCaseGalleryDialog(
            state = g,
            onDismiss = { gallery = null },
            onShare = { item -> task { share(listOf(item.file to item.mime)) } },
            onSave = { item -> task { save(listOf(item.file to item.mime)) } },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FullscreenCaseGalleryDialog(
    state: GalleryState,
    onDismiss: () -> Unit,
    onShare: (GalleryImageItem) -> Unit,
    onSave: (GalleryImageItem) -> Unit,
) {
    val palette = assistantPalette()
    val pagerState = rememberPagerState(initialPage = state.startIndex.coerceIn(0, (state.items.size - 1).coerceAtLeast(0))) { state.items.size }
    val current = state.items.getOrNull(pagerState.currentPage) ?: return

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black)
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
            HorizontalPager(state = pagerState, modifier = Modifier.fillMaxSize()) { page ->
                val item = state.items[page]
                var scale by remember(item.id) { mutableFloatStateOf(1f) }
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .pointerInput(item.id) {
                            detectTransformGestures { _, _, zoom, _ -> scale = (scale * zoom).coerceIn(1f, 4f) }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    AsyncImage(
                        model = item.file,
                        contentDescription = item.title,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .fillMaxSize()
                            .graphicsLayer(scaleX = scale, scaleY = scale),
                    )
                }
            }

            // Top bar
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .align(Alignment.TopCenter)
                    .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.72f), Color.Transparent)))
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Surface(
                    onClick = onDismiss,
                    shape = CircleShape,
                    color = Color.White.copy(alpha = 0.14f),
                    modifier = Modifier.size(36.dp),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(Icons.Default.Close, "关闭", tint = Color.White, modifier = Modifier.size(18.dp))
                    }
                }
                Column(
                    modifier = Modifier.weight(1f).padding(horizontal = 12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(current.title, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${pagerState.currentPage + 1} / ${state.items.size} · ${current.subtitle}", color = Color.White.copy(alpha = 0.65f), fontSize = 11.sp)
                }
                Spacer(Modifier.size(36.dp))
            }

            // Bottom bar
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .align(Alignment.BottomCenter)
                    .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.78f))))
                    .padding(horizontal = 20.dp, vertical = 18.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Surface(
                    onClick = { onSave(current) },
                    shape = CircleShape,
                    color = Color.White.copy(alpha = 0.14f),
                    modifier = Modifier.weight(1f).height(44.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
                        Icon(Icons.Default.ArrowDownward, null, tint = Color.White, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("保存图片", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
                Box(
                    modifier = Modifier
                        .weight(1.2f)
                        .height(44.dp)
                        .clip(CircleShape)
                        .background(palette.accentGradient)
                        .clickable { onShare(current) },
                    contentAlignment = Alignment.Center,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
                        Icon(Icons.Default.Share, null, tint = Color.White, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("转发此图", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CaseImageTileBox(
    file: File?,
    caption: String?,
    selecting: Boolean,
    checked: Boolean,
    modifier: Modifier = Modifier,
    onTap: () -> Unit,
    onToggle: () -> Unit,
    onLongPress: () -> Unit,
) {
    val palette = assistantPalette()
    Surface(
        shape = RoundedCornerShape(11.dp),
        color = palette.surfaceMuted,
        border = BorderStroke(
            width = if (selecting && checked) 1.8.dp else 0.5.dp,
            color = if (selecting && checked) palette.accent else palette.border,
        ),
        modifier = modifier.aspectRatio(1.05f),
    ) {
        Box {
            AsyncImage(
                model = file,
                contentDescription = caption ?: "图片",
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxSize()
                    .combinedClickable(onClick = onTap, onLongClick = onLongPress),
            )
            if (caption != null) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .align(Alignment.BottomStart)
                        .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.68f))))
                        .padding(start = 6.dp, end = 6.dp, top = 12.dp, bottom = 4.dp),
                ) {
                    Text(caption, color = Color.White, fontSize = 9.5.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            if (selecting) {
                CaseCheckBadge(
                    checked = checked,
                    onToggle = onToggle,
                    onImage = true,
                    modifier = Modifier.align(Alignment.TopEnd).padding(4.dp),
                )
            }
        }
    }
}

@Composable
private fun CaseFilterPill(label: String, count: Int, active: Boolean, onClick: () -> Unit) {
    val palette = assistantPalette()
    Surface(
        onClick = onClick,
        shape = CircleShape,
        color = if (active) palette.ink else palette.surfaceMuted,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 11.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = label,
                fontSize = 12.sp,
                fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
                color = if (active) palette.inkOnSolid else palette.inkSecondary,
            )
            if (count > 0) {
                Text(
                    text = "$count",
                    fontSize = 11.5.sp,
                    color = (if (active) palette.inkOnSolid else palette.inkSecondary).copy(alpha = if (active) 0.8f else 0.65f),
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CaseFileListRow(
    name: String,
    mime: String,
    detail: String,
    directoryTag: String? = null,
    isPrimaryReport: Boolean,
    selecting: Boolean,
    checked: Boolean,
    isContainer: Boolean,
    onToggle: () -> Unit,
    onOpen: () -> Unit,
    onLongPress: () -> Unit = {},
) {
    val palette = assistantPalette()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(if (selecting && checked) palette.accent.copy(alpha = 0.06f) else Color.Transparent)
            .combinedClickable(onClick = onOpen, onLongClick = onLongPress)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        if (selecting) {
            CaseCheckBadge(checked = checked, onToggle = onToggle, onImage = false)
        }
        FormatBadge(name, mime, highlighted = isPrimaryReport)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = name,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = palette.ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                if (isPrimaryReport) {
                    Text(
                        text = "主报告",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = palette.accent,
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(palette.accentSoft)
                            .padding(horizontal = 5.5.dp, vertical = 1.dp),
                    )
                }
                if (directoryTag != null) {
                    Text(
                        text = directoryTag,
                        fontSize = 10.sp,
                        color = palette.inkSecondary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(4.dp))
                            .background(palette.surfaceMuted)
                            .padding(horizontal = 5.dp, vertical = 1.dp),
                    )
                }
                Text(detail, fontSize = 11.sp, color = palette.inkMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (isContainer && !selecting) {
            Icon(Icons.Default.ChevronRight, null, tint = palette.inkMuted, modifier = Modifier.size(16.dp))
        }
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
            .size(28.dp)
            .clickable(onClick = onToggle),
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            shape = CircleShape,
            color = when {
                checked -> palette.accent
                onImage -> Color.Black.copy(alpha = 0.28f)
                else -> Color.Transparent
            },
            border = BorderStroke(
                width = 1.5.dp,
                color = when {
                    checked -> if (onImage) Color.White else palette.accent
                    onImage -> Color.White.copy(alpha = 0.9f)
                    else -> palette.inkMuted.copy(alpha = 0.45f)
                },
            ),
            modifier = Modifier.size(20.dp),
        ) {
            if (checked) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Default.Check, null, tint = Color.White, modifier = Modifier.size(13.dp))
                }
            }
        }
    }
}

@Composable
private fun CompactSheetButton(
    label: String,
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
        border = BorderStroke(0.6.dp, palette.border),
        modifier = Modifier.height(44.dp),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Icon(icon, null, tint = if (enabled) palette.ink else palette.inkMuted, modifier = Modifier.size(16.dp))
            Text(label, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = if (enabled) palette.ink else palette.inkMuted, maxLines = 1)
        }
    }
}

@Composable
internal fun FormatBadge(name: String, mime: String, compact: Boolean = false, highlighted: Boolean = false) {
    val palette = assistantPalette()
    val ext = name.substringAfterLast('.', "").lowercase()
    val icon = when {
        ext in setOf("zip", "rar", "7z", "tar", "gz") -> Icons.Default.FolderZip
        ext in setOf("xls", "xlsx", "csv") -> Icons.Default.TableChart
        mime.startsWith("image/") -> Icons.Default.Image
        ext == "pdf" -> Icons.Default.PictureAsPdf
        else -> Icons.Default.Description
    }
    val tint = when {
        highlighted -> palette.accent
        ext in setOf("zip", "rar", "7z") -> palette.risk
        ext == "pdf" -> palette.report
        ext in setOf("xls", "xlsx", "csv") -> palette.accent
        else -> palette.inkSecondary
    }
    val bg = when {
        highlighted -> palette.accentSoft
        ext in setOf("zip", "rar", "7z") -> palette.risk.copy(alpha = 0.13f)
        ext == "pdf" -> palette.report.copy(alpha = 0.11f)
        ext in setOf("xls", "xlsx", "csv") -> palette.accentSoft
        else -> palette.surfaceMuted
    }
    Box(
        modifier = Modifier
            .size(if (compact) 30.dp else 34.dp)
            .clip(RoundedCornerShape(if (compact) 8.dp else 9.dp))
            .background(bg),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(if (compact) 16.dp else 18.dp))
    }
}
