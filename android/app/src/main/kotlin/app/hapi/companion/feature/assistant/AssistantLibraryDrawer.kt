package app.hapi.companion.feature.assistant

import android.content.ClipData
import android.content.ComponentName
import android.content.Intent
import android.graphics.Bitmap
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Share
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
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import app.hapi.companion.MainActivity
import app.hapi.companion.di.HubGraph
import app.hapi.companion.feature.chat.attachments.AttachmentPreparer
import app.hapi.companion.feature.chat.attachments.PrepareResult
import app.hapi.data.casefiles.safeCaseName
import app.hapi.protocol.wire.RecentDeliverable
import app.hapi.protocol.wire.ReferenceDoc
import app.hapi.protocol.wire.UpdateReferenceDocRequest
import app.hapi.protocol.wire.UploadReferenceDocRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Base64
import java.util.Calendar

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun AssistantLibraryDrawer(
    hub: HubGraph,
    scenarios: List<AssistantSceneSpec>,
    onOpenSession: (String) -> Unit,
    onUseReferenceInStudio: (ReferenceDoc) -> Unit,
) {
    val palette = assistantPalette()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val preparer = remember { AttachmentPreparer(context) }

    var tab by remember { mutableIntStateOf(0) } // 0 = 最近交付, 1 = 参考底稿
    var delivFilter by remember { mutableIntStateOf(0) } // 0 = 报告, 1 = 证据包, 2 = 全部
    var searching by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    var deliverables by remember { mutableStateOf<List<RecentDeliverable>>(emptyList()) }
    var refs by remember { mutableStateOf<List<ReferenceDoc>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun refresh() {
        runCatching {
            val d = hub.session.api.getRecentDeliverables(50).files
            val r = hub.session.api.getReferenceDocs().files
            deliverables = d
            refs = r
            error = null
        }.onFailure {
            error = "资料库暂时无法读取，请重试"
        }
    }

    LaunchedEffect(hub.hubUrl) { refresh() }

    suspend fun materializeDeliverable(item: RecentDeliverable): File {
        val cached = caseDiskCacheFile(context, item.sessionId, item.id, item.fileName)
        if (cached.isFile && cached.length() > 0) return cached
        return withContext(Dispatchers.IO) {
            val bytes = hub.session.api.getDeliverableBytes(item.sessionId, item.id).bytes
            cached.parentFile?.mkdirs()
            cached.writeBytes(bytes)
            cached
        }
    }

    suspend fun materializeReference(doc: ReferenceDoc): File {
        val cached = caseDiskCacheFile(context, "_reference_docs", doc.id, doc.fileName)
        if (cached.isFile && cached.length() > 0) return cached
        return withContext(Dispatchers.IO) {
            val bytes = hub.session.api.getReferenceDocBytes(doc.id).bytes
            cached.parentFile?.mkdirs()
            cached.writeBytes(bytes)
            cached
        }
    }

    fun openFile(file: File, mime: String) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.attachments", file, file.name)
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val chooser = Intent.createChooser(view, "预览资料")
            .putExtra(Intent.EXTRA_EXCLUDE_COMPONENTS, arrayOf(ComponentName(context, MainActivity::class.java)))
        context.startActivity(chooser)
    }

    fun shareFile(file: File, mime: String) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.attachments", file, file.name)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri(file.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, "转发资料"))
    }

    fun runTask(block: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = null
        scope.launch {
            try {
                block()
            } catch (e: Exception) {
                error = e.message ?: "操作失败，请重试"
            } finally {
                busy = false
            }
        }
    }

    val uploadLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        runTask {
            uris.forEach { uri ->
                when (val prepared = preparer.prepare(uri)) {
                    is PrepareResult.Ready -> {
                        val att = prepared.attachment
                        val encoded = withContext(Dispatchers.IO) { Base64.getEncoder().encodeToString(att.bytes) }
                        val res = hub.session.api.uploadReferenceDoc(
                            UploadReferenceDocRequest(
                                filename = safeCaseName(att.filename),
                                content = encoded,
                                mimeType = att.mimeType,
                                scope = "library",
                            ),
                        )
                        refs = listOf(res.file) + refs
                    }
                    else -> Toast.makeText(context, "无法读取部分文件或超过 50 MB", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }

    val filteredDelivs = remember(deliverables, delivFilter, query) {
        val q = query.trim()
        deliverables.filter { item ->
            val okTab = when (delivFilter) {
                0 -> item.isPdf
                1 -> item.isZip
                else -> true
            }
            okTab && (q.isEmpty() || item.fileName.contains(q, true) || item.sessionTitle.contains(q, true))
        }
    }

    val groupedDelivs = remember(filteredDelivs) {
        filteredDelivs.groupBy { dayBucket(it.createdAt) }.entries.sortedBy { it.key }
    }

    val filteredRefs = remember(refs, query) {
        val q = query.trim()
        if (q.isEmpty()) refs else refs.filter { it.fileName.contains(q, true) }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(palette.background)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "我的资料库",
                fontSize = 21.sp,
                fontWeight = FontWeight.Bold,
                color = palette.ink,
            )
            Spacer(Modifier.weight(1f))
            Surface(
                onClick = {
                    searching = !searching
                    if (!searching) query = ""
                },
                shape = CircleShape,
                color = palette.surface,
                border = BorderStroke(0.5.dp, palette.border),
                modifier = Modifier.size(36.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = if (searching) Icons.Default.Close else Icons.Default.Search,
                        contentDescription = "搜索资料库",
                        tint = palette.ink,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
        }

        if (searching) {
            Surface(
                shape = RoundedCornerShape(11.dp),
                color = palette.surfaceMuted,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 14.dp)
                    .padding(bottom = 10.dp)
                    .height(36.dp),
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(Icons.Default.Search, null, tint = palette.inkMuted, modifier = Modifier.size(15.dp))
                    BasicTextField(
                        value = query,
                        onValueChange = { query = it },
                        singleLine = true,
                        textStyle = TextStyle(color = palette.ink, fontSize = 14.sp),
                        cursorBrush = SolidColor(palette.accent),
                        modifier = Modifier.weight(1f),
                        decorationBox = { inner ->
                            if (query.isEmpty()) Text("搜索报告、案件或底稿", fontSize = 14.sp, color = palette.inkMuted)
                            inner()
                        },
                    )
                }
            }
        }

        // Segmented bar: 最近交付 | 参考底稿
        Surface(
            shape = RoundedCornerShape(12.dp),
            color = palette.surfaceMuted,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp)
                .padding(bottom = 10.dp),
        ) {
            Row(modifier = Modifier.padding(3.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                listOf("最近交付" to 0, "参考底稿" to 1).forEach { (label, idx) ->
                    val active = tab == idx
                    Surface(
                        onClick = { tab = idx },
                        shape = RoundedCornerShape(9.5.dp),
                        color = if (active) palette.surface else androidx.compose.ui.graphics.Color.Transparent,
                        shadowElevation = if (active) 1.dp else 0.dp,
                        modifier = Modifier.weight(1f).height(32.dp),
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Text(
                                text = label,
                                fontSize = 13.sp,
                                fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
                                color = if (active) palette.ink else palette.inkSecondary,
                            )
                        }
                    }
                }
            }
        }

        if (tab == 0) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 14.dp)
                    .padding(bottom = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                listOf("报告" to 0, "证据包" to 1, "全部" to 2).forEach { (label, tag) ->
                    val active = delivFilter == tag
                    Surface(
                        onClick = { delivFilter = tag },
                        shape = CircleShape,
                        color = if (active) palette.ink else palette.surfaceMuted,
                    ) {
                        Text(
                            text = label,
                            fontSize = 12.sp,
                            fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
                            color = if (active) palette.inkOnSolid else palette.inkSecondary,
                            modifier = Modifier.padding(horizontal = 11.dp, vertical = 5.5.dp),
                        )
                    }
                }
            }
        }

        HorizontalDivider(modifier = Modifier.padding(horizontal = 14.dp), thickness = 0.5.dp, color = palette.border)

        if (busy) {
            LinearProgressIndicator(color = palette.accent, trackColor = palette.surfaceMuted, modifier = Modifier.fillMaxWidth())
        }
        error?.let {
            Text(it, color = palette.report, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp))
        }

        LazyColumn(
            modifier = Modifier.weight(1f),
            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            if (tab == 0) {
                if (groupedDelivs.isEmpty()) {
                    item {
                        Text(
                            text = "各案件生成的尽调报告和证据包会汇集在这里",
                            fontSize = 13.sp,
                            color = palette.inkMuted,
                            modifier = Modifier.padding(top = 32.dp, start = 6.dp, end = 6.dp),
                        )
                    }
                }
                groupedDelivs.forEach { (bucket, itemsInBucket) ->
                    item(key = "day-$bucket") {
                        Text(
                            text = dayBucketTitle(bucket),
                            fontSize = 11.5.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = palette.inkMuted,
                            modifier = Modifier.padding(start = 4.dp, top = 2.dp),
                        )
                    }
                    items(itemsInBucket, key = { it.uniqueKey }) { item ->
                        var menuOpen by remember { mutableStateOf(false) }
                        var pdfThumb by remember(item.uniqueKey) { mutableStateOf<Bitmap?>(null) }
                        LaunchedEffect(item.uniqueKey) {
                            if (item.isPdf) {
                                runCatching {
                                    val local = materializeDeliverable(item)
                                    renderPdfCoverBitmap(local, 96, 128)
                                }.onSuccess { pdfThumb = it }
                            }
                        }
                        Box {
                            Surface(
                                shape = RoundedCornerShape(15.dp),
                                color = palette.surface,
                                border = BorderStroke(0.5.dp, palette.border),
                            ) {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .combinedClickable(
                                            onClick = { runTask { openFile(materializeDeliverable(item), item.mimeType) } },
                                            onLongClick = { menuOpen = true },
                                        )
                                        .padding(10.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                                ) {
                                    if (item.isPdf) {
                                        Box(
                                            modifier = Modifier
                                                .size(width = 36.dp, height = 48.dp)
                                                .clip(RoundedCornerShape(6.dp))
                                                .background(palette.surfaceMuted),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            val bmp = pdfThumb
                                            if (bmp != null) {
                                                Image(bmp.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                                            } else {
                                                Icon(Icons.Default.PictureAsPdf, null, tint = palette.accent, modifier = Modifier.size(18.dp))
                                            }
                                        }
                                    } else {
                                        FormatBadge(item.fileName, item.mimeType)
                                    }
                                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                        Text(
                                            text = item.fileName,
                                            fontSize = 13.sp,
                                            fontWeight = FontWeight.SemiBold,
                                            color = palette.ink,
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                        Text(
                                            text = "${item.sessionTitle.ifBlank { "尽调案件" }} · ${formatByteSize(item.size)}",
                                            fontSize = 11.sp,
                                            color = palette.inkMuted,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                    Surface(
                                        onClick = { runTask { shareFile(materializeDeliverable(item), item.mimeType) } },
                                        shape = CircleShape,
                                        color = palette.accentSoft,
                                        modifier = Modifier.size(34.dp),
                                    ) {
                                        Box(contentAlignment = Alignment.Center) {
                                            Icon(Icons.Default.Share, "转发", tint = palette.accent, modifier = Modifier.size(15.dp))
                                        }
                                    }
                                }
                            }
                            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                                DropdownMenuItem(text = { Text("进入所属案件") }, onClick = { menuOpen = false; onOpenSession(item.sessionId) })
                                DropdownMenuItem(text = { Text("预览") }, onClick = { menuOpen = false; runTask { openFile(materializeDeliverable(item), item.mimeType) } })
                                DropdownMenuItem(text = { Text("转发") }, onClick = { menuOpen = false; runTask { shareFile(materializeDeliverable(item), item.mimeType) } })
                            }
                        }
                    }
                }
            } else {
                if (filteredRefs.isEmpty()) {
                    item {
                        Text(
                            text = "上传常用行内审单表、高风险口径或报告模板，供定制场景和日常尽调复用",
                            fontSize = 13.sp,
                            color = palette.inkMuted,
                            modifier = Modifier.padding(top = 32.dp, start = 6.dp, end = 6.dp),
                        )
                    }
                }
                items(filteredRefs, key = { it.id }) { doc ->
                    var menuOpen by remember { mutableStateOf(false) }
                    val linkedTitle = doc.scenarioIds.firstNotNullOfOrNull { sid ->
                        scenarios.firstOrNull { it.id == sid }?.title
                    }
                    Box {
                        Surface(
                            shape = RoundedCornerShape(15.dp),
                            color = palette.surface,
                            border = BorderStroke(0.5.dp, palette.border),
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .combinedClickable(
                                        onClick = { runTask { openFile(materializeReference(doc), doc.mimeType) } },
                                        onLongClick = { menuOpen = true },
                                    )
                                    .padding(11.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                FormatBadge(doc.fileName, doc.mimeType)
                                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                    Text(
                                        text = doc.fileName,
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = palette.ink,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                                        if (doc.isGlobal) {
                                            Text(
                                                text = "全局生效",
                                                fontSize = 10.sp,
                                                fontWeight = FontWeight.SemiBold,
                                                color = palette.risk,
                                                modifier = Modifier
                                                    .clip(CircleShape)
                                                    .background(palette.risk.copy(alpha = 0.14f))
                                                    .padding(horizontal = 6.dp, vertical = 1.5.dp),
                                            )
                                        } else if (linkedTitle != null) {
                                            Text(
                                                text = linkedTitle,
                                                fontSize = 10.sp,
                                                fontWeight = FontWeight.SemiBold,
                                                color = palette.accent,
                                                modifier = Modifier
                                                    .clip(CircleShape)
                                                    .background(palette.accentSoft)
                                                    .padding(horizontal = 6.dp, vertical = 1.5.dp),
                                            )
                                        }
                                        Text(formatByteSize(doc.size), fontSize = 11.sp, color = palette.inkMuted)
                                    }
                                }
                            }
                        }
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                            DropdownMenuItem(text = { Text("基于此底稿定制场景") }, onClick = { menuOpen = false; onUseReferenceInStudio(doc) })
                            DropdownMenuItem(
                                text = { Text(if (doc.isGlobal) "取消全局生效" else "设为全局生效") },
                                onClick = {
                                    menuOpen = false
                                    runTask {
                                        val updated = hub.session.api.updateReferenceDoc(
                                            doc.id,
                                            UpdateReferenceDocRequest(scope = if (doc.isGlobal) "library" else "global"),
                                        ).file
                                        refs = refs.map { if (it.id == doc.id) updated else it }
                                    }
                                },
                            )
                            DropdownMenuItem(text = { Text("转发") }, onClick = { menuOpen = false; runTask { shareFile(materializeReference(doc), doc.mimeType) } })
                            DropdownMenuItem(
                                text = { Text("删除底稿", color = palette.report) },
                                onClick = {
                                    menuOpen = false
                                    runTask {
                                        hub.session.api.deleteReferenceDoc(doc.id)
                                        refs = refs.filterNot { it.id == doc.id }
                                    }
                                },
                            )
                        }
                    }
                }
            }
        }

        if (tab == 1) {
            HorizontalDivider(thickness = 0.5.dp, color = palette.border)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            ) {
                Surface(
                    onClick = { uploadLauncher.launch(arrayOf("*/*")) },
                    enabled = !busy,
                    shape = CircleShape,
                    color = palette.ink,
                    modifier = Modifier.fillMaxWidth().height(44.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.Center,
                    ) {
                        Icon(Icons.Default.Add, null, tint = palette.inkOnSolid, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("上传参考底稿", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = palette.inkOnSolid)
                    }
                }
            }
        }
    }
}

private fun dayBucket(createdAt: Double): Int {
    val ms = if (createdAt > 10_000_000_000.0) createdAt.toLong() else (createdAt * 1000.0).toLong()
    val now = Calendar.getInstance()
    val target = Calendar.getInstance().apply { timeInMillis = ms }
    val sameYear = now.get(Calendar.YEAR) == target.get(Calendar.YEAR)
    val diffDays = now.get(Calendar.DAY_OF_YEAR) - target.get(Calendar.DAY_OF_YEAR)
    return when {
        sameYear && diffDays == 0 -> 0
        sameYear && diffDays == 1 -> 1
        System.currentTimeMillis() - ms <= 7L * 24 * 3600 * 1000 -> 2
        else -> 3
    }
}

private fun dayBucketTitle(bucket: Int): String = when (bucket) {
    0 -> "今天"
    1 -> "昨天"
    2 -> "近 7 天"
    else -> "更早"
}
