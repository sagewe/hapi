package app.hapi.companion.feature.assistant
import androidx.compose.material3.*
import androidx.compose.runtime.*
import app.hapi.companion.di.LocalAppGraph
import kotlinx.coroutines.launch
@Composable fun AssistantConversationShell(drawer: DrawerState, content: @Composable () -> Unit) {
    if(app.hapi.companion.di.LocalClientProfile.current?.mode != "assistant") { content(); return }
    val graph = LocalAppGraph.current.activeHubGraph.collectAsState().value ?: return
    val navigation = AssistantNavigation.current
    val scope = rememberCoroutineScope()
    ModalNavigationDrawer(drawerState = drawer, drawerContent = {
        AssistantHistoryDrawer(graph, { id -> scope.launch { drawer.close(); navigation.chat(id) } }, navigation.settings, navigation.home)
    }, content = content)
}
