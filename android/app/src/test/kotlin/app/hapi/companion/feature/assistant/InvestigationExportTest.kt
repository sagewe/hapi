package app.hapi.companion.feature.assistant
import app.hapi.protocol.wire.*
import kotlin.test.*
class InvestigationExportTest {
    @Test fun exportsConclusionsAndSourcesButNeverToolPayloads() {
        val messages=listOf(
            DecryptedMessage("u",createdAt=1,content=HapiJson.parseToJsonElement("""{"role":"user","content":{"type":"text","text":"核查某企业"}}""")),
            DecryptedMessage("a",createdAt=2,content=HapiJson.parseToJsonElement("""{"role":"agent","content":{"type":"codex","data":{"type":"message","message":"结论：须补充注册证明。\n来源：https://example.org/registry"}}}""")),
            DecryptedMessage("t",createdAt=3,content=HapiJson.parseToJsonElement("""{"role":"agent","content":{"type":"codex","data":{"type":"tool-call","name":"Bash","callId":"tool","input":{"command":"PRIVATE_TOOL_JSON"}}}}""")))
        val result=investigationExport("企业核验",messages)
        assertTrue(result.startsWith("# 企业核验"))
        assertTrue(result.contains("结论：须补充注册证明。"))
        assertTrue(result.contains("https://example.org/registry"))
        assertFalse(result.contains("PRIVATE_TOOL_JSON"));assertFalse(result.contains("tool-call"))
    }
    @Test fun titleCannotEscapeExportDirectory() { assertEquals("企业_核验.md",investigationFilename("企业/核验"));assertEquals("调查记录.md",investigationFilename("..")) }
}
