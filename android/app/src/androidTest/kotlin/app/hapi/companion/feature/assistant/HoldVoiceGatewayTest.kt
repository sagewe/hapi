package app.hapi.companion.feature.assistant

import androidx.compose.material3.Surface
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.runtime.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import app.hapi.companion.ui.theme.HapiTheme
import app.hapi.data.api.HapiApi
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.atomic.AtomicReference

/** Opt-in live gateway acceptance. Uses synthetic PCM because headless hosts may lack an input device.
 * Arguments: asrHub, asrJwt, pcmPath. No credentials or user recordings are stored in the source tree. */
class HoldVoiceGatewayTest {
    @get:Rule val compose=createComposeRule()
    @Test fun livePartialsDraftAndCancel() {
        val args=InstrumentationRegistry.getArguments()
        assumeTrue(args.containsKey("asrHub"))
        val api=HapiApi(args.getString("asrHub")!!,OkHttpClient.Builder().addInterceptor { chain -> chain.proceed(chain.request().newBuilder().header("Authorization","Bearer "+args.getString("asrJwt")).build()) }.build())
        val pcm=File(args.getString("pcmPath")!!).readBytes().drop(44).toByteArray()
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main)
        val result=AtomicReference<String?>(null);val failure=AtomicReference<String?>(null)
        val controller=HoldDictation(api,scope,{result.set(it)},{failure.set(it)},{object: HoldPcmInput {
            var offset=0
            override fun startRecording() { offset=0 }
            override fun read(bytes: ByteArray,start: Int,length: Int): Int {
                Thread.sleep(50);val n=minOf(length,pcm.size-offset)
                if(n>0) { pcm.copyInto(bytes,start,offset,offset+n);offset+=n } else bytes.fill(0)
                return if(n>0) n else length
            }
            override fun stop() {}
            override fun release() {}
        }})
        val export=InstrumentationRegistry.getInstrumentation().targetContext.filesDir
        var cancel by mutableStateOf(false)
        compose.setContent { HapiTheme { Surface(modifier=Modifier.fillMaxSize()) { val state by controller.state.collectAsState();HoldVoiceOverlay(state,cancel) } } }
        compose.waitForIdle()
        fun shot(name: String) {
            compose.waitForIdle()
            Thread.sleep(600) // Wait for the Popup surface to reach the emulator framebuffer.
            val bitmap=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
            File(export,"$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) }
        }
        try {
            InstrumentationRegistry.getInstrumentation().runOnMainSync { controller.start("合成验收，不发送查询") }
            val deadline=System.currentTimeMillis()+18000
            while(controller.state.value.text.isBlank() && failure.get()==null && System.currentTimeMillis()<deadline) Thread.sleep(100)
            assertNull(failure.get());assertTrue(controller.state.value.text.isNotBlank());Thread.sleep(500);shot("voice-partial-gateway")
            InstrumentationRegistry.getInstrumentation().runOnMainSync { controller.finish(false) }
            val finish=System.currentTimeMillis()+40000
            while(result.get()==null && failure.get()==null && System.currentTimeMillis()<finish) Thread.sleep(100)
            assertNull(failure.get());assertTrue(!result.get().isNullOrBlank())
            File(export,"voice-result.txt").writeText(result.get()!!)
            result.set(null)
            InstrumentationRegistry.getInstrumentation().runOnMainSync { controller.start("取消验收") }
            Thread.sleep(1800)
            InstrumentationRegistry.getInstrumentation().runOnMainSync { cancel=true }
            Thread.sleep(400);shot("voice-cancel-gateway")
            InstrumentationRegistry.getInstrumentation().runOnMainSync { controller.finish(true) }
            Thread.sleep(1000);assertNull(result.get());assertFalse(controller.state.value.active);assertFalse(controller.state.value.finishing)
        } finally { InstrumentationRegistry.getInstrumentation().runOnMainSync { controller.cancel() };scope.cancel() }
    }
}
