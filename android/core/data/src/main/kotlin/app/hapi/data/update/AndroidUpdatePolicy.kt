package app.hapi.data.update
import app.hapi.protocol.wire.AndroidRelease
import java.io.File
import java.security.MessageDigest
object AndroidUpdatePolicy {
    const val MAX_BYTES = 500L * 1024 * 1024
    fun validFilename(name: String) = name.length <= 160 && !name.contains("..") && Regex("[A-Za-z0-9][A-Za-z0-9._-]*\\.apk").matches(name)
    fun validate(release: AndroidRelease) {
        require(validFilename(release.fileName)) { "更新文件名无效" }
        require(release.downloadPath == "/v1/app-updates/android/download/${release.fileName}") { "更新下载路径无效" }
        require(release.size in 1..MAX_BYTES && release.versionCode > 0) { "更新信息无效" }
        require(Regex("[a-f0-9]{64}").matches(release.sha256)) { "更新校验信息无效" }
    }
    fun isNewer(release: AndroidRelease, packageName: String, versionCode: Int): Boolean {
        validate(release)
        return release.packageName == packageName && release.versionCode > versionCode
    }
    /** Invalid files are removed before an installer can receive their URI. */
    fun verify(file: File, release: AndroidRelease) {
        try {
            validate(release)
            require(file.length() == release.size) { "更新文件大小不匹配" }
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input -> val buffer = ByteArray(65536); while(true) { val n = input.read(buffer); if(n < 0) break; digest.update(buffer,0,n) } }
            val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            require(actual == release.sha256) { "SHA-256 校验失败，请重新下载" }
        } catch(e: Exception) { file.delete(); throw e }
    }
}
