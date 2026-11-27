package app.hapi.companion.feature.assistant

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import app.hapi.data.api.HapiApi
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import okhttp3.*
import okio.ByteString.Companion.toByteString
import kotlinx.serialization.json.*
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal data class HoldVoiceState(val active: Boolean=false, val finishing: Boolean=false, val text: String="", val level: Float=0f)
internal data class AsrFrame(val type: String,val text: String?)
internal fun decodeAsrFrame(raw: String): AsrFrame? = runCatching {
    val obj=Json.parseToJsonElement(raw).jsonObject
    AsrFrame(obj["type"]!!.jsonPrimitive.content,obj["text"]?.jsonPrimitive?.contentOrNull)
}.getOrNull()
internal fun keepHold(durationMs: Long, cancelled: Boolean) = durationMs >= 350 && !cancelled
internal fun pcmWave(pcm: ByteArray): ByteArray = ByteBuffer.allocate(44+pcm.size).order(ByteOrder.LITTLE_ENDIAN).apply {
    put("RIFF".toByteArray());putInt(36+pcm.size);put("WAVEfmt ".toByteArray());putInt(16);putShort(1);putShort(1);putInt(16000);putInt(32000);putShort(2);putShort(16);put("data".toByteArray());putInt(pcm.size);put(pcm)
}.array()

internal interface HoldPcmInput {
    fun startRecording()
    fun read(bytes: ByteArray,offset: Int,length: Int): Int
    fun stop()
    fun release()
}
private class AndroidHoldPcmInput : HoldPcmInput {
    @SuppressLint("MissingPermission")
    private val mic=AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION,16000,AudioFormat.CHANNEL_IN_MONO,AudioFormat.ENCODING_PCM_16BIT,maxOf(AudioRecord.getMinBufferSize(16000,AudioFormat.CHANNEL_IN_MONO,AudioFormat.ENCODING_PCM_16BIT),6400))
    override fun startRecording() { check(mic.state==AudioRecord.STATE_INITIALIZED);mic.startRecording() }
    override fun read(bytes: ByteArray,offset: Int,length: Int)=mic.read(bytes,offset,length)
    override fun stop()=mic.stop()
    override fun release()=mic.release()
}

/** One take owns its recorder, socket and bounded PCM buffer; cancellation invalidates all callbacks. */
internal class HoldDictation(private val api: HapiApi,private val scope: CoroutineScope,private val result: (String)->Unit,private val error: (String)->Unit,private val inputFactory: ()->HoldPcmInput = { AndroidHoldPcmInput() }) {
    val state=MutableStateFlow(HoldVoiceState())
    private var take: Job?=null
    @Volatile private var socket: WebSocket?=null
    @Volatile private var record: HoldPcmInput?=null
    @Volatile private var generation=0
    private var started=0L
    private var capture: Job?=null
    private var pcm=ByteArrayOutputStream()
    private var final=CompletableDeferred<String?>()
    @Volatile private var ready=false
    @Volatile private var failed=false
    @Volatile private var recording=false

    @SuppressLint("MissingPermission")
    fun start(draft: String) {
        if(state.value.active || state.value.finishing) return
        val token=++generation
        started=System.currentTimeMillis();pcm=ByteArrayOutputStream();final=CompletableDeferred();ready=false;failed=false;recording=true
        state.value=HoldVoiceState(active=true)
        take=scope.launch {
            try {
                capture=launch(Dispatchers.IO) {
                    val mic=inputFactory()
                    record=mic
                    try {
                        mic.startRecording()
                        val bytes=ByteArray(1600)
                        while(recording && token==generation && pcm.size()<5_760_000) {
                            val n=mic.read(bytes,0,bytes.size)
                            check(n>0) { "麦克风读取失败" }
                            synchronized(this@HoldDictation) { if(token==generation) { pcm.write(bytes,0,n);if(ready && !failed) socket?.send(bytes.toByteString(0,n)) } }
                            var peak=0
                            for(i in 0 until n-1 step 2) peak=maxOf(peak,kotlin.math.abs(((bytes[i].toInt() and 255) or (bytes[i+1].toInt() shl 8)).toShort().toInt()))
                            if(token==generation) state.value=state.value.copy(level=(peak/12000f).coerceIn(.08f,1f))
                        }
                    } finally { runCatching { mic.stop() };mic.release();if(record===mic) record=null }
                    if(recording && token==generation) withContext(Dispatchers.Main) { finish(false) }
                }
                val recordingId=java.util.UUID.randomUUID().toString()
                api.prepareStreamingAsr(draft,recordingId)
                if(token!=generation || !recording) return@launch
                socket=api.openStreamingAsr(draft,object: WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket,response: Response) {
                        synchronized(this@HoldDictation) {
                            if(token!=generation) { webSocket.cancel();return }
                            ready=true
                            val pending=pcm.toByteArray();if(pending.isNotEmpty()) webSocket.send(pending.toByteString())
                        }
                    }
                    override fun onMessage(webSocket: WebSocket,text: String) {
                        if(token!=generation) return
                        val frame=decodeAsrFrame(text) ?: return
                        when(frame.type) {
                            "partial" -> state.value=state.value.copy(text=frame.text.orEmpty())
                            "final" -> final.complete(frame.text)
                            "error" -> {failed=true;final.complete(null)}
                        }
                    }
                    override fun onFailure(webSocket: WebSocket,t: Throwable,response: Response?) { if(token==generation) { failed=true;final.complete(null) } }
                    override fun onClosed(webSocket: WebSocket,code: Int,reason: String) { if(token==generation) final.complete(null) }
                },recordingId=recordingId)

            } catch(e: Exception) { if(e is CancellationException) throw e;if(token==generation) { this@HoldDictation.cancel();error("无法开始录音，请使用语音听写重试") } }
        }
    }
    fun finish(cancelled: Boolean) {
        if(!state.value.active) return
        if(!keepHold(System.currentTimeMillis()-started,cancelled)) { cancel();return }
        recording=false
        state.value=state.value.copy(active=false,finishing=true)
        scope.launch {
            val token=generation
            try {
                capture?.join()
                socket?.send("{\"type\":\"finish\"}")
                val transcript=if(failed) null else withTimeoutOrNull(12000) { final.await() }
                val text=transcript?.takeIf { it.isNotBlank() } ?: run {
                    val bytes=synchronized(this@HoldDictation) { pcm.toByteArray() }
                    check(bytes.isNotEmpty()) { "录音太短，请重试" }
                    val provider=api.getTranscriptionProviders().providers.firstOrNull { "standard" in it.modes } ?: kotlin.error("暂时无法转写，请重试")
                    api.transcribeVoice(pcmWave(bytes),"speech.wav","audio/wav",provider.id,mode="standard",language=null).text
                }
                if(token==generation && text.isNotBlank()) result(text)
            } catch(e: Exception) { if(e is CancellationException) throw e;if(token==generation) error("转写未完成，请重试") }
            finally { if(token==generation) this@HoldDictation.cancel() }
        }
    }
    fun cancel() { generation++;recording=false;take?.cancel();socket?.cancel();socket=null;runCatching { record?.stop() };state.value=HoldVoiceState() }
}
