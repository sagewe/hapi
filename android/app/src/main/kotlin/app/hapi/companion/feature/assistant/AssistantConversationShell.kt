package app.hapi.companion.feature.assistant
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.hapi.companion.di.LocalAppGraph

@Composable fun AssistantConversationShell(drawer: DrawerState, content: @Composable () -> Unit) {
    if(app.hapi.companion.di.LocalClientProfile.current?.mode != "assistant") { content(); return }
    val graph = LocalAppGraph.current.activeHubGraph.collectAsState().value ?: return
    val sessions by graph.sessionStore.sessions.collectAsState()
    val navigation = AssistantNavigation.current
    var search by remember { mutableStateOf("") }
    ModalNavigationDrawer(drawerState = drawer, drawerContent = {
        ModalDrawerSheet(Modifier.fillMaxWidth(.88f)) {
            Text("历史调查", Modifier.padding(20.dp), style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(search, { search = it }, placeholder = { Text("搜索调查") }, modifier = Modifier.padding(16.dp))
            LazyColumn(Modifier.weight(1f)) {
                items(sessions.filter { it.hasConversationContent && (it.metadata?.name ?: "").contains(search, true) }.sortedByDescending { it.updatedAt }) { s ->
                    ListItem(headlineContent = { Text(s.metadata?.name ?: "调查") }, supportingContent = { if(s.thinking) Text("调查中…") else if(s.pendingRequestsCount > 0) Text("等待回复") }, modifier = Modifier.clickable { navigation.chat(s.id) })
                    HorizontalDivider(thickness = .5.dp)
                }
            }
            TextButton(navigation.home, Modifier.fillMaxWidth()) { Text("新建调查") }
            TextButton(navigation.settings, Modifier.fillMaxWidth().navigationBarsPadding()) { Text("设置") }
        }
    }, content = content)
}
