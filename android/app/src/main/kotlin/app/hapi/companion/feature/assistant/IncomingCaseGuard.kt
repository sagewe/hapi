package app.hapi.companion.feature.assistant

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.hapi.companion.feature.share.SharedFile
import app.hapi.companion.feature.share.SharedFileStatus

internal enum class IncomingCaseRoute { Draft, AskCurrentCase }

internal fun incomingCaseRoute(currentSessionId: String?) =
    if (currentSessionId.isNullOrBlank()) IncomingCaseRoute.Draft else IncomingCaseRoute.AskCurrentCase

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun IncomingCaseGuard(
    files: List<SharedFile>,
    title: String?,
    newCase: () -> Unit,
    currentCase: () -> Unit,
    dismiss: () -> Unit,
) {
    val palette = assistantPalette()
    val canAppend = title != null && files.all { it.status == SharedFileStatus.Ready }
    ModalBottomSheet(
        onDismissRequest = dismiss,
        containerColor = palette.background,
        contentColor = palette.ink,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 20.dp)
                .padding(bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = "收到分享的 ${files.size} 份资料",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                color = palette.ink,
            )
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                files.take(3).forEach {
                    Text(
                        text = "${it.filename} · " + when (it.status) {
                            SharedFileStatus.Ready -> formatByteSize(it.size)
                            SharedFileStatus.Copying -> "正在读取"
                            else -> "读取失败，请重新分享"
                        },
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        fontSize = 13.sp,
                        color = palette.inkSecondary,
                    )
                }
                if (files.size > 3) {
                    Text("等共 ${files.size} 份", fontSize = 12.sp, color = palette.inkMuted)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(44.dp)
                        .clip(CircleShape)
                        .background(palette.accentGradient)
                        .clickable(onClick = newCase),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = "新建尽调送审",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.White,
                        maxLines = 1,
                    )
                }
                Surface(
                    onClick = currentCase,
                    enabled = canAppend,
                    shape = CircleShape,
                    color = palette.surfaceMuted,
                    border = BorderStroke(0.5.dp, palette.border),
                    modifier = Modifier
                        .weight(1f)
                        .height(44.dp),
                ) {
                    Box(
                        modifier = Modifier.padding(horizontal = 12.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = if (title == null) "正在确认当前案件…" else "补传到「$title」",
                            fontSize = 13.5.sp,
                            fontWeight = FontWeight.Medium,
                            color = if (canAppend) palette.ink else palette.inkMuted,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}
