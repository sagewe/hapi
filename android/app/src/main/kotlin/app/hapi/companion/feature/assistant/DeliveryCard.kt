package app.hapi.companion.feature.assistant
import android.content.Intent
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import app.hapi.companion.feature.chat.LocalChatMedia
import app.hapi.protocol.chat.GeneratedImageBlock
import kotlinx.coroutines.launch
import java.io.File

@Composable fun DeliveryCard(block: GeneratedImageBlock, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val media = LocalChatMedia.current
    val scope = rememberCoroutineScope()
    var file by remember(block.imageId) { mutableStateOf<File?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val pdf = block.fileName.endsWith(".pdf", true)
    val mime = if(pdf) "application/pdf" else "application/zip"
    val tint = if(pdf) Color(0xFFBB4C68) else Color(0xFFB78027)
    fun open(share: Boolean) {
        if(busy) return
        busy = true; error = null
        scope.launch {
            try {
                val cached = file ?: requireNotNull(media.fetchGeneratedMedia)(requireNotNull(media.generatedImageUrl(block.imageId)), block.imageId, block.fileName).also { file = it }
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.attachments", cached)
                val intent = Intent(if(share) Intent.ACTION_SEND else Intent.ACTION_VIEW).apply {
                    if(share) { type = mime; putExtra(Intent.EXTRA_STREAM, uri); clipData = android.content.ClipData.newRawUri("报告", uri) }
                    else setDataAndType(uri, mime)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                val chooser = Intent.createChooser(intent, if(share) "转发报告" else "预览报告")
                if(!share) chooser.putExtra(Intent.EXTRA_EXCLUDE_COMPONENTS, arrayOf(android.content.ComponentName(context, app.hapi.companion.MainActivity::class.java)))
                context.startActivity(chooser)
            } catch (_: Exception) { error = "无法打开报告，请重试或安装 PDF 阅读器" }
            finally { busy = false }
        }
    }
    Surface(modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), border = BorderStroke(.5.dp, MaterialTheme.colorScheme.outlineVariant)) {
        Column(Modifier.padding(14.dp)) {
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Surface(color = tint.copy(alpha = .12f), shape = RoundedCornerShape(8.dp)) { Text(if(pdf) "PDF" else "ZIP", color = tint, modifier = Modifier.padding(8.dp)) }
                Spacer(Modifier.width(12.dp))
                Text(block.fileName, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            }
            Row { TextButton({ open(false) }, enabled = !busy) { Text("预览") }; TextButton({ open(true) }, enabled = !busy) { Text("转发") }; if(busy) CircularProgressIndicator(Modifier.padding(10.dp).size(20.dp)) }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }
}
