package app.hapi.companion.feature.assistant
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.hapi.companion.di.HubGraph

@Composable internal fun AssistantHistoryDrawer(hub: HubGraph, onOpen: (String) -> Unit, onSettings: () -> Unit, onNew: (() -> Unit)? = null) {
    val sessions by hub.sessionStore.sessions.collectAsState()
    var search by remember { mutableStateOf("") }
    var archived by remember { mutableStateOf(false) }
    var tag by remember { mutableStateOf<String?>(null) }
    ModalDrawerSheet(Modifier.fillMaxWidth(.88f)) {
        Text("历史调查", Modifier.padding(20.dp), style = MaterialTheme.typography.titleLarge)
        OutlinedTextField(search, { search = it }, placeholder = { Text("搜索调查") }, modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth())
        Row(Modifier.padding(horizontal = 16.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FilterChip(archived, { archived = !archived }, { Text("已归档") })
            sessions.flatMap { it.metadata?.tags.orEmpty() }.distinct().forEach { value -> FilterChip(tag == value, { tag = if(tag == value) null else value }, { Text(value.removePrefix("#")) }) }
        }
        LazyColumn(Modifier.weight(1f)) {
            items(sessions.filter { s -> s.hasConversationContent && (if(archived) s.metadata?.lifecycleState == "archived" else s.metadata?.lifecycleState != "archived") && (tag == null || tag in s.metadata?.tags.orEmpty()) && ((s.metadata?.name ?: "").contains(search, true) || s.metadata?.tags.orEmpty().any { it.contains(search,true) }) }.sortedByDescending { it.updatedAt }, key = { it.id }) { s ->
                val title = s.metadata?.name ?: "调查"
                val kind = when { listOf("单据", "审核", "PDF").any { title.contains(it,true) } -> 2; listOf("自然人", "实控人").any { title.contains(it) } -> 1; title.contains("制裁") -> 3; else -> 0 }
                val tint = assistantSceneColors[kind]
                ListItem(headlineContent = { Text(title) }, supportingContent = {
                    Column {
                        if(s.metadata?.tags.orEmpty().isNotEmpty()) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            s.metadata?.tags.orEmpty().forEach { value -> Surface(color = tint.copy(alpha = .1f), shape = RoundedCornerShape(5.dp)) { Text(value.removePrefix("#"), Modifier.padding(horizontal = 6.dp, vertical = 2.dp), style = MaterialTheme.typography.labelSmall, color = tint) } }
                        }
                        if(s.thinking) Text("调查中…") else if(s.pendingRequestsCount > 0) Text("等待回复")
                    }
                }, leadingContent = {
                    Surface(color = tint.copy(alpha = .12f), shape = RoundedCornerShape(8.dp), modifier = Modifier.size(32.dp)) { Icon(listOf(Icons.Default.Business,Icons.Default.PersonSearch,Icons.Default.Description,Icons.Default.Policy)[kind], null, tint = tint, modifier = Modifier.padding(6.dp)) }
                }, modifier = Modifier.clickable { onOpen(s.id) })
                HorizontalDivider(Modifier.padding(start = 56.dp), thickness = .5.dp)
            }
        }
        onNew?.let { TextButton(it, Modifier.fillMaxWidth()) { Text("新建调查") } }
        TextButton(onSettings, Modifier.fillMaxWidth().navigationBarsPadding()) { Icon(Icons.Default.Settings, null); Spacer(Modifier.width(8.dp)); Text("设置") }
    }
}
