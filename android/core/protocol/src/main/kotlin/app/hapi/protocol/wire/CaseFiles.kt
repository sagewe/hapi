package app.hapi.protocol.wire
import kotlinx.serialization.Serializable
@Serializable data class CaseFilesResponse(val files: List<CaseFile> = emptyList())
@Serializable data class CaseFile(val id: String, val category: String, val fileName: String, val mimeType: String, val size: Long, val createdAt: Double, val downloadPath: String = "") {
    val key: String get() = "$category:$id"
    val isImage: Boolean get() = mimeType.startsWith("image/")
    val isZip: Boolean get() = fileName.endsWith(".zip", true)
    val isPdf: Boolean get() = fileName.endsWith(".pdf", true)
    val isUpload: Boolean get() = category == "uploads"
}
