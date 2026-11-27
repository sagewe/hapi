package app.hapi.protocol.wire

import app.hapi.protocol.chat.AgentEvent
import app.hapi.protocol.chat.NormalizedAgentContent
import app.hapi.protocol.chat.NormalizedMessage
import app.hapi.protocol.chat.normalizeDecryptedMessage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Verifies every Reins Native v1 wire payload emitted by
 * `reins-hub/src/v1` and `reins-core/src/events.rs`.
 */
class ReinsV1WireDecodingTest {

    @Test
    fun `v1 auth login response decodes without legacy user object`() {
        val resp = HapiJson.decodeFromString<AuthResponse>(
            """{"token":"jwt-v1","namespace":"compliance","is_owner":false}"""
        )
        assertEquals("jwt-v1", resp.token)
        assertEquals("compliance", resp.namespace)
        assertEquals(false, resp.isOwner)
        assertNull(resp.user)
    }

    @Test
    fun `v1 settings response decodes snake_case client_profile`() {
        val resp = HapiJson.decodeFromString<HubSettingsResponse>(
            """{"session_summary_contract":false,"client_profile":{"mode":"assistant","appTitle":"Reins"}}"""
        )
        assertEquals("assistant", resp.clientProfile?.mode)
        assertEquals("Reins", resp.clientProfile?.appTitle)
    }

    @Test
    fun `v1 machine decodes name platform capabilities and last_seen_at`() {
        val resp = HapiJson.decodeFromString<MachinesResponse>(
            """{"machines":[{"id":"m1","namespace":"default","name":"mac-studio","platform":"darwin","capabilities":["workspace","terminal"],"active":true,"last_seen_at":1700000000000}]}"""
        )
        val m = resp.machines.single()
        assertEquals("m1", m.id)
        assertEquals("mac-studio", m.metadata?.host)
        assertEquals("darwin", m.metadata?.platform)
        assertEquals(listOf("workspace", "terminal"), m.metadata?.capabilities)
        assertEquals(true, m.active)
        assertEquals(1700000000000L, m.activeAt)
        assertEquals("running", m.runnerState?.status)
    }

    @Test
    fun `v1 session decodes into both Session and SessionSummary`() {
        val raw = """{
            "id":"s1","namespace":"compliance","machine_id":"m1","agent":"claude",
            "directory":"/cases/c1","title":"Case Alpha","title_locked":true,
            "prompt_title":null,"model":"sonnet","effort":"high","permission_mode":"yolo",
            "status":"thinking","pinned":true,"pin_mode":"global","archived":false,
            "meta_rev":7,"state_rev":3,"message_epoch":2,"content_rev":12,
            "read_rev":10,"read_state_ver":4,"manual_unread":false,
            "pending_requests":{"requests":{"req-1":{"tool":"Bash","createdAt":1700000000500}}},
            "metadata":{"tags":["audit","urgent"],"host":"mac-studio"},
            "created_at":1700000000000,"updated_at":1700000001000,"seq":5,
            "message_count":4,"last_preview":"Checking files..."
        }"""
        val sess = HapiJson.decodeFromString<Session>(raw)
        assertEquals("s1", sess.id)
        assertTrue(sess.active)
        assertTrue(sess.thinking)
        assertEquals(true, sess.globalPinned)
        assertEquals(false, sess.pinned)
        assertEquals("Case Alpha", sess.metadata?.name)
        assertEquals("/cases/c1", sess.metadata?.path)
        assertEquals("claude", sess.metadata?.flavor)
        assertEquals(listOf("audit", "urgent"), sess.metadata?.tags)
        assertEquals(7L, sess.metadataVersion)
        assertEquals(3L, sess.agentStateVersion)
        assertEquals(12L, sess.contentRevision)
        assertEquals(10L, sess.readState?.readRevision)
        assertEquals(4L, sess.readState?.version)
        assertEquals("Bash", sess.agentState?.requests?.get("req-1")?.tool)
        assertTrue(sess.hasConversationContent)

        val list = HapiJson.decodeFromString<SessionsResponse>("""{"sessions":[$raw]}""")
        val summary = list.sessions.single()
        assertEquals("s1", summary.id)
        assertEquals(1, summary.pendingRequestsCount)
        assertEquals(listOf("permission"), summary.pendingRequestKinds)
        assertEquals("Case Alpha", summary.metadata?.name)
        assertEquals(true, summary.globalPinned)
    }

    @Test
    fun `v1 stored messages decode and normalize through chat pipeline`() {
        val raw = """{
            "messages":[
                {
                    "id":"m-user","session_id":"s1","seq":1,"local_id":"loc-1",
                    "role":"user","content_rev":1,"invoked_at":null,"delivery_state":"queued",
                    "blocks":[{"type":"text","text":"Hello Reins"}],
                    "meta":{},"created_at":1700000000000
                },
                {
                    "id":"m-asst","session_id":"s1","seq":2,"local_id":null,
                    "role":"assistant","content_rev":2,"invoked_at":1700000000100,"delivery_state":"invoked",
                    "blocks":[{"type":"text","text":"Hi there!"}],
                    "meta":{},"created_at":1700000000100
                },
                {
                    "id":"m-media","session_id":"s1","seq":3,"local_id":null,
                    "role":"assistant","content_rev":3,"invoked_at":1700000000200,"delivery_state":"invoked",
                    "blocks":[{"type":"generated_media","id":"img-1","filename":"chart.png","mime_type":"image/png"}],
                    "meta":{},"created_at":1700000000200
                }
            ],
            "page":{
                "read_through_revision":2,"content_revision":3,"direction":"latest",
                "limit":50,"epoch":1,"reset":false,"next_before_seq":1,"next_before_at":1700000000000,
                "snapshot_head_seq":3,"snapshot_head_at":1700000000200,"has_more":true
            }
        }"""
        val resp = HapiJson.decodeFromString<MessagesResponse>(raw)
        assertEquals(3, resp.messages.size)
        assertTrue(resp.page.hasMore)
        assertEquals(2L, resp.page.readThroughRevision)
        assertEquals(3L, resp.page.contentRevision)
        assertEquals(1L, resp.page.nextBeforeSeq)

        val userMsg = resp.messages[0]
        assertEquals("loc-1", userMsg.localId)
        assertEquals(OptionalField.Present(null), userMsg.invokedAt)
        val normUser = assertIs<NormalizedMessage.User>(normalizeDecryptedMessage(userMsg))
        assertEquals("Hello Reins", normUser.text)

        val asstMsg = resp.messages[1]
        val normAsst = assertIs<NormalizedMessage.Agent>(normalizeDecryptedMessage(asstMsg))
        val textContent = assertIs<NormalizedAgentContent.Text>(normAsst.content.single())
        assertEquals("Hi there!", textContent.text)
    }

    @Test
    fun `v1 flat read-state snapshot decodes into SessionReadStateResponse`() {
        val resp = HapiJson.decodeFromString<SessionReadStateResponse>(
            """{"contentRevision":15,"readRevision":14,"readStateVersion":7,"manualUnread":false}"""
        )
        assertEquals(15L, resp.contentRevision)
        assertEquals(14L, resp.readState.readRevision)
        assertEquals(7L, resp.readState.version)
        assertFalse(resp.readState.manualUnread)
    }

    @Test
    fun `v1 resume reopen and scratchlist entry decode native fields`() {
        val resume = HapiJson.decodeFromString<ResumeSessionResponse>(
            """{"ok":true,"session":{"id":"s-resumed"}}"""
        )
        assertEquals("s-resumed", resume.sessionId)

        val reopen = HapiJson.decodeFromString<ReopenSessionResponse>(
            """{"ok":true,"session":{"id":"s-reopened"}}"""
        )
        assertEquals("s-reopened", reopen.sessionId)
        assertTrue(reopen.resumed)

        val scratch = HapiJson.decodeFromString<ScratchlistEntriesResponse>(
            """{"entries":[{"id":"e-1","sessionId":"s1","text":"todo","attachments":[],"createdAt":10,"updatedAt":20}]}"""
        )
        assertEquals("e-1", scratch.entries.single().entryId)
    }

    @Test
    fun `v1 SSE events parse snake_case types and fields`() {
        val conn = assertIs<SyncEvent.ConnectionChanged>(
            SyncEvents.parse("""{"type":"connection_changed","data":{"status":"connected","subscription_id":"sub-1","resume":"ok"}}""")
        )
        assertEquals("sub-1", conn.data?.subscriptionId)
        assertEquals("ok", conn.data?.resume)

        val updated = assertIs<SyncEvent.SessionUpdated>(
            SyncEvents.parse("""{"type":"session_updated","namespace":"default","session_id":"s1","session":{"id":"s1","created_at":1,"updated_at":2}}""")
        )
        assertEquals("s1", updated.sessionId)
        assertNotNull(updated.data)

        val removed = assertIs<SyncEvent.SessionRemoved>(
            SyncEvents.parse("""{"type":"session_removed","namespace":"default","session_id":"s1"}""")
        )
        assertEquals("s1", removed.sessionId)

        val msg = assertIs<SyncEvent.MessageReceived>(
            SyncEvents.parse("""{"type":"message_received","namespace":"default","session_id":"s1","message":{"id":"m1","role":"user","blocks":[{"type":"text","text":"hi"}],"created_at":100}}""")
        )
        assertEquals("s1", msg.sessionId)
        assertEquals("m1", msg.message.id)

        val mach = assertIs<SyncEvent.MachineUpdated>(
            SyncEvents.parse("""{"type":"machine_updated","namespace":"default","machine_id":"m1","active":false,"updated_at":500,"machine":null}""")
        )
        assertEquals("m1", mach.machineId)
        assertIs<OptionalField.Present<*>>(mach.data)

        val toast = assertIs<SyncEvent.Toast>(
            SyncEvents.parse("""{"type":"toast","namespace":"default","data":{"title":"T","body":"B","session_id":"s1","url":"/s/s1"}}""")
        )
        assertEquals("s1", toast.data.sessionId)

        val consumed = assertIs<SyncEvent.MessagesConsumed>(
            SyncEvents.parse("""{"type":"messages_consumed","namespace":"default","session_id":"s1","local_ids":["l1"],"invoked_at":999}""")
        )
        assertEquals("s1", consumed.sessionId)
        assertEquals(listOf("l1"), consumed.localIds)
        assertEquals(999L, consumed.invokedAt)

        val indet = assertIs<SyncEvent.MessagesIndeterminate>(
            SyncEvents.parse("""{"type":"messages_indeterminate","session_id":"s1","local_ids":["l2"]}""")
        )
        assertEquals(listOf("l2"), indet.localIds)

        val requeued = assertIs<SyncEvent.MessagesRequeued>(
            SyncEvents.parse("""{"type":"messages_requeued","session_id":"s1","local_ids":["l3"]}""")
        )
        assertEquals(listOf("l3"), requeued.localIds)

        val cancelled = assertIs<SyncEvent.MessageCancelled>(
            SyncEvents.parse("""{"type":"message_cancelled","session_id":"s1","message_id":"m9","local_id":"l9"}""")
        )
        assertEquals("m9", cancelled.messageId)
        assertEquals("l9", cancelled.localId)
    }

    @Test
    fun `v1 multi-block generated_media, system role, user attachment previewUrl, and session modelReasoningEffort`() {
        val multi = HapiJson.decodeFromString<DecryptedMessage>(
            """{
                "id":"m-multi","session_id":"s1","seq":4,"role":"assistant","content_rev":4,
                "invoked_at":1700000000300,"delivery_state":"invoked",
                "blocks":[
                    {"type":"text","text":"Report ready:"},
                    {"type":"generated_media","id":"pdf-1","filename":"report.pdf","mime_type":"application/pdf"}
                ],
                "meta":{"model":"sonnet"},"created_at":1700000000300
            }"""
        )
        val normMulti = assertIs<NormalizedMessage.Agent>(normalizeDecryptedMessage(multi))
        assertEquals(2, normMulti.content.size)
        assertEquals("Report ready:", assertIs<NormalizedAgentContent.Text>(normMulti.content[0]).text)
        val genImg = assertIs<NormalizedAgentContent.GeneratedImage>(normMulti.content[1])
        assertEquals("pdf-1", genImg.imageId)
        assertEquals("report.pdf", genImg.fileName)
        assertEquals("application/pdf", genImg.mimeType)

        val sys = HapiJson.decodeFromString<DecryptedMessage>(
            """{"id":"m-sys","session_id":"s1","seq":5,"role":"system","blocks":[{"type":"text","text":"Session resumed"}],"created_at":1700000000400}"""
        )
        val normSys = assertIs<NormalizedMessage.Event>(normalizeDecryptedMessage(sys))
        assertEquals("Session resumed", assertIs<AgentEvent.Message>(normSys.event).message)

        val userAtt = HapiJson.decodeFromString<DecryptedMessage>(
            """{"id":"m-u","session_id":"s1","seq":6,"role":"user","blocks":[{"type":"text","text":"check"},{"type":"attachment","id":"a1","filename":"doc.pdf","mimeType":"application/pdf","size":123,"previewUrl":"/v1/sessions/s1/blobs/a1"}],"created_at":1700000000500}"""
        )
        val normUser = assertIs<NormalizedMessage.User>(normalizeDecryptedMessage(userAtt))
        assertEquals("/v1/sessions/s1/blobs/a1", normUser.attachments?.single()?.previewUrl)

        val sess = HapiJson.decodeFromString<Session>(
            """{"id":"s-codex","agent":"codex","effort":"high","created_at":1,"updated_at":2}"""
        )
        assertEquals("high", sess.effort)
        assertEquals("high", sess.modelReasoningEffort)
    }

    @Test
    fun `reins-v1 machines are exempt from legacy runner skew and snake_case ClientProfile and AndroidRelease defaults decode`() {
        val m = HapiJson.decodeFromString<Machine>(
            """{"id":"m-reins","namespace":"default","name":"studio","platform":"darwin","capabilities":{},"active":true,"last_seen_at":1}"""
        )
        assertFalse(RunnerSkew.isMachineSkewed(m.metadata))

        val settings = HapiJson.decodeFromString<HubSettingsResponse>(
            """{"client_profile":{"mode":"assistant","app_title":"Qiqi","default_agent":"agy","default_model":"m1","default_permission_mode":"yolo","default_directory":"/cases","hide_execution_details":true,"model_presets":[{"id":"p1","label":"Fast","model":"m1","is_default":true}],"quick_actions":[{"id":"q1","title":"Check","prompt":"Go"}]}}"""
        )
        val cp = assertNotNull(settings.clientProfile)
        assertEquals("Qiqi", cp.appTitle)
        assertEquals("/cases", cp.defaultDirectory)
        assertTrue(cp.hideExecutionDetails)
        assertTrue(cp.modelPresets.single().isDefault)

        val rel = HapiJson.decodeFromString<AndroidRelease>(
            """{"package_name":"com.sagewe.hapi.compliance","version_code":6,"version_name":"0.34.3","file_name":"QiqiWork-0.34.3-6.apk","sha256":"${"a".repeat(64)}","size":100,"download_path":"/v1/app-updates/android/download/QiqiWork-0.34.3-6.apk"}"""
        )
        assertEquals("", rel.releaseNotes)
        assertEquals("", rel.publishedAt)
    }
}
