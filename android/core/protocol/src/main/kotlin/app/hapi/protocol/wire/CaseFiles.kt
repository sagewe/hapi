package app.hapi.protocol.wire
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNames
@Serializable data class CaseFilesResponse(val files: List<CaseFile> = emptyList())
@OptIn(ExperimentalSerializationApi::class)
@Serializable data class CaseFile(
    val id: String,
    val category: String,
    @JsonNames("filename") val fileName: String,
    @JsonNames("mime_type") val mimeType: String,
    val size: Long,
    @JsonNames("created_at") val createdAt: Double,
    @JsonNames("download_path") val downloadPath: String = "",
) {
    val key: String get() = "$category:$id"
    val isImage: Boolean get() = mimeType.startsWith("image/")
    val isZip: Boolean get() = fileName.endsWith(".zip", true)
    val isPdf: Boolean get() = fileName.endsWith(".pdf", true)
    val isUpload: Boolean get() = category == "uploads"
}
