package app.hapi.companion.feature.assistant

import android.content.ClipData
import android.content.ContentValues
import android.content.Intent
import android.os.Build
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import app.hapi.data.api.HapiApi
import app.hapi.data.casefiles.*
import app.hapi.protocol.wire.CaseFile
import coil.compose.AsyncImage
import kotlinx.coroutines.*
import java.io.File
import java.util.UUID

internal data class CaseFilesAccess(val files: List<CaseFile>, val open: () -> Unit)
internal val LocalCaseFiles = staticCompositionLocalOf { CaseFilesAccess(emptyList(), {}) }

@Composable internal fun CaseFilesCapsule(files: List<CaseFile>, open: () -> Unit, modifier: Modifier = Modifier) {
    Surface(onClick=open,modifier=modifier.pointerInput(open) {
        var drag=0f
        detectVerticalDragGestures(onDragStart={drag=0f},onVerticalDrag={change,dy->change.consume();drag+=dy},onDragEnd={if(drag < -24.dp.toPx()) open()})
    },shape=RoundedCornerShape(50),color=MaterialTheme.colorScheme.surfaceContainerLow,border=BorderStroke(1.dp,MaterialTheme.colorScheme.primary.copy(alpha=.5f)),shadowElevation=2.dp) {
        Text("本案资料 · ${files.size}" + (if(files.any { !it.isUpload && it.isPdf }) " 含报告" else "") + " ▴",Modifier.padding(horizontal=18.dp,vertical=10.dp),style=MaterialTheme.typography.labelLarge,color=MaterialTheme.colorScheme.primary)
    }
}
internal fun primaryReport(files: List<CaseFile>) = files.filter { !it.isUpload && it.isPdf }.sortedBy { if(it.fileName.contains("报告") || it.fileName.contains("尽调")) 0 else 1 }.firstOrNull()
private fun mimeFor(name: String) = MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.').lowercase()) ?: "application/octet-stream"

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun CaseFilesPanel(api: HapiApi, sessionId: String, title: String, files: List<CaseFile>, dismiss: () -> Unit) {
    val context=LocalContext.current
    val scope=rememberCoroutineScope()
    val root=remember(sessionId) { File(context.cacheDir,"case-files/${UUID.randomUUID()}").apply { mkdirs() } }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var filter by remember { mutableIntStateOf(0) }
    var archive by remember { mutableStateOf<Pair<CaseFile,SafeCaseZip>?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var image by remember { mutableStateOf<File?>(null) }
    val cache=remember { mutableMapOf<String,File>() }
    // Material 1.3.2 hides before invoking onDismissRequest for system back.
    // Veto that hide while browsing ZIP so the callback can pop the inner page.
    val zipOpen=rememberUpdatedState(archive != null)
    val sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true,confirmValueChange={ value -> value != SheetValue.Hidden || !zipOpen.value })
    suspend fun materialize(file: CaseFile): File = cache[file.key] ?: withContext(Dispatchers.IO) {
        val dir=File(root,UUID.randomUUID().toString()).apply { mkdirs() }
        File(dir,safeCaseName(file.fileName)).apply { writeBytes(api.getCaseFile(sessionId,file).bytes) }.also { cache[file.key]=it }
    }
    fun task(action: suspend () -> Unit) { if(busy) return; busy=true;error=null;scope.launch { try { action() } catch(e: Exception) { if(e is CancellationException) throw e;error=e.message ?: "操作未完成，请重试" } finally { busy=false } } }
    fun preview(file: File, mime: String) {
        if(mime.startsWith("image/")) { image=file;return }
        val uri=FileProvider.getUriForFile(context,"${context.packageName}.attachments",file,file.name)
        val view=Intent(Intent.ACTION_VIEW).setDataAndType(uri,mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val chooser=Intent.createChooser(view,"预览资料").putExtra(Intent.EXTRA_EXCLUDE_COMPONENTS,arrayOf(android.content.ComponentName(context,app.hapi.companion.MainActivity::class.java)))
        context.startActivity(chooser)
    }
    suspend fun share(items: List<Pair<File,String>>) {
        if(items.isEmpty()) error("请先选择资料")
        val output=withContext(Dispatchers.IO) { if(needsSelectionZip(items.map { it.second })) listOf(packageSelection(items.map { it.first },File(File(root,UUID.randomUUID().toString()).apply { mkdirs() },selectionZipName(title,items.size))) to "application/zip") else items }
        val uris=ArrayList(output.map { FileProvider.getUriForFile(context,"${context.packageName}.attachments",it.first,it.first.name) })
        val intent=Intent(if(output.size > 1) Intent.ACTION_SEND_MULTIPLE else Intent.ACTION_SEND).apply {
            type=if(output.all { it.second.startsWith("image/") }) "image/*" else output.first().second
            if(output.size > 1) putParcelableArrayListExtra(Intent.EXTRA_STREAM,uris) else putExtra(Intent.EXTRA_STREAM,uris.first())
            clipData=ClipData.newRawUri("本案资料",uris.first()).also { clip -> uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) } }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent,"转发本案资料"))
    }
    suspend fun chosen(): List<Pair<File,String>> {
        val zip=archive
        return if(zip!=null) withContext(Dispatchers.IO) { zip.second.members.filter { it.name in selected }.map { member -> zip.second.extract(member,File(root,UUID.randomUUID().toString())) to mimeFor(member.name) } }
        else files.filter { it.key in selected }.map { materialize(it) to it.mimeType }
    }
    suspend fun save(items: List<Pair<File,String>>) {
        require(items.isNotEmpty()) { "没有可保存的资料" }
        if(Build.VERSION.SDK_INT < 29) error("此系统请使用转发后选择文件应用保存")
        withContext(Dispatchers.IO) {
            items.forEach { (file,mime) ->
                val values=ContentValues().apply { put(MediaStore.Downloads.DISPLAY_NAME,safeCaseName(file.name));put(MediaStore.Downloads.MIME_TYPE,mime);put(MediaStore.Downloads.RELATIVE_PATH,"Download/琪琪工作/");put(MediaStore.Downloads.IS_PENDING,1) }
                val uri=requireNotNull(context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,values))
                try { requireNotNull(context.contentResolver.openOutputStream(uri)).use { out -> file.inputStream().use { it.copyTo(out) } };context.contentResolver.update(uri,ContentValues().apply { put(MediaStore.Downloads.IS_PENDING,0) },null,null) }
                catch(e: Exception) { context.contentResolver.delete(uri,null,null);throw e }
            }
        }
        Toast.makeText(context,"已保存 ${items.size} 份至 Download/琪琪工作/",Toast.LENGTH_LONG).show()
    }
    fun back() { archive=null;selected=emptySet();error=null }
    ModalBottomSheet(onDismissRequest={if(archive!=null) { back();scope.launch { sheetState.show() } } else dismiss()},sheetState=sheetState,containerColor=assistantPaper(),contentColor=MaterialTheme.colorScheme.onSurface) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(.9f).navigationBarsPadding()) {
            Column(Modifier.padding(horizontal=20.dp)) {
                Row(verticalAlignment=Alignment.CenterVertically) { Text(archive?.first?.fileName ?: "本案资料（${files.size}）",Modifier.weight(1f),style=MaterialTheme.typography.titleLarge,maxLines=2);if(archive==null) Text("持久留存",color=Color(0xFF238B80),style=MaterialTheme.typography.labelSmall) }
                if(archive==null) Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) { listOf("全部","报告与证据","送审原件").forEachIndexed { i,label -> FilterChip(filter==i,{filter=i},{Text(label)},shape=RoundedCornerShape(50)) } }
                else Text("${archive!!.second.members.size} 份文件 · 免解压直接查看",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant,modifier=Modifier.padding(vertical=12.dp))
            }
            if(busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            error?.let { Text(it,color=MaterialTheme.colorScheme.error,modifier=Modifier.padding(horizontal=20.dp,vertical=6.dp)) }
            LazyColumn(Modifier.weight(1f),contentPadding=PaddingValues(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)) {
                val zip=archive
                if(zip!=null) items(zip.second.members,key={it.name}) { member ->
                    FileRow(member.name,mimeFor(member.name),member.size,member.name in selected,{selected=if(member.name in selected) selected-member.name else selected+member.name},{task { val extracted=withContext(Dispatchers.IO) { zip.second.extract(member,File(root,UUID.randomUUID().toString())) };preview(extracted,mimeFor(member.name)) }},"预览")
                } else {
                    val visible=files.filter { filter==0 || if(filter==2) it.isUpload else !it.isUpload }
                    items(visible.filter { !it.isImage },key={it.key}) { file ->
                        FileRow(file.fileName,file.mimeType,file.size,file.key in selected,{selected=if(file.key in selected) selected-file.key else selected+file.key},{task { val local=materialize(file);if(file.isZip) { val parsed=withContext(Dispatchers.IO) { SafeCaseZip(local) };archive=file to parsed;selected=emptySet() } else preview(local,file.mimeType) }},if(file.isZip) "展开 ›" else "预览")
                    }
                    items(visible.filter { it.isImage }.chunked(3)) { row ->
                        Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                            row.forEach { file ->
                                var thumb by remember(file.key) { mutableStateOf<File?>(null) }
                                LaunchedEffect(file.key) { runCatching { materialize(file) }.onSuccess { thumb=it } }
                                Surface(Modifier.weight(1f),shape=RoundedCornerShape(12.dp),border=BorderStroke(1.dp,if(file.key in selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant)) {
                                    Column { Box { AsyncImage(thumb,"预览 ${file.fileName}",Modifier.fillMaxWidth().height(90.dp).clickable { task { image=materialize(file) } },contentScale=androidx.compose.ui.layout.ContentScale.Crop);CaseCheck(file.key in selected,{selected=if(file.key in selected) selected-file.key else selected+file.key},Modifier.align(Alignment.TopEnd)) };Text(file.fileName,Modifier.padding(6.dp),maxLines=2,style=MaterialTheme.typography.labelSmall) }
                                }
                            }
                            repeat(3-row.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
            }
            HorizontalDivider()
            Row(Modifier.fillMaxWidth().padding(horizontal=12.dp,vertical=10.dp),horizontalArrangement=Arrangement.spacedBy(6.dp),verticalAlignment=Alignment.CenterVertically) {
                if(archive!=null) OutlinedButton({back()},enabled=!busy,contentPadding=PaddingValues(horizontal=10.dp)) { Text("← 返回资料",maxLines=1) }
                OutlinedButton({task { save(if(selected.isNotEmpty()) chosen() else if(archive!=null) listOf(materialize(archive!!.first) to "application/zip") else files.map { materialize(it) to it.mimeType }) }},enabled=!busy && files.isNotEmpty(),contentPadding=PaddingValues(horizontal=10.dp)) { Text(if(archive!=null) "↓ 存" else "↓ 存手机",maxLines=1) }
                if(selected.isEmpty() && archive==null) files.firstOrNull { it.isZip }?.let { zip -> OutlinedButton({task { share(listOf(materialize(zip) to "application/zip")) }},enabled=!busy,contentPadding=PaddingValues(horizontal=8.dp)) { Text("整包 ZIP",maxLines=1) } }
                Button({task { share(if(selected.isNotEmpty()) chosen() else if(archive!=null) listOf(materialize(archive!!.first) to "application/zip") else listOfNotNull(primaryReport(files)).map { materialize(it) to it.mimeType }) }},enabled=!busy && (selected.isNotEmpty() || archive!=null || primaryReport(files)!=null),modifier=Modifier.weight(1f),contentPadding=PaddingValues(horizontal=8.dp)) { Text(if(selected.isNotEmpty()) "转发已选 (${selected.size})" else if(archive!=null) "整包转发" else "转发尽调报告",maxLines=1,style=MaterialTheme.typography.labelMedium) }
            }
        }
    }
    image?.let { file ->
        Dialog({image=null},properties=DialogProperties(usePlatformDefaultWidth=false)) {
            var scale by remember { mutableFloatStateOf(1f) };var x by remember { mutableFloatStateOf(0f) };var y by remember { mutableFloatStateOf(0f) }
            Box(Modifier.fillMaxSize().background(Color.Black)) {
                AsyncImage(file,"双指缩放图片",Modifier.fillMaxSize().pointerInput(file) { detectTransformGestures { _,pan,zoom,_->scale=(scale*zoom).coerceIn(1f,8f);x+=pan.x;y+=pan.y } }.graphicsLayer(scaleX=scale,scaleY=scale,translationX=x,translationY=y))
                TextButton({image=null},Modifier.align(Alignment.BottomCenter).navigationBarsPadding()) { Text("关闭图片",color=Color.White) }
            }
        }
    }
}
@Composable private fun FileRow(name: String,mime: String,size: Long,checked: Boolean,toggle: () -> Unit,open: () -> Unit,action: String) {
    Surface(onClick=open,shape=RoundedCornerShape(14.dp),border=BorderStroke(.5.dp,if(checked) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant),color=MaterialTheme.colorScheme.surfaceContainerLow) {
        Row(Modifier.padding(end=12.dp,top=8.dp,bottom=8.dp),verticalAlignment=Alignment.CenterVertically) {
            CaseCheck(checked,{toggle()})
            FormatBadge(name,mime)
            Column(Modifier.weight(1f).padding(horizontal=10.dp)) { Text(name,style=MaterialTheme.typography.bodyMedium,maxLines=2);Text("${(size/1024).coerceAtLeast(1)} KB",style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant) }
            Text(action,style=MaterialTheme.typography.labelMedium,color=MaterialTheme.colorScheme.primary)
        }
    }
}
@Composable internal fun FormatBadge(name: String,mime: String) {
    val ext=name.substringAfterLast('.').uppercase()
    val color=when { ext=="PDF" -> Color(0xFFBB4C68);ext=="ZIP" -> Color(0xFFB78027);ext in listOf("XLS","XLSX","CSV") -> Color(0xFF238B65);else -> Color(0xFF3478BD) }
    Surface(shape=RoundedCornerShape(8.dp),color=color.copy(alpha=.12f)) { Text(ext.take(4).ifBlank { if(mime.startsWith("image/")) "图" else "文" },Modifier.padding(8.dp),color=color,style=MaterialTheme.typography.labelSmall) }
}

@Composable private fun CaseCheck(checked: Boolean,onChange: (Boolean) -> Unit,modifier: Modifier=Modifier) {
    Box(modifier.size(48.dp).clickable(role=androidx.compose.ui.semantics.Role.Checkbox,onClick={onChange(!checked)}),contentAlignment=Alignment.Center) {
        Surface(shape=androidx.compose.foundation.shape.CircleShape,color=if(checked) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surface,border=BorderStroke(1.5.dp,if(checked) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant),modifier=Modifier.size(22.dp)) {
            Box(contentAlignment=Alignment.Center) { if(checked) Text("✓",color=MaterialTheme.colorScheme.onPrimary,style=MaterialTheme.typography.labelSmall) }
        }
    }
}
