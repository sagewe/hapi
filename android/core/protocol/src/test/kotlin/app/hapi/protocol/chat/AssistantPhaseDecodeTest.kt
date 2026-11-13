package app.hapi.protocol.chat

import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Test

class AssistantPhaseDecodeTest {
    @Test fun `preserves explicit common phases with missing or null envelope metadata`() {
        for (phase in listOf("progress", "final")) {
            val record = buildJsonObject {
                put("type", "codex")
                put("data", buildJsonObject { put("type", "message"); put("message", "answer"); put("phase", phase) })
            }
            for (meta in listOf(null, JsonNull)) {
                val normalized = assertIs<NormalizedMessage.Agent>(normalizeAgentRecord("phase", null, 1, record, meta))
                assertEquals(JsonPrimitive(phase), (normalized.meta as? JsonObject)?.get("assistantPhase"))
            }
        }
    }
}
