package app.hapi.companion.feature.updates

import app.hapi.companion.BuildConfig
import app.hapi.data.api.ApiError
import app.hapi.data.api.HapiApi
import app.hapi.data.update.AndroidUpdatePolicy
import app.hapi.protocol.wire.AndroidRelease
import java.io.File
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

data class AndroidUpdateState(
    val release: AndroidRelease? = null, val available: Boolean = false,
    val checking: Boolean = false, val downloading: Boolean = false,
    val bytes: Long = 0, val file: File? = null, val status: String = "尚未检查更新",
)
/** One controller per paired hub; private download folders never cross hub identities. */
class AndroidUpdateController(private val api: HapiApi, private val directory: File, private val scope: CoroutineScope) {
    private val mutable = MutableStateFlow(AndroidUpdateState())
    val state = mutable.asStateFlow()
    private var checkJob: Job? = null
    private var lastCheck = 0L
    fun check(manual: Boolean = false) {
        if (!BuildConfig.COMPLIANCE || checkJob?.isActive == true || mutable.value.downloading) return
        if(!manual && System.currentTimeMillis() - lastCheck < 15000) return
        lastCheck = System.currentTimeMillis()
        checkJob = scope.launch {
            mutable.update { it.copy(checking = true) }
            try {
                val release = api.getAndroidRelease()
                val newer = AndroidUpdatePolicy.isNewer(release, BuildConfig.APPLICATION_ID, BuildConfig.VERSION_CODE)
                require(release.packageName == BuildConfig.APPLICATION_ID) { "更新不适用于本应用" }
                if(!newer) withContext(Dispatchers.IO) { directory.listFiles()?.forEach { it.delete() } }
                mutable.update { old -> old.copy(release = release, available = newer,
                    file = old.file.takeIf { old.release?.sha256 == release.sha256 },
                    status = if(newer) "发现新版本 ${release.versionName} (${release.versionCode})" else "已是最新版本") }
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) { mutable.update { it.copy(release = null, available = false, file = null, status = if(e is ApiError && e.status == 404) "暂无可用更新" else "暂时无法检查更新，请重试") } }
            finally { mutable.update { it.copy(checking = false) } }
        }
    }
    fun download() {
        val release = mutable.value.release ?: return
        if(!mutable.value.available || mutable.value.downloading) return
        mutable.update { it.copy(downloading = true, bytes = 0, file = null, status = "正在下载…") }
        scope.launch {
            try {
                val file = withContext(Dispatchers.IO) {
                    directory.mkdirs()
                    directory.listFiles()?.forEach { it.delete() }
                    File(directory,release.fileName)
                }
                api.downloadAndroidRelease(release,file) { count -> mutable.update { it.copy(bytes = count) } }
                mutable.update { it.copy(file = file, status = "SHA-256 校验通过，可安装") }
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) { mutable.update { it.copy(file = null, status = "下载或 SHA-256 校验失败，请重试") } }
            finally { mutable.update { it.copy(downloading = false) } }
        }
    }
    fun invalidateDownload() { mutable.update { it.copy(file = null, status = "更新文件不可用，请重新下载") } }
    suspend fun verifiedForInstall(): File {
        val current = mutable.value
        val release = requireNotNull(current.release)
        check(AndroidUpdatePolicy.isNewer(release,BuildConfig.APPLICATION_ID,BuildConfig.VERSION_CODE))
        val file = requireNotNull(current.file)
        // Recheck after returning from Android's unknown-sources permission page.
        withContext(Dispatchers.IO) { AndroidUpdatePolicy.verify(file,release) }
        return file
    }
}
