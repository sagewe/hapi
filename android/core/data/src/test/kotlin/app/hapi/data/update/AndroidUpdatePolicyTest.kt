package app.hapi.data.update
import app.hapi.protocol.wire.AndroidRelease
import java.nio.file.Files
import java.security.MessageDigest
import kotlin.test.*
class AndroidUpdatePolicyTest {
    private fun release() = AndroidRelease("com.sagewe.hapi.compliance",2,"0.34.3","QiqiWork-2.apk",MessageDigest.getInstance("SHA-256").digest("apk".toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) },3,"notes","2026-11-23T00:00:00Z","/v1/app-updates/android/download/QiqiWork-2.apk")
    @Test fun versionAndPackageMustBothMatch() {
        assertTrue(AndroidUpdatePolicy.isNewer(release(),release().packageName,1))
        assertFalse(AndroidUpdatePolicy.isNewer(release(),release().packageName,2))
        assertFalse(AndroidUpdatePolicy.isNewer(release(),release().packageName,3))
        assertFalse(AndroidUpdatePolicy.isNewer(release(),"run.hapi.companion",1))
    }
    @Test fun pathsCannotEscapeAuthenticatedDownloadEndpoint() {
        listOf("../x.apk","a..apk","x/y.apk","x\\y.apk","a.zip","a.apk.exe").forEach { assertFalse(AndroidUpdatePolicy.validFilename(it)) }
        assertFailsWith<IllegalArgumentException> { AndroidUpdatePolicy.validate(release().copy(downloadPath="https://other.example/app.apk")) }
    }
    @Test fun verifiedBytesAreRetainedAndCorruptionDeleted() {
        val file = Files.createTempFile("android-update-test", ".apk").toFile()
        try {
            file.writeText("apk"); AndroidUpdatePolicy.verify(file,release()); assertTrue(file.exists())
            file.writeText("bad"); assertFailsWith<IllegalArgumentException> { AndroidUpdatePolicy.verify(file,release()) }; assertFalse(file.exists())
            file.writeText("shorter"); assertFailsWith<IllegalArgumentException> { AndroidUpdatePolicy.verify(file,release()) }; assertFalse(file.exists())
        } finally { file.delete() }
    }
}
