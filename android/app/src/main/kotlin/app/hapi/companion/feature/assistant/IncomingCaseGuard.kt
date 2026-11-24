package app.hapi.companion.feature.assistant
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
internal enum class IncomingCaseRoute { Draft, AskCurrentCase }
internal fun incomingCaseRoute(currentSessionId: String?) = if(currentSessionId.isNullOrBlank()) IncomingCaseRoute.Draft else IncomingCaseRoute.AskCurrentCase
@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun IncomingCaseGuard(count: Int,newCase: () -> Unit,currentCase: () -> Unit,dismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest=dismiss,containerColor=assistantPaper(),contentColor=MaterialTheme.colorScheme.onSurface) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
            Text("收到分享的 $count 份资料",style=MaterialTheme.typography.titleLarge)
            Text("请选择送审案件",style=MaterialTheme.typography.bodyMedium)
            Button(newCase,Modifier.fillMaxWidth()) { Text("新建尽调送审") }
            OutlinedButton(currentCase,Modifier.fillMaxWidth()) { Text("补传到当前案") }
        }
    }
}
