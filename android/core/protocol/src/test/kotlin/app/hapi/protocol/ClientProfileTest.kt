package app.hapi.protocol
import app.hapi.protocol.wire.*
import kotlin.test.*
class ClientProfileTest {
    @Test fun absentProfileKeepsDeveloperMode() {
        assertNull(HapiJson.decodeFromString<HubSettingsResponse>("{}").clientProfile)
        assertEquals("developer", HapiJson.decodeFromString<ClientProfile>("{}").mode)
    }
    @Test fun forwardFieldsDoNotBreakProfile() {
        val settings = HapiJson.decodeFromString<HubSettingsResponse>("""{"future":true,"clientProfile":{"mode":"assistant","future":1}}""")
        assertEquals("assistant", settings.clientProfile?.mode)
    }
}
