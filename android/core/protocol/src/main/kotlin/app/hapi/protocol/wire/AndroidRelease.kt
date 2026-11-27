package app.hapi.protocol.wire
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNames
@OptIn(ExperimentalSerializationApi::class)
@Serializable data class AndroidRelease(
    @JsonNames("package_name") val packageName: String,
    @JsonNames("version_code") val versionCode: Int,
    @JsonNames("version_name") val versionName: String,
    @JsonNames("file_name") val fileName: String,
    val sha256: String,
    val size: Long,
    @JsonNames("release_notes") val releaseNotes: String = "",
    @JsonNames("published_at") val publishedAt: String = "",
    @JsonNames("download_path") val downloadPath: String,
)
