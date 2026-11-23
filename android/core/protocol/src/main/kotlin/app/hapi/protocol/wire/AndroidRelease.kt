package app.hapi.protocol.wire
import kotlinx.serialization.Serializable
@Serializable data class AndroidRelease(
    val packageName: String, val versionCode: Int, val versionName: String,
    val fileName: String, val sha256: String, val size: Long,
    val releaseNotes: String, val publishedAt: String, val downloadPath: String,
)
