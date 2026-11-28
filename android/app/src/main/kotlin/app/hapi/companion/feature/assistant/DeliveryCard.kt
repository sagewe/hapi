package app.hapi.companion.feature.assistant

import android.content.ClipData
import android.content.ComponentName
import android.content.Intent
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.FolderZip
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import app.hapi.companion.MainActivity
import app.hapi.companion.feature.chat.LocalChatMedia
import app.hapi.protocol.chat.GeneratedImageBlock
import kotlinx.coroutines.launch
import java.io.File

@Composable
fun DeliveryCard(block: GeneratedImageBlock, modifier: Modifier = Modifier) {
    val palette = assistantPalette()
    val caseAccess = LocalCaseFiles.current
    val context = LocalContext.current
    val media = LocalChatMedia.current
    val scope = rememberCoroutineScope()
    var file by remember(block.imageId) { mutableStateOf<File?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val pdf = block.fileName.endsWith(".pdf", true)
    val zip = block.fileName.endsWith(".zip", true)
    val mime = if (pdf) "application/pdf" else if (zip) "application/zip" else "application/octet-stream"

    fun open(share: Boolean) {
        if (busy) return
        busy = true
        error = null
        scope.launch {
            try {
                val cached = file ?: requireNotNull(media.fetchGeneratedMedia)(
                    requireNotNull(media.generatedImageUrl(block.imageId)),
                    block.imageId,
                    block.fileName,
                ).also { file = it }
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.attachments", cached, block.fileName)
                val intent = Intent(if (share) Intent.ACTION_SEND else Intent.ACTION_VIEW).apply {
                    if (share) {
                        type = mime
                        putExtra(Intent.EXTRA_STREAM, uri)
                        clipData = ClipData.newRawUri("报告", uri)
                    } else {
                        setDataAndType(uri, mime)
                    }
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                val chooser = Intent.createChooser(intent, if (share) "转发报告" else "预览报告")
                if (!share) {
                    chooser.putExtra(
                        Intent.EXTRA_EXCLUDE_COMPONENTS,
                        arrayOf(ComponentName(context, MainActivity::class.java)),
                    )
                }
                context.startActivity(chooser)
            } catch (_: Exception) {
                error = "无法打开报告，请重试或安装 PDF 阅读器"
            } finally {
                busy = false
            }
        }
    }

    Surface(
        modifier = modifier.fillMaxWidth(),
        color = palette.surface,
        shape = RoundedCornerShape(18.dp),
        border = BorderStroke(0.5.dp, palette.border),
        shadowElevation = if (palette.isDark) 4.dp else 1.5.dp,
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(42.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(if (pdf) palette.accentSoft else palette.surfaceMuted),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = when {
                            pdf -> Icons.Default.PictureAsPdf
                            zip -> Icons.Default.FolderZip
                            else -> Icons.Default.Description
                        },
                        contentDescription = null,
                        tint = if (pdf) palette.accent else palette.inkSecondary,
                        modifier = Modifier.size(21.dp),
                    )
                }
                Column(
                    modifier = Modifier
                        .padding(start = 12.dp)
                        .weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        text = block.fileName,
                        fontSize = 14.5.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = palette.ink,
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            text = (if (pdf) "尽调 PDF 报告" else if (zip) "证据资料包" else "交付文件") +
                                if (busy) " · 下载中…" else if (file != null) " · 已下载" else "",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            color = palette.inkMuted,
                        )
                        if (busy) {
                            CircularProgressIndicator(
                                color = palette.accent,
                                strokeWidth = 1.8.dp,
                                modifier = Modifier.size(12.dp),
                            )
                        }
                    }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(42.dp)
                        .clip(RoundedCornerShape(13.dp))
                        .background(palette.accentGradient)
                        .clickable(enabled = !busy) {
                            if (zip) caseAccess.openZip(block.imageId)
                            else open(share = false)
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.Center,
                    ) {
                        Icon(
                            imageVector = if (zip) Icons.Default.FolderZip else Icons.Default.Visibility,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = if (pdf) "预览报告" else if (zip) "卷内浏览" else "预览",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = Color.White,
                            maxLines = 1,
                        )
                    }
                }

                Surface(
                    onClick = { open(share = true) },
                    enabled = !busy,
                    shape = RoundedCornerShape(13.dp),
                    color = palette.surfaceMuted,
                    border = BorderStroke(0.6.dp, palette.border),
                    modifier = Modifier.height(42.dp),
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 18.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Default.Share,
                            contentDescription = null,
                            tint = palette.ink,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = "转发微信",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            color = palette.ink,
                            maxLines = 1,
                        )
                    }
                }
            }

            val extraCount = caseAccess.files.count { it.id != block.imageId }
            if (pdf && extraCount > 0) {
                HorizontalDivider(thickness = 0.5.dp, color = palette.border)
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .clickable(onClick = caseAccess.open)
                        .padding(vertical = 4.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = "附 $extraCount 项核验图与资料 · 查看 ›",
                        fontSize = 12.5.sp,
                        fontWeight = FontWeight.Medium,
                        color = palette.accent,
                    )
                }
            }

            error?.let {
                Text(it, color = palette.report, fontSize = 12.sp)
            }
        }
    }
}
