package app.hapi.companion.feature.assistant

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.hapi.companion.di.HubGraph
import app.hapi.protocol.wire.SessionSummary
import kotlinx.coroutines.delay

/**
 * MyDots-style bottom-weighted history drawer aligned with iOS `AssistantHistoryDrawer`:
 * - Clean header with brand title + circular search toggle button.
 * - Optional collapsible search bar + horizontal solid-ink filter chips + archive toggle.
 * - Bottom-weighted session list when idle (newest cases closest to the thumb); flips to
 *   top-down while searching so keyboard never obscures results.
 * - Bottom thumb bar: bold solid-ink `新调查` pill + circular Settings button.
 */
@Composable
internal fun AssistantHistoryDrawer(
    hub: HubGraph,
    onOpen: (String) -> Unit,
    onSettings: () -> Unit,
    onNew: (() -> Unit)? = null,
    brandTitle: String = "琪琪工作",
    selectedSessionId: String? = null,
) {
    val palette = assistantPalette()
    val sessions by hub.sessionStore.sessions.collectAsState()
    var isSearching by remember { mutableStateOf(false) }
    var search by remember { mutableStateOf("") }
    var archived by remember { mutableStateOf(false) }
    var tag by remember { mutableStateOf<String?>(null) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val searchFocus = remember { FocusRequester() }

    LaunchedEffect(Unit) {
        while (true) {
            now = System.currentTimeMillis()
            delay(30_000)
        }
    }
    LaunchedEffect(isSearching) {
        if (isSearching) runCatching { searchFocus.requestFocus() }
    }

    val availableTags = remember(sessions) {
        sessions.flatMap { it.metadata?.tags.orEmpty() }.distinct().sorted()
    }
    val visible = remember(sessions, archived, tag, search) {
        sessions
            .filter { s ->
                s.hasConversationContent &&
                    (if (archived) s.metadata?.lifecycleState == "archived" else s.metadata?.lifecycleState != "archived") &&
                    (tag == null || tag in s.metadata?.tags.orEmpty()) &&
                    (search.isBlank() ||
                        (s.metadata?.name ?: "").contains(search, ignoreCase = true) ||
                        s.metadata?.tags.orEmpty().any { it.contains(search, ignoreCase = true) })
            }
            .sortedByDescending { it.updatedAt }
    }

    val updater = hub.androidUpdates
    val update by (updater?.state ?: remember {
        kotlinx.coroutines.flow.MutableStateFlow(app.hapi.companion.feature.updates.AndroidUpdateState())
    }).collectAsState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(palette.background)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        // Header: Brand title + circular search toggle button.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = brandTitle,
                fontSize = 24.sp,
                fontWeight = FontWeight.Bold,
                color = palette.ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Surface(
                onClick = {
                    isSearching = !isSearching
                    if (!isSearching) search = ""
                },
                shape = CircleShape,
                color = palette.surface,
                border = BorderStroke(0.5.dp, palette.border),
                shadowElevation = 2.dp,
                modifier = Modifier.size(42.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = if (isSearching) Icons.Default.Close else Icons.Default.Search,
                        contentDescription = if (isSearching) "关闭搜索" else "搜索调查",
                        tint = palette.ink,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }

        AnimatedVisibility(visible = isSearching) {
            Row(
                modifier = Modifier
                    .padding(horizontal = 16.dp)
                    .padding(bottom = 8.dp)
                    .fillMaxWidth()
                    .height(38.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(palette.surfaceMuted)
                    .padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    imageVector = Icons.Default.Search,
                    contentDescription = null,
                    tint = palette.inkMuted,
                    modifier = Modifier.size(16.dp),
                )
                BasicTextField(
                    value = search,
                    onValueChange = { search = it },
                    singleLine = true,
                    textStyle = TextStyle(fontSize = 15.sp, color = palette.ink),
                    cursorBrush = SolidColor(palette.accent),
                    modifier = Modifier
                        .weight(1f)
                        .focusRequester(searchFocus),
                    decorationBox = { inner ->
                        Box(contentAlignment = Alignment.CenterStart) {
                            if (search.isEmpty()) {
                                Text(
                                    text = "搜索案件、主体或标签",
                                    fontSize = 14.sp,
                                    color = palette.inkMuted,
                                    maxLines = 1,
                                )
                            }
                            inner()
                        }
                    },
                )
                if (search.isNotEmpty()) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = "清除搜索",
                        tint = palette.inkMuted,
                        modifier = Modifier
                            .size(16.dp)
                            .clickable { search = "" },
                    )
                }
            }
        }

        if (availableTags.isNotEmpty() || archived) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
                    .padding(bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Row(
                    modifier = Modifier
                        .weight(1f)
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    DrawerFilterChip("全部", active = tag == null) { tag = null }
                    availableTags.forEach { value ->
                        DrawerFilterChip(
                            label = value.removePrefix("#"),
                            active = tag == value,
                        ) { tag = if (tag == value) null else value }
                    }
                }
                Surface(
                    onClick = { archived = !archived },
                    shape = CircleShape,
                    color = if (archived) palette.accentSoft else palette.surfaceMuted,
                    modifier = Modifier.height(28.dp),
                ) {
                    Box(
                        modifier = Modifier.padding(horizontal = 9.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Default.Inventory2,
                            contentDescription = "显示已归档调查",
                            tint = if (archived) palette.accent else palette.inkMuted,
                            modifier = Modifier.size(14.dp),
                        )
                    }
                }
            }
        }

        HorizontalDivider(
            modifier = Modifier.padding(horizontal = 20.dp),
            thickness = 0.5.dp,
            color = palette.border,
        )

        // Bottom-weighted list when browsing (`reverseLayout = !isSearching` puts index 0
        // — the newest session — right at the bottom next to the user's thumb!).
        if (visible.isEmpty()) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp, vertical = 16.dp),
                contentAlignment = if (isSearching) Alignment.TopStart else Alignment.BottomStart,
            ) {
                Text(
                    text = if (search.isBlank()) "还没有调查记录" else "未找到匹配案件",
                    fontSize = 14.sp,
                    color = palette.inkMuted,
                )
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                reverseLayout = !isSearching,
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 6.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                items(visible, key = { it.id }) { session ->
                    AssistantHistoryRowItem(
                        session = session,
                        isCurrent = session.id == selectedSessionId,
                        now = now,
                        onClick = { onOpen(session.id) },
                    )
                }
            }
        }

        if (update.available) {
            Surface(
                onClick = onSettings,
                shape = CircleShape,
                color = palette.accentSoft,
                border = BorderStroke(0.5.dp, palette.accentBorder),
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
            ) {
                Text(
                    text = "发现新版本，轻点前往更新",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = palette.accent,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }
        }

        HorizontalDivider(
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
            thickness = 0.5.dp,
            color = palette.border,
        )

        // MyDots signature bottom thumb bar: solid-ink primary action pill + circular Settings button.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (onNew != null) {
                Surface(
                    onClick = onNew,
                    shape = CircleShape,
                    color = palette.ink,
                    contentColor = palette.inkOnSolid,
                    modifier = Modifier.height(48.dp),
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 22.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Default.EditNote,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                        )
                        Text(
                            text = "新调查",
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                        )
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            Surface(
                onClick = onSettings,
                shape = CircleShape,
                color = palette.surface,
                border = BorderStroke(0.5.dp, palette.border),
                shadowElevation = 2.dp,
                modifier = Modifier.size(48.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = Icons.Default.Settings,
                        contentDescription = "设置",
                        tint = palette.ink,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun DrawerFilterChip(
    label: String,
    active: Boolean,
    onClick: () -> Unit,
) {
    val palette = assistantPalette()
    Surface(
        onClick = onClick,
        shape = CircleShape,
        color = if (active) palette.ink else palette.surfaceMuted,
        contentColor = if (active) palette.inkOnSolid else palette.inkSecondary,
    ) {
        Text(
            text = label,
            fontSize = 12.sp,
            fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
            maxLines = 1,
            softWrap = false,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
        )
    }
}

@Composable
private fun AssistantHistoryRowItem(
    session: SessionSummary,
    isCurrent: Boolean,
    now: Long,
    onClick: () -> Unit,
) {
    val palette = assistantPalette()
    val title = session.metadata?.name?.takeIf { it.isNotBlank() } ?: "调查"
    val tags = session.metadata?.tags.orEmpty()
    val unread = session.readState?.manualUnread == true ||
        (session.contentRevision ?: 0) > (session.readState?.readRevision ?: 0)
    val hasRisk = tags.any { it.contains("风险") || it.contains("制裁") }
    val status = when {
        session.pendingRequestsCount > 0 -> "待回复"
        session.active && session.thinking -> "调查中"
        else -> null
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(if (isCurrent) palette.surfaceMuted else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (unread) {
                    Box(
                        Modifier
                            .size(6.dp)
                            .clip(CircleShape)
                            .background(palette.accent),
                    )
                }
                Text(
                    text = title,
                    fontSize = 15.sp,
                    fontWeight = if (isCurrent || unread) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (isCurrent) palette.ink else palette.inkSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                val firstTag = tags.firstOrNull()?.removePrefix("#")
                if (!firstTag.isNullOrBlank()) {
                    val firstRisk = firstTag.contains("风险") || firstTag.contains("制裁")
                    Text(
                        text = firstTag,
                        fontSize = 11.sp,
                        color = if (firstRisk) palette.risk else palette.inkMuted,
                        maxLines = 1,
                    )
                }
                if (tags.size > 1 && hasRisk) {
                    Text(
                        text = "· 高风险",
                        fontSize = 11.sp,
                        color = palette.risk,
                        maxLines = 1,
                    )
                }
                Text(
                    text = historyRelativeTime(session.updatedAt, now),
                    fontSize = 11.sp,
                    color = palette.inkMuted.copy(alpha = 0.85f),
                    maxLines = 1,
                )
            }
        }

        when (status) {
            "调查中" -> {
                Row(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(palette.accentSoft)
                        .padding(horizontal = 8.dp, vertical = 3.5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    AssistantOrbitingRing(
                        color = palette.accent,
                        strokeWidth = 1.4.dp,
                        modifier = Modifier.size(9.dp),
                    )
                    Text(
                        text = "调查中",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = palette.accent,
                    )
                }
            }
            "待回复" -> {
                Text(
                    text = "待回复",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = palette.risk,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(palette.risk.copy(alpha = 0.14f))
                        .padding(horizontal = 8.dp, vertical = 3.5.dp),
                )
            }
        }
    }
}
