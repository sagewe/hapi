package app.hapi.companion.feature.assistant

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.hapi.companion.BuildConfig
import app.hapi.companion.di.HubGraph
import kotlinx.coroutines.delay

@Composable internal fun AssistantHistoryDrawer(hub: HubGraph,onOpen: (String)->Unit,onSettings: ()->Unit,onNew: (() -> Unit)?=null) {
    val sessions by hub.sessionStore.sessions.collectAsState()
    var search by remember { mutableStateOf("") }; var archived by remember { mutableStateOf(false) }; var tag by remember { mutableStateOf<String?>(null) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while(true) { now=System.currentTimeMillis();delay(30000) } }
    val visible = sessions.filter { s -> s.hasConversationContent && (if(archived) s.metadata?.lifecycleState=="archived" else s.metadata?.lifecycleState!="archived") && (tag==null || tag in s.metadata?.tags.orEmpty()) && ((s.metadata?.name ?: "").contains(search,true) || s.metadata?.tags.orEmpty().any { it.contains(search,true) }) }.sortedByDescending { it.updatedAt }
    val updater=hub.androidUpdates
    val update by (updater?.state ?: remember { kotlinx.coroutines.flow.MutableStateFlow(app.hapi.companion.feature.updates.AndroidUpdateState()) }).collectAsState()
    ModalDrawerSheet(Modifier.fillMaxWidth(.88f)) {
        Text("历史调查",Modifier.padding(horizontal=20.dp,vertical=22.dp),style=MaterialTheme.typography.titleLarge,fontWeight=FontWeight.SemiBold)
        TextField(search,{search=it},placeholder={Text("搜索调查")},leadingIcon={Icon(Icons.Default.Search,null,Modifier.size(20.dp))},
            trailingIcon=if(search.isNotEmpty()) {{IconButton({search=""}) {Icon(Icons.Default.Close,"清除搜索",Modifier.size(18.dp))}}} else null,
            singleLine=true,shape=RoundedCornerShape(14.dp),modifier=Modifier.padding(horizontal=16.dp).fillMaxWidth(),
            colors=TextFieldDefaults.colors(focusedIndicatorColor=Color.Transparent,unfocusedIndicatorColor=Color.Transparent,
                focusedContainerColor=MaterialTheme.colorScheme.surfaceContainerHigh,unfocusedContainerColor=MaterialTheme.colorScheme.surfaceContainerHigh))
        Row(Modifier.padding(horizontal=16.dp,vertical=12.dp).horizontalScroll(rememberScrollState()),horizontalArrangement=Arrangement.spacedBy(6.dp)) {
            HistoryFilter("已归档",archived,{archived=!archived},Icons.Default.Inventory2)
            sessions.flatMap { it.metadata?.tags.orEmpty() }.distinct().forEach { value -> HistoryFilter(value.removePrefix("#"),tag==value,{tag=if(tag==value)null else value}) }
        }
        LazyColumn(Modifier.weight(1f)) {
            visible.groupBy { historyGroup(it.updatedAt,now) }.forEach { (group,rows) ->
                item(key="group-$group") { Text(group,Modifier.padding(start=20.dp,top=16.dp,bottom=8.dp),style=MaterialTheme.typography.labelMedium,color=MaterialTheme.colorScheme.onSurfaceVariant) }
                items(rows,key={it.id}) { s ->
                    val title=s.metadata?.name ?: "调查"
                    val kind=when {listOf("单据","审核","PDF").any {title.contains(it,true)}->2; listOf("自然人","实控人").any {title.contains(it)}->1;title.contains("制裁")->3;else->0}
                    val tint=assistantSceneColors[kind]
                    Row(Modifier.fillMaxWidth().clickable {onOpen(s.id)}.padding(horizontal=18.dp,vertical=12.dp),verticalAlignment=Alignment.Top) {
                        Surface(color=tint.copy(alpha=.12f),shape=RoundedCornerShape(9.dp),modifier=Modifier.size(34.dp)) { Icon(listOf(Icons.Default.Business,Icons.Default.PersonSearch,Icons.Default.Description,Icons.Default.Policy)[kind],null,Modifier.padding(7.dp),tint=tint) }
                        Column(Modifier.padding(start=12.dp).weight(1f)) {
                            Row(verticalAlignment=Alignment.CenterVertically) {
                                Text(title,Modifier.weight(1f),style=MaterialTheme.typography.bodyMedium,fontWeight=FontWeight.Medium,maxLines=2,overflow=TextOverflow.Ellipsis)
                                if(s.readState?.manualUnread==true || (s.contentRevision ?: 0)>(s.readState?.readRevision ?: 0)) Box(Modifier.padding(start=6.dp).size(6.dp).background(MaterialTheme.colorScheme.primary,CircleShape))
                            }
                            if(s.metadata?.tags.orEmpty().isNotEmpty()) Row(Modifier.padding(top=6.dp).horizontalScroll(rememberScrollState()),horizontalArrangement=Arrangement.spacedBy(4.dp)) {
                                s.metadata?.tags.orEmpty().forEach { value -> Surface(color=tint.copy(alpha=.09f),shape=RoundedCornerShape(5.dp)) { Text(value.removePrefix("#"),Modifier.padding(horizontal=6.dp,vertical=2.dp),style=MaterialTheme.typography.labelSmall,color=tint,maxLines=1,softWrap=false) } }
                            }
                            if(s.thinking || s.pendingRequestsCount>0) Text(if(s.thinking) "调查中…" else "等待回复",Modifier.padding(top=5.dp),style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.primary)
                        }
                        Text(historyRelativeTime(s.updatedAt,now),Modifier.padding(start=8.dp,top=2.dp),style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant,maxLines=1,softWrap=false)
                    }
                    HorizontalDivider(Modifier.padding(start=64.dp,end=18.dp),thickness=.5.dp,color=MaterialTheme.colorScheme.outlineVariant.copy(alpha=.5f))
                }
            }
        }
        if(update.available) Surface(onClick=onSettings,shape=CircleShape,color=MaterialTheme.colorScheme.primaryContainer,modifier=Modifier.padding(horizontal=18.dp,vertical=8.dp)) {
            Text("发现新版本",Modifier.padding(horizontal=14.dp,vertical=8.dp),style=MaterialTheme.typography.labelMedium,color=MaterialTheme.colorScheme.onPrimaryContainer)
        }
        onNew?.let { TextButton(it,Modifier.padding(start=10.dp)) {Icon(Icons.Default.Add,null,Modifier.size(18.dp));Text("新建调查",Modifier.padding(start=8.dp))} }
        HorizontalDivider(Modifier.padding(horizontal=18.dp),thickness=.5.dp)
        Row(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal=12.dp,vertical=8.dp),verticalAlignment=Alignment.CenterVertically) {
            TextButton(onSettings) {Icon(Icons.Default.Settings,null,Modifier.size(20.dp));Text("设置",Modifier.padding(start=8.dp))}
            Spacer(Modifier.weight(1f));Text("v${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",Modifier.padding(end=8.dp),style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
@Composable private fun HistoryFilter(label: String,selected: Boolean,onClick: ()->Unit,icon: androidx.compose.ui.graphics.vector.ImageVector?=null) {
    Surface(onClick=onClick,shape=CircleShape,color=if(selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha=.6f),contentColor=if(selected) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurfaceVariant) {
        Row(Modifier.padding(horizontal=12.dp,vertical=8.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(5.dp)) {
            icon?.let {Icon(it,null,Modifier.size(14.dp))};Text(label,style=MaterialTheme.typography.labelMedium,maxLines=1,softWrap=false)
        }
    }
}
