package app.hapi.companion.feature.assistant

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CompareArrows
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AssistantAttachmentSheet(
    onDismiss: () -> Unit,
    onCamera: () -> Unit,
    onPhotos: () -> Unit,
    onPdf: () -> Unit,
    useCodex: Boolean = false,
    onToggleCodex: (() -> Unit)? = null,
) {
    val palette = assistantPalette()
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = palette.background,
        contentColor = palette.ink,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 16.dp)
                .padding(bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Surface(
                shape = RoundedCornerShape(20.dp),
                color = palette.surface,
                border = BorderStroke(0.5.dp, palette.border),
            ) {
                Column(modifier = Modifier.padding(6.dp)) {
                    AttachmentMenuRow("拍照", Icons.Default.PhotoCamera) {
                        onDismiss()
                        onCamera()
                    }
                    AttachmentMenuRow("相册图片", Icons.Default.PhotoLibrary) {
                        onDismiss()
                        onPhotos()
                    }
                    AttachmentMenuRow("选择文件（PDF / ZIP / Office）", Icons.Default.Description) {
                        onDismiss()
                        onPdf()
                    }
                    if (onToggleCodex != null) {
                        HorizontalDivider(
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                            thickness = 0.5.dp,
                            color = palette.border,
                        )
                        AttachmentMenuRow(
                            title = if (useCodex) "切回标准调查" else "用 Codex 交叉核验",
                            icon = if (useCodex) Icons.Default.VerifiedUser else Icons.Default.CompareArrows,
                        ) {
                            onDismiss()
                            onToggleCodex()
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AttachmentMenuRow(
    title: String,
    icon: ImageVector,
    onClick: () -> Unit,
) {
    val palette = assistantPalette()
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(14.dp),
        color = palette.surface,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 50.dp)
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(
                modifier = Modifier.size(28.dp),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = palette.inkSecondary,
                    modifier = Modifier.size(20.dp),
                )
            }
            Text(
                text = title,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                color = palette.ink,
                maxLines = 1,
            )
        }
    }
}
