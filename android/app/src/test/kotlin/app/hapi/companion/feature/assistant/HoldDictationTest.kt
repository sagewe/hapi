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
}
