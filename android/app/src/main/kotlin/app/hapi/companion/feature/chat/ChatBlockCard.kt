package app.hapi.companion.feature.chat

import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.*
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import app.hapi.companion.feature.chat.blocks.AgentEventBlockView
import app.hapi.companion.feature.chat.blocks.AgentReasoningBlockView
import app.hapi.companion.feature.chat.blocks.AgentTextBlockView
import app.hapi.companion.feature.chat.blocks.CliOutputBlockView
import app.hapi.companion.feature.chat.blocks.CodexReviewBlockView
import app.hapi.companion.feature.chat.blocks.GeneratedImageBlockView
import app.hapi.companion.feature.chat.blocks.ToolCallBlockView
import app.hapi.companion.feature.chat.blocks.ToolGroupBlockView
import app.hapi.companion.feature.chat.blocks.UserTextBlockView
import app.hapi.protocol.chat.AgentEventBlock
import app.hapi.protocol.chat.AgentReasoningBlock
import app.hapi.protocol.chat.AgentTextBlock
import app.hapi.protocol.chat.ChatBlock
import app.hapi.protocol.chat.CliOutputBlock
import app.hapi.protocol.chat.CodexReviewBlock
import app.hapi.protocol.chat.GeneratedImageBlock
import app.hapi.protocol.chat.ToolCallBlock
import app.hapi.protocol.chat.ToolGroupBlock
import app.hapi.protocol.chat.UserTextBlock
import app.hapi.protocol.chat.VisibleChatBlock
import coil.ImageLoader
import java.io.File

/**
 * Hub-scoped media plumbing for chat blocks: the authed Coil loader, the
 * generated-image URL builder (both from `HubGraph`) and the raw byte
 * fetcher used by non-image generated media (video/audio/file download to
 * the media cache). Null loader/fetcher (previews, tests) degrade: images
 * to a filename placeholder, gated media to the unavailable error line.
 */
data class ChatMedia(
    val imageLoader: ImageLoader?,
    val generatedImageUrl: (imageId: String) -> String?,
    val fetchGeneratedMedia: (suspend (url: String, imageId: String, fileName: String) -> File)? = null,
)

val LocalChatMedia = staticCompositionLocalOf {
    ChatMedia(imageLoader = null, generatedImageUrl = { null })
}

/** Stable LazyColumn key. */
val VisibleChatBlock.stableId: String
    get() = when (this) {
        is ChatBlock -> id
        is ToolGroupBlock -> id
    }

/** LazyColumn contentType (recycling bucket). */
val VisibleChatBlock.contentKind: String
    get() = when (this) {
        is ChatBlock -> kind
        is ToolGroupBlock -> kind
    }

/**
 * One thread entry: dispatches a reduced [VisibleChatBlock] to its card —
 * the Compose analogue of the web's block-kind → component mapping
 * (`HappyThread` user/assistant/system messages + `ToolCard`/`ToolGroupCard`).
 * Also used recursively for tool-call children (sidechains).
 */
@Composable
fun ChatBlockCard(
    block: VisibleChatBlock,
    basePath: String?,
    modifier: Modifier = Modifier,
    processSteps: Int? = null,
) {
    if (app.hapi.companion.di.LocalClientProfile.current?.mode == "assistant") {
        when (block) {
            is GeneratedImageBlock -> if (block.fileName.endsWith(".pdf", true) || block.fileName.endsWith(".zip", true)) {
                app.hapi.companion.feature.assistant.DeliveryCard(block, modifier); return
            }
            is AgentReasoningBlock, is CliOutputBlock -> return
            is ToolCallBlock -> { AssistantStage(listOf(block), modifier); return }
            is ToolGroupBlock -> { AssistantStage(block.tools, modifier, block.summary,block.id); return }
            else -> Unit
        }
    }
    when (block) {
        is UserTextBlock -> UserTextBlockView(block, modifier)
        is AgentTextBlock -> AgentTextBlockView(block, modifier)
        is AgentReasoningBlock -> AgentReasoningBlockView(block, modifier)
        is AgentEventBlock -> AgentEventBlockView(block, modifier)
        is CliOutputBlock -> CliOutputBlockView(block, modifier)
        is GeneratedImageBlock -> GeneratedImageBlockView(block, modifier)
        is CodexReviewBlock -> CodexReviewBlockView(block, modifier)
        is ToolCallBlock -> ToolCallBlockView(block, basePath, modifier, processSteps)
        is ToolGroupBlock -> ToolGroupBlockView(block, basePath, modifier)
    }
}

@Composable private fun AssistantStage(tools: List<ToolCallBlock>, modifier: Modifier, summary: app.hapi.protocol.chat.ToolGroupSummary? = null, groupId: String? = null) {
    val label = assistantStageText(tools, summary) ?: return
    val running = label.startsWith("正在")
    val totalSteps = summary?.totalTools ?: tools.size
    val inspection = LocalChatInspection.current
    val palette = app.hapi.companion.feature.assistant.assistantPalette()
    androidx.compose.material3.Surface(
        onClick = { if (groupId != null) inspection?.openGroup(groupId) else tools.firstOrNull()?.id?.let { inspection?.openTool(it) } },
        enabled = inspection != null && (groupId != null || tools.isNotEmpty()),
        color = if (running) palette.accentSoft else palette.surface,
        shape = androidx.compose.foundation.shape.RoundedCornerShape(14.dp),
        border = androidx.compose.foundation.BorderStroke(
            width = if (running) 1.dp else 0.5.dp,
            color = if (running) palette.accentBorder else palette.border,
        ),
        modifier = modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        androidx.compose.foundation.layout.Row(
            androidx.compose.ui.Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        ) {
            if (running) {
                app.hapi.companion.feature.assistant.AssistantOrbitingRing(
                    color = palette.accent,
                    strokeWidth = 1.7.dp,
                    modifier = androidx.compose.ui.Modifier.size(14.dp),
                )
            } else {
                androidx.compose.material3.Icon(
                    androidx.compose.material.icons.Icons.Default.CheckCircle,
                    null,
                    androidx.compose.ui.Modifier.size(16.dp),
                    tint = palette.accent,
                )
            }
            androidx.compose.material3.Text(
                label,
                androidx.compose.ui.Modifier.padding(start = 10.dp).weight(1f),
                style = androidx.compose.material3.MaterialTheme.typography.labelMedium,
                color = if (running) palette.ink else palette.inkSecondary,
            )
            if (running && totalSteps > 0) {
                androidx.compose.material3.Surface(
                    shape = androidx.compose.foundation.shape.CircleShape,
                    color = palette.accent.copy(alpha = 0.14f),
                    modifier = androidx.compose.ui.Modifier.padding(end = 6.dp),
                ) {
                    androidx.compose.material3.Text(
                        "$totalSteps 步",
                        style = androidx.compose.material3.MaterialTheme.typography.labelSmall,
                        color = palette.accent,
                        modifier = androidx.compose.ui.Modifier.padding(horizontal = 7.dp, vertical = 2.dp),
                    )
                }
            }
            androidx.compose.material3.Icon(
                androidx.compose.material.icons.Icons.Default.ChevronRight,
                "展开查证步骤",
                androidx.compose.ui.Modifier.size(16.dp),
                tint = palette.inkMuted,
            )
        }
    }
}

/** Compact groups can omit their retained tool objects; summary remains authoritative. */
internal fun assistantStageText(tools: List<ToolCallBlock>, summary: app.hapi.protocol.chat.ToolGroupSummary? = null): String? {
    val total = summary?.totalTools ?: tools.size
    if (total == 0) return null
    val running = (summary?.runningCount ?: 0) + (summary?.pendingCount ?: 0) > 0 || tools.any { it.tool.state == "running" || it.tool.state == "pending" }
    val names = (tools.joinToString { it.tool.name + " " + it.tool.input.toString() } + summary?.commandTargets.orEmpty().joinToString() + summary?.fileTargets.orEmpty().joinToString()).lowercase()
    val kinds = summary?.countsByKind.orEmpty()
    val phase = when {
        "pdf" in names || "render" in names -> "正在排版调查报告"
        "search" in names || (kinds[app.hapi.protocol.chat.ToolGroupActionKind.SEARCH] ?: 0) > 0 -> "正在检索公开线索"
        "web" in names || "fetch" in names || "browse" in names || (kinds[app.hapi.protocol.chat.ToolGroupActionKind.WEB] ?: 0) > 0 -> "正在核验官网与公开来源"
        "read" in names || "parse" in names || (kinds[app.hapi.protocol.chat.ToolGroupActionKind.READ] ?: 0) > 0 -> "正在解析资料与单据"
        else -> "正在整理调查证据"
    }
    return if (running) phase + "…" else "已完成 $total 步查证"
}
