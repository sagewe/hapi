package app.hapi.companion.feature.chat

import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
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
            is ToolGroupBlock -> { AssistantStage(block.tools, modifier); return }
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

@Composable private fun AssistantStage(tools: List<ToolCallBlock>, modifier: Modifier) {
    if (tools.isEmpty()) return
    val running = tools.any { it.tool.state == "running" || it.tool.state == "pending" }
    val names = tools.joinToString { it.tool.name + " " + it.tool.input.toString() }.lowercase()
    val phase = when {
        "pdf" in names || "render" in names -> "正在排版调查报告"
        "search" in names -> "正在检索公开线索"
        "web" in names || "fetch" in names || "browse" in names -> "正在核验官网与公开来源"
        "read" in names || "parse" in names -> "正在解析资料与单据"
        else -> "正在整理调查证据"
    }
    androidx.compose.material3.Text(if (running) phase + "…" else "已完成 ${tools.size} 项调查步骤", modifier, style = androidx.compose.material3.MaterialTheme.typography.bodySmall)
}
