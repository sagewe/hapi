package app.hapi.protocol.wire

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNames
import java.util.UUID

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class RecentDeliverable(
    val id: String,
    @JsonNames("session_id") val sessionId: String,
    @JsonNames("session_title") val sessionTitle: String = "",
    val category: String = "deliverables",
    @JsonNames("filename") val fileName: String,
    @JsonNames("mime_type") val mimeType: String = "application/octet-stream",
    val size: Long = 0,
    @JsonNames("created_at") val createdAt: Double = 0.0,
    @JsonNames("download_path") val downloadPath: String = "",
) {
    val uniqueKey: String get() = "$sessionId:$id"
    val isPdf: Boolean get() = fileName.endsWith(".pdf", ignoreCase = true)
    val isZip: Boolean get() = fileName.endsWith(".zip", ignoreCase = true)
    val isImage: Boolean get() = mimeType.startsWith("image/")
}

@Serializable
data class RecentDeliverablesResponse(val files: List<RecentDeliverable> = emptyList())

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class ReferenceDoc(
    val id: String,
    @JsonNames("filename") val fileName: String,
    @JsonNames("mime_type") val mimeType: String = "application/octet-stream",
    val size: Long = 0,
    val scope: String = "library",
    @JsonNames("scenario_ids") val scenarioIds: List<String> = emptyList(),
    @JsonNames("created_at") val createdAt: Double = 0.0,
    @JsonNames("updated_at") val updatedAt: Double = 0.0,
    @JsonNames("download_path") val downloadPath: String = "",
) {
    val isGlobal: Boolean get() = scope == "global"
    val isImage: Boolean get() = mimeType.startsWith("image/")
    val isPdf: Boolean get() = fileName.endsWith(".pdf", ignoreCase = true)
}

@Serializable
data class ReferenceDocsResponse(val files: List<ReferenceDoc> = emptyList())

@Serializable
data class ReferenceDocResponse(val file: ReferenceDoc)

@Serializable
data class UploadReferenceDocRequest(
    val filename: String,
    val content: String,
    val mimeType: String,
    val scope: String = "library",
    val scenarioIds: List<String> = emptyList(),
)

@Serializable
data class UpdateReferenceDocRequest(
    val filename: String? = null,
    val scope: String? = null,
    val scenarioIds: List<String>? = null,
)

@Serializable
data class ScenariosPayload(
    val scenarios: List<ClientQuickAction> = emptyList(),
    val defaults: List<ClientQuickAction> = emptyList(),
    val customized: Boolean = false,
)

@Serializable
data class PutScenariosRequest(val scenarios: List<ClientQuickAction>)

@Serializable
data class SceneDraft(
    val id: String = "",
    val title: String,
    val subtitle: String? = null,
    val icon: String? = null,
    val opensAttachment: Boolean = false,
    val skillSlug: String? = null,
    val referenceDocIds: List<String> = emptyList(),
    val summaryPoints: List<String> = emptyList(),
    val prompt: String = "",
) {
    val resolvedId: String
        get() = id.trim().ifEmpty { "custom-${UUID.randomUUID().toString().take(8)}" }

    fun toQuickAction(): ClientQuickAction = ClientQuickAction(
        id = resolvedId,
        title = title.trim(),
        prompt = prompt.trim(),
        subtitle = subtitle?.trim()?.ifEmpty { null },
        icon = icon?.trim()?.ifEmpty { null },
        opensAttachment = opensAttachment,
        isCustom = true,
        hidden = false,
        skillSlug = skillSlug?.trim()?.ifEmpty { null },
        referenceDocIds = referenceDocIds.takeIf { it.isNotEmpty() },
        summaryPoints = summaryPoints.takeIf { it.isNotEmpty() },
    )
}

object SceneDraftParser {
    data class Extraction(val markdown: String, val drafts: List<SceneDraft>)

    private val fenceRegex = Regex("```qiqi-scene-draft\\s*\\n(.*?)\\n```", setOf(RegexOption.DOT_MATCHES_ALL))

    fun extract(text: String): Extraction {
        if (!text.contains("qiqi-scene-draft")) return Extraction(text, emptyList())
        val matches = fenceRegex.findAll(text).toList()
        if (matches.isEmpty()) return Extraction(text, emptyList())
        val drafts = mutableListOf<SceneDraft>()
        val cleaned = StringBuilder(text)
        for (match in matches.asReversed()) {
            val rawJson = match.groupValues[1].trim()
            val parsed = runCatching { HapiJson.decodeFromString<SceneDraft>(rawJson) }.getOrNull()
            if (parsed != null && parsed.title.isNotBlank()) {
                drafts.add(0, parsed)
                cleaned.replace(match.range.first, match.range.last + 1, "")
            }
        }
        val finalMd = cleaned.toString().replace(Regex("\n{3,}"), "\n\n").trim()
        return Extraction(finalMd, drafts)
    }
}
