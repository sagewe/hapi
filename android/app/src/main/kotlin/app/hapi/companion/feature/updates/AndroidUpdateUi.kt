package app.hapi.companion.feature.updates

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import app.hapi.companion.BuildConfig
import app.hapi.companion.di.HubGraph
import app.hapi.companion.feature.assistant.AssistantNavigation
import kotlinx.coroutines.launch

class UpdateFileProvider : FileProvider()

@Composable fun AndroidUpdateHint(hub: HubGraph) {
    val updater = hub.androidUpdates ?: return
    val state by updater.state.collectAsState()
    val navigation = AssistantNavigation.current
    if(state.available) TextButton(navigation.settings) { Text("有新版本 · ${state.release?.versionName} (${state.release?.versionCode})") }
}

@Composable fun AndroidUpdateSection(hub: HubGraph) {
    val updater = hub.androidUpdates ?: return
    val state by updater.state.collectAsState()
    var expanded by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var needsPermission by remember { mutableStateOf(false) }
    var installRequested by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    fun install() { scope.launch {
        try {
            val file = updater.verifiedForInstall()
            val flags = if(android.os.Build.VERSION.SDK_INT >= 28) android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES else android.content.pm.PackageManager.GET_SIGNATURES
            val archive = requireNotNull(context.packageManager.getPackageArchiveInfo(file.absolutePath,flags))
            check(archive.packageName == BuildConfig.APPLICATION_ID && androidx.core.content.pm.PackageInfoCompat.getLongVersionCode(archive) == state.release?.versionCode?.toLong())
            val installed = context.packageManager.getPackageInfo(context.packageName,flags)
            @Suppress("DEPRECATION")
            fun signatures(info: android.content.pm.PackageInfo): Set<String> =
                (if(android.os.Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures).orEmpty().map { it.toCharsString() }.toSet()
            check(signatures(archive).isNotEmpty() && signatures(archive) == signatures(installed))
            val uri = FileProvider.getUriForFile(context,"${context.packageName}.updates",file)
            context.startActivity(Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri,"application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = android.content.ClipData.newRawUri("琪琪工作更新",uri)
            })
        } catch (_: Exception) { updater.invalidateDownload(); error = "无法安装更新，请重新下载后重试" }
    } }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        if(context.packageManager.canRequestPackageInstalls()) install() else needsPermission = true
    }
    LaunchedEffect(state.file, state.downloading) {
        if(installRequested && !state.downloading) {
            installRequested = false
            if(state.file != null) {
                if(context.packageManager.canRequestPackageInstalls()) install() else needsPermission = true
            }
        }
    }
    Column(Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
        TextButton({ expanded = !expanded; if(expanded) updater.check(manual = true) }) { Text("检查更新 · ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})") }
        if(expanded) {
            Text(if(state.checking) "正在检查更新…" else state.status, Modifier.padding(horizontal = 12.dp))
            state.release?.let { release ->
                if(release.releaseNotes.isNotBlank()) Text(release.releaseNotes, Modifier.padding(12.dp), style = MaterialTheme.typography.bodyMedium)
            }
            if(state.downloading) {
                val fraction = (state.bytes.toFloat() / (state.release?.size ?: 1)).coerceIn(0f,1f)
                LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth().padding(12.dp))
                Text("已下载 ${(fraction * 100).toInt()}%",Modifier.padding(horizontal = 12.dp))
            }
            if(state.available && !state.downloading) Button({
                if(state.file != null) { if(context.packageManager.canRequestPackageInstalls()) install() else needsPermission = true }
                else { installRequested = true; updater.download() }
            }, Modifier.padding(12.dp)) { Text(if(state.file == null) "下载并安装" else "安装已校验更新") }
        }
    }
    if(needsPermission) AlertDialog(onDismissRequest = { needsPermission = false }, title = { Text("允许安装琪琪工作更新") }, text = { Text("请在系统页面开启“允许来自此来源的应用”。返回后将打开已通过 SHA-256 校验的更新安装器。") }, confirmButton = { TextButton({
        needsPermission = false
        try { permission.launch(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))) }
        catch (_: Exception) { error = "无法打开安装权限设置，请在系统设置中允许本应用安装更新" }
    }) { Text("前往设置") } }, dismissButton = { TextButton({ needsPermission = false }) { Text("稍后") } })
    error?.let { AlertDialog(onDismissRequest = { error = null }, text = { Text(it) }, confirmButton = { TextButton({ error = null }) { Text("好") } }) }
}
