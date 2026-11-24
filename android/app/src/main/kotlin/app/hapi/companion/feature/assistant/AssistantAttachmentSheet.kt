package app.hapi.companion.feature.assistant
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
@OptIn(ExperimentalMaterial3Api::class)
@Composable fun AssistantAttachmentSheet(onDismiss: () -> Unit,onCamera: () -> Unit,onPhotos: () -> Unit,onPdf: () -> Unit) {
    ModalBottomSheet(onDismiss) {
        Column(Modifier.padding(horizontal=16.dp).padding(bottom=24.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            listOf(Triple("拍照拍摄单据",Icons.Default.PhotoCamera,onCamera),Triple("从相册选择图片",Icons.Default.PhotoLibrary,onPhotos),Triple("选择文件（PDF / ZIP / Office）",Icons.Default.PictureAsPdf,onPdf)).forEachIndexed { i, item ->
                val tint = assistantSceneColors[listOf(2,0,1)[i]]
                Surface(onClick={onDismiss();item.third()},shape=RoundedCornerShape(14.dp),color=assistantPaper()) {
                    Row(Modifier.fillMaxWidth().padding(14.dp),verticalAlignment=Alignment.CenterVertically) {
                        Surface(shape=RoundedCornerShape(10.dp),color=tint.copy(alpha=.12f)) { Icon(item.second,null,Modifier.padding(10.dp).size(22.dp),tint=tint) }
                        Text(item.first,Modifier.padding(start=14.dp).weight(1f),style=MaterialTheme.typography.bodyLarge)
                        Icon(Icons.Default.ChevronRight,null,Modifier.size(18.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}
