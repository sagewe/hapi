package app.hapi.companion.feature.assistant
import org.junit.Test
import org.junit.Assert.*
import java.nio.ByteBuffer
import java.nio.ByteOrder
class HoldDictationTest {
    @Test fun frames() {
        assertEquals(AsrFrame("partial","核查企业"),decodeAsrFrame("""{"type":"partial","text":"核查企业"}"""))
        assertEquals(AsrFrame("final","完整文字"),decodeAsrFrame("""{"type":"final","text":"完整文字","unknown":1}"""))
        assertEquals(AsrFrame("error",null),decodeAsrFrame("""{"type":"error"}"""))
        assertNull(decodeAsrFrame("broken"));assertNull(decodeAsrFrame("{}"))
    }
    @Test fun releaseNeverSendsShortOrCancelledTakes() {
        assertFalse(keepHold(349,false));assertFalse(keepHold(10000,true));assertTrue(keepHold(350,false))
    }
    @Test fun fallbackIsValidMono16kWave() {
        val pcm=byteArrayOf(1,2,3,4);val wave=pcmWave(pcm)
        assertEquals("RIFF",String(wave,0,4));assertEquals("WAVE",String(wave,8,4));assertEquals(48,wave.size)
        val b=ByteBuffer.wrap(wave).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(16000,b.getInt(24));assertEquals(32000,b.getInt(28));assertEquals(4,b.getInt(40));assertArrayEquals(pcm,wave.copyOfRange(44,48))
    }
    @Test fun holdVoiceZonesMatchMyDotsGeometry() {
        assertEquals(HoldVoiceZone.SEND, resolveHoldVoiceZone(0f, 0f))
        assertEquals(HoldVoiceZone.SEND, resolveHoldVoiceZone(12f, -15f))
        assertEquals(HoldVoiceZone.CANCEL, resolveHoldVoiceZone(-30f, -50f))
        assertEquals(HoldVoiceZone.CANCEL, resolveHoldVoiceZone(0f, -84f))
        assertEquals(HoldVoiceZone.EDIT, resolveHoldVoiceZone(42f, -32f))
    }
    @Test fun assistantVisibleUserTextStripsHiddenInstructions() {
        val scene = defaultAssistantScenes[0].copy(prompt = "check registry")
        val wire = scene.buildMessage("查一下某某公司")
        assertTrue(wire.contains("<investigation-instructions>"))
        assertEquals("【调查场景：企业股权穿透】\n\n查一下某某公司", assistantVisibleUserText(wire))
        assertEquals("普通消息", assistantVisibleUserText("普通消息"))
    }
    @Test fun assistantGreetingCoversAllTimeBuckets() {
        assertEquals("早上好", assistantGreeting(8))
        assertEquals("中午好", assistantGreeting(12))
        assertEquals("下午好", assistantGreeting(15))
        assertEquals("晚上好", assistantGreeting(20))
        assertEquals("夜深了", assistantGreeting(2))
    }
}
