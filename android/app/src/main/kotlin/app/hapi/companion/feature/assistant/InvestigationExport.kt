package app.hapi.companion.feature.assistant
import app.hapi.protocol.wire.DecryptedMessage
import app.hapi.protocol.chat.*
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/** Uses the same normalizer/reducer as the transcript; tool/reasoning payloads never become prose. */
internal fun investigationExport(title: String,messages: List<DecryptedMessage>): String {
    val normalized=messages.mapNotNull { message ->
        val envelope=message.content as? JsonObject
        if((envelope?.get("role") as? JsonPrimitive)?.contentOrNull !in listOf("user","agent")) null else normalizeDecryptedMessage(message)
    }
    val blocks=reduceChatBlocks(normalized,null).blocks
    return buildString {
        append("# ").append(title).append("\n\n> 琪琪工作 · 调查记录\n\n")
        blocks.forEach { block -> when(block) {
            is UserTextBlock -> {append("## 调查提问\n\n").append(block.text).append("\n\n");block.attachments.orEmpty().forEach {append("附件：").append(it.filename).append("\n\n")} }
            is AgentTextBlock -> append("## 调查回复\n\n").append(block.text).append("\n\n")
            is GeneratedImageBlock -> append("交付文件：").append(block.fileName).append("\n\n")
            else -> Unit
        } }
    }.trimEnd()+"\n"
}
internal fun investigationFilename(title: String): String = title.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"),"_").trim().trim('.').take(80).ifBlank {"调查记录"}+".md"
