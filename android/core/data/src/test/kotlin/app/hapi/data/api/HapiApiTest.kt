package app.hapi.data.api

import app.hapi.data.HubSession
import app.hapi.data.auth.HubCredentials
import app.hapi.data.auth.InMemoryCredentialStore
import app.hapi.data.fakeJwt
import app.hapi.protocol.wire.ApprovePermissionRequest
import app.hapi.protocol.wire.SendMessageRequest
import app.hapi.protocol.wire.SpawnSessionRequest
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer

/** Request/response shapes of [HapiApi] against MockWebServer. */
class HapiApiTest {

    private lateinit var server: MockWebServer
    private lateinit var session: HubSession
    private val jwt = fakeJwt(expSeconds = 4_000_000_000)

    @BeforeTest
    fun setUp() {
        server = MockWebServer()
        server.start()
        val hubUrl = server.url("/").toString().removeSuffix("/")
        val store = InMemoryCredentialStore()
        store.set(HubCredentials(hubUrl = hubUrl, accessToken = "token", jwt = jwt))
        session = HubSession(server.url("/"), store)
    }

    @AfterTest
    fun tearDown() {
        session.close()
        server.shutdown()
    }

    private fun ok(body: String) = MockResponse()
        .setHeader("Content-Type", "application/json")
        .setBody(body)

    private fun lastRequestBody() = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject

    @Test
    fun `ASR discovery context and websocket remain authenticated and same origin`() = runBlocking {
        server.enqueue(ok("""{"available":true,"ws_url":"wss://evil.example"}"""))
        assertEquals(true,session.api.streamingAsrAvailable())
        val config=server.takeRequest();assertEquals("/v1/voice/asr-config",config.path);assertEquals("Bearer $jwt",config.getHeader("Authorization"))
        server.enqueue(ok("""{"ok":true}"""))
        session.api.prepareStreamingAsr("核验企业","take-1")
        val context=server.takeRequest();assertEquals("/v1/voice/asr-context",context.path);assertEquals("Bearer $jwt",context.getHeader("Authorization"));assertTrue(context.body.readUtf8().contains("核验企业"))
        val done=java.util.concurrent.CountDownLatch(1)
        server.enqueue(MockResponse().withWebSocketUpgrade(object: okhttp3.WebSocketListener() {
            override fun onOpen(ws: okhttp3.WebSocket,response: okhttp3.Response) { ws.send("""{"type":"partial","text":"企业"}""");ws.send("""{"type":"final","text":"核验企业"}""") }
        }))
        val frames=java.util.Collections.synchronizedList(mutableListOf<String>())
        val socket=session.api.openStreamingAsr("中文草稿",object: okhttp3.WebSocketListener() {
            override fun onMessage(ws: okhttp3.WebSocket,text: String) { frames.add(text);if(frames.size==2) done.countDown() }
        }, recordingId = "take-1")
        assertTrue(done.await(5,java.util.concurrent.TimeUnit.SECONDS))
        val upgrade=server.takeRequest();assertEquals("/v1/voice/asr-ws?sample_rate=16000&recording_id=take-1",upgrade.path);assertEquals("Bearer $jwt",upgrade.getHeader("Authorization"));assertEquals("中文草稿",String(java.util.Base64.getDecoder().decode(upgrade.getHeader("X-ASR-Draft"))))
        assertEquals(2,frames.size);socket.cancel()
    }

    @Test
    fun `getMessageContext returns null on 404`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(404).setBody("""{"error":"not_found"}"""))
        assertNull(session.api.getMessageContext("s1", "missing-msg"))
    }

    @Test
    fun `case index and uploads stay authenticated on this origin`() = runBlocking {
        server.enqueue(ok("""{"files":[{"id":"f","category":"uploads","filename":"单据.zip","mime_type":"application/zip","size":3,"created_at":1,"download_path":"https://evil.example/steal"}]}"""))
        val file=session.api.getCaseFiles("case1").files.single()
        val index=server.takeRequest(); assertEquals("/v1/sessions/case1/case-files",index.path); assertEquals("Bearer $jwt",index.getHeader("Authorization"))
        server.enqueue(MockResponse().setBody("zip").setHeader("Content-Type","application/zip"))
        assertEquals("zip",session.api.getCaseFile("case1",file).bytes.toString(Charsets.UTF_8))
        val download=server.takeRequest(); assertEquals("/v1/sessions/case1/blobs/f",download.path);assertEquals("Bearer $jwt",download.getHeader("Authorization"))
    }

    @Test
    fun `update downloads are authenticated streamed and checksum gated`() = runBlocking {
        val bytes = "apk".toByteArray()
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
        val release = app.hapi.protocol.wire.AndroidRelease("com.sagewe.hapi.compliance",2,"0.34.3","work.apk",hash,3,"notes","2026-11-23T00:00:00Z","/v1/app-updates/android/download/work.apk")
        val file = java.nio.file.Files.createTempFile("update-download", ".apk").toFile()
        try {
            server.enqueue(MockResponse().setBody("apk"))
            var count = 0L
            session.api.downloadAndroidRelease(release,file) { count = it }
            assertEquals(3L,count); assertEquals("apk",file.readText())
            val request = server.takeRequest()
            assertEquals("/v1/app-updates/android/download/work.apk",request.path)
            assertEquals("Bearer $jwt",request.getHeader("Authorization"))
            server.enqueue(MockResponse().setBody("bad"))
            assertFailsWith<IllegalArgumentException> { session.api.downloadAndroidRelease(release,file) {} }
            assertTrue(!file.exists())
            server.takeRequest()
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location","https://other.example/file.apk"))
            assertFailsWith<ApiError> { session.api.downloadAndroidRelease(release,file) {} }
            server.takeRequest(); assertTrue(!file.exists())
            assertEquals(3,server.requestCount)
        } finally { file.delete() }
    }

    @Test
    fun `assistant profile and atomic preset use the shared wire contract`() = runBlocking {
        server.enqueue(ok("""{"client_profile":{"mode":"assistant","appTitle":"合规调查","defaultAgent":"agy","defaultPermissionMode":"always-proceed","defaultDirectory":"/cases","hideExecutionDetails":true,"modelPresets":[{"id":"deep","label":"深度","model":"neon-high","effort":"high","isDefault":true}],"quickActions":[{"id":"document","title":"单据审核","prompt":"审核资料"}]}}"""))
        val profile = session.api.getHubSettings().clientProfile!!
        assertEquals("assistant", profile.mode)
        assertEquals("high", profile.modelPresets.single().effort)
        assertEquals("/v1/settings", server.takeRequest().path)
        server.enqueue(ok("{}"))
        session.api.setModelPreset("case", "neon-high", "high")
        val request = server.takeRequest()
        assertEquals("PATCH", request.method)
        assertEquals("/v1/sessions/case", request.path)
        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals("neon-high", body["model"]!!.jsonPrimitive.content)
        assertEquals("high", body["effort"]!!.jsonPrimitive.content)
        assertEquals(2, server.requestCount)
    }

    @Test
    fun `updateSessionReadState maps unread and read to manualUnread boolean`() = runBlocking {
        server.enqueue(ok("""{"contentRevision":5,"readRevision":4,"readStateVersion":2,"manualUnread":true}"""))
        val unreadResp = session.api.updateSessionReadState(
            "s1",
            app.hapi.protocol.wire.SessionReadStateRequest(type = "unread", expectedVersion = 1),
        )
        val unreadReq = server.takeRequest()
        assertEquals("PUT", unreadReq.method)
        assertEquals("/v1/sessions/s1/read-state", unreadReq.path)
        val unreadBody = Json.parseToJsonElement(unreadReq.body.readUtf8()).jsonObject
        assertEquals("true", unreadBody.getValue("manualUnread").jsonPrimitive.content)
        assertEquals("1", unreadBody.getValue("expectedVersion").jsonPrimitive.content)
        assertTrue(unreadResp.readState.manualUnread)

        server.enqueue(ok("""{"contentRevision":5,"readRevision":5,"readStateVersion":3,"manualUnread":false}"""))
        session.api.updateSessionReadState(
            "s1",
            app.hapi.protocol.wire.SessionReadStateRequest(type = "read", readRevision = 5, expectedVersion = 2),
        )
        val readBody = lastRequestBody()
        assertEquals("false", readBody.getValue("manualUnread").jsonPrimitive.content)
        assertEquals("5", readBody.getValue("readRevision").jsonPrimitive.content)
    }

    @Test
    fun `updateSessionSummary patches session title on v1 sessions id`() = runBlocking {
        server.enqueue(ok("""{"session":{"id":"s1","created_at":1,"updated_at":2}}"""))
        session.api.updateSessionSummary("s1", "Updated summary")
        val req = server.takeRequest()
        assertEquals("PATCH", req.method)
        assertEquals("/v1/sessions/s1", req.path)
        assertEquals("Updated summary", Json.parseToJsonElement(req.body.readUtf8()).jsonObject.getValue("title").jsonPrimitive.content)
    }

    @Test
    fun `production clients reject cleartext hub urls`() {
        assertFailsWith<IllegalArgumentException> {
            HapiApi("http://hub.example", OkHttpClient())
        }
        assertFailsWith<IllegalArgumentException> {
            HubSession("http://hub.example", InMemoryCredentialStore())
        }
    }

    // ------------------------------------------------------------ ApiError --

    @Test
    fun `409 session_inactive maps to ApiError with code`() {
        server.enqueue(
            MockResponse().setResponseCode(409)
                .setBody("""{"error":"Session is inactive","code":"session_inactive"}""")
        )

        val error = assertFailsWith<ApiError> { runBlocking { session.api.abortSession("s1") } }
        assertEquals(409, error.status)
        assertEquals("session_inactive", error.code)
        assertEquals("""{"error":"Session is inactive","code":"session_inactive"}""", error.body)
    }

    @Test
    fun `503 rpc_target_missing maps to ApiError with code`() {
        server.enqueue(
            MockResponse().setResponseCode(503)
                .setBody("""{"error":"RPC handler unregistered","code":"rpc_target_missing"}""")
        )

        val error = assertFailsWith<ApiError> { runBlocking { session.api.getSlashCommands("s1") } }
        assertEquals(503, error.status)
        assertEquals("rpc_target_missing", error.code)
    }

    @Test
    fun `code falls back to the error string when absent`() {
        server.enqueue(MockResponse().setResponseCode(404).setBody("""{"error":"Session not found"}"""))

        val error = assertFailsWith<ApiError> { runBlocking { session.api.getSession("gone") } }
        assertEquals(404, error.status)
        assertEquals("Session not found", error.code)
    }

    @Test
    fun `non-json error bodies keep a null code`() {
        server.enqueue(MockResponse().setResponseCode(500).setBody("boom"))

        val error = assertFailsWith<ApiError> { runBlocking { session.api.getMachines() } }
        assertEquals(500, error.status)
        assertNull(error.code)
        assertEquals("boom", error.body)
    }

    // ------------------------------------------------------ request shapes --

    @Test fun `Codex implementation uses a dedicated endpoint and exact plan id`() = runBlocking {
        server.enqueue(ok("""{"ok":true}"""))
        session.api.implementCodexPlan("session/1", "plan:thread:turn:item")
        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/v1/sessions/session%2F1/codex/plan/implement", request.path)
        assertEquals("Bearer $jwt", request.getHeader("Authorization"))
        assertEquals("""{"planId":"plan:thread:turn:item"}""", request.body.readUtf8())
    }

    @Test fun `uncertain plan implementation reports its error without automatic resubmission`() = runBlocking {
        for ((status, code) in listOf(409 to "stale_plan", 409 to "unavailable", 502 to "failed", 503 to "indeterminate")) {
            server.enqueue(MockResponse().setResponseCode(status).setBody("""{"ok":false,"code":"$code","error":"Not confirmed"}"""))
            val error = assertFailsWith<ApiError> { session.api.implementCodexPlan("session", "proposal") }
            assertEquals(status, error.status)
            assertEquals(code, error.code)
        }
        assertEquals(4, server.requestCount)
    }

    @Test
    fun `messages page sends compound cursor and epoch as query params`() {
        server.enqueue(
            ok("""{"messages":[],"page":{"direction":"before","limit":200,"epoch":3,"reset":false,"hasMore":false}}""")
        )

        val response = runBlocking {
            session.api.getMessages("s1", limit = 200, beforeSeq = 120, beforeAt = 1_755_000_000_000, epoch = 3)
        }

        val request = server.takeRequest()
        val url = requireNotNull(request.requestUrl)
        assertEquals("/v1/sessions/s1/messages", url.encodedPath)
        assertEquals("1755000000000", url.queryParameter("beforeAt"))
        assertEquals("120", url.queryParameter("beforeSeq"))
        assertEquals("3", url.queryParameter("epoch"))
        assertEquals("200", url.queryParameter("limit"))
        assertNull(url.queryParameter("afterSeq"))
        assertNull(url.queryParameter("untilSeq"))
        assertEquals(3L, response.page.epoch)
        assertEquals(false, response.page.reset)
    }

    @Test
    fun `path params are percent-encoded`() {
        server.enqueue(
            ok("""{"session":{"id":"a/b","namespace":"default","seq":1,"createdAt":1,"updatedAt":1,"active":true,"metadataVersion":0,"agentStateVersion":0,"thinking":false,"thinkingAt":0}}""")
        )

        runBlocking { session.api.getSession("a/b") }
        assertEquals("/v1/sessions/a%2Fb", server.takeRequest().path)
    }

    @Test
    fun `send message body carries deliveryMode steer and omits absent fields`() {
        server.enqueue(ok("""{"ok":true}"""))

        runBlocking {
            session.api.sendMessage(
                "s1",
                SendMessageRequest(text = "fix it", localId = "local-1", deliveryMode = "steer"),
            )
        }

        val request = server.takeRequest()
        assertEquals("/v1/sessions/s1/messages", request.path)
        assertEquals("POST", request.method)
        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals(
            buildJsonObject {
                put("text", "fix it")
                put("localId", "local-1")
                put("deliveryMode", "steer")
            },
            body,
            "null fields (attachments/scheduledAt) must be omitted, not sent as null",
        )
    }

    @Test
    fun `send message body carries scheduledAt as epoch millis`() {
        server.enqueue(ok("""{"ok":true}"""))

        runBlocking {
            session.api.sendMessage(
                "s1",
                SendMessageRequest(
                    text = "later",
                    localId = "local-2",
                    deliveryMode = "queue",
                    scheduledAt = 1_761_400_200_000L,
                ),
            )
        }

        val request = server.takeRequest()
        assertEquals("/v1/sessions/s1/messages", request.path)
        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals(
            buildJsonObject {
                put("text", "later")
                put("localId", "local-2")
                put("deliveryMode", "queue")
                put("scheduledAt", 1_761_400_200_000L)
            },
            body,
            "a scheduled send rides the wire as an epoch-millis number",
        )
    }

    @Test
    fun `upload posts json base64 (not multipart) and yields the hub path`() {
        server.enqueue(ok("""{"success":true,"path":"/tmp/uploads/shot.jpg"}"""))

        val response = runBlocking {
            session.api.uploadFile("s1", "shot.jpg", "QUJDRA==", "image/jpeg")
        }

        assertTrue(response.success)
        assertEquals("/tmp/uploads/shot.jpg", response.path)
        val request = server.takeRequest()
        assertEquals("/v1/sessions/s1/uploads", request.path)
        assertEquals("POST", request.method)
        assertTrue(request.getHeader("Content-Type")!!.startsWith("application/json"))
        assertEquals(
            buildJsonObject {
                put("filename", "shot.jpg")
                put("content", "QUJDRA==")
                put("mimeType", "image/jpeg")
            },
            Json.parseToJsonElement(request.body.readUtf8()).jsonObject,
        )
    }

    @Test
    fun `delete upload posts the path`() {
        server.enqueue(ok("""{"success":true}"""))

        val response = runBlocking { session.api.deleteUpload("s1", "/tmp/uploads/shot.jpg") }

        assertTrue(response.success)
        val request = server.takeRequest()
        assertEquals("DELETE", request.method)
        assertEquals("/v1/sessions/s1/uploads", request.path)
        assertEquals(
            buildJsonObject { put("path", "/tmp/uploads/shot.jpg") },
            Json.parseToJsonElement(request.body.readUtf8()).jsonObject,
        )
    }

    @Test
    fun `approve body supports nested answers`() {
        server.enqueue(ok("""{"ok":true}"""))

        val answers = buildJsonObject {
            put("q1", buildJsonObject { putJsonArray("answers") { add("yes") } })
        }
        runBlocking {
            session.api.approvePermission(
                "s1",
                "req-9",
                ApprovePermissionRequest(decision = "approved", answers = answers),
            )
        }

        val request = server.takeRequest()
        assertEquals("/v1/sessions/s1/permissions/req-9/approve", request.path)
        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals("approved", body.getValue("decision").jsonPrimitive.content)
        val nested = body.getValue("answers").jsonObject.getValue("q1").jsonObject
        assertEquals("yes", nested.getValue("answers").jsonArray.single().jsonPrimitive.content)
        assertNull(body["mode"])
        assertNull(body["allowTools"])
    }

    @Test
    fun `deny without a decision sends an empty object`() {
        server.enqueue(ok("""{"ok":true}"""))

        runBlocking { session.api.denyPermission("s1", "req-9") }

        val request = server.takeRequest()
        assertEquals("/v1/sessions/s1/permissions/req-9/deny", request.path)
        assertEquals("{}", request.body.readUtf8())
    }

    @Test
    fun `clearing the model sends an explicit json null`() {
        server.enqueue(ok("""{"ok":true}"""))

        runBlocking { session.api.setModel("s1", model = null) }

        assertEquals(JsonNull, lastRequestBody().getValue("model"))
    }

    @Test
    fun `provider model variant sends provider slash modelId`() {
        server.enqueue(ok("""{"ok":true}"""))

        runBlocking { session.api.setModel("s1", provider = "anthropic", modelId = "claude-4") }

        val model = lastRequestBody().getValue("model").jsonPrimitive.content
        assertEquals("anthropic/claude-4", model)
    }

    @Test
    fun `spawn posts to v1 sessions and decodes v1 session envelope`() {
        server.enqueue(ok("""{"session":{"id":"sess-new","namespace":"default","machine_id":"m1","agent":"claude","directory":"/work","title":"","title_locked":false,"model":"","status":"idle","pinned":false,"pin_mode":"none","archived":false,"meta_rev":0,"state_rev":0,"message_epoch":1,"content_rev":0,"read_rev":0,"read_state_ver":0,"manual_unread":false,"pending_requests":{},"metadata":{},"created_at":1,"updated_at":1,"seq":1}}"""))

        val response = runBlocking {
            session.api.spawnSession("m1", SpawnSessionRequest(directory = "/work", agent = "claude", yolo = false))
        }

        val request = server.takeRequest()
        assertEquals("/v1/sessions", request.path)
        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals("m1", body.getValue("machine_id").jsonPrimitive.content)
        assertEquals("/work", body.getValue("directory").jsonPrimitive.content)
        assertEquals("claude", body.getValue("agent").jsonPrimitive.content)
        assertEquals("success", response.type)
        assertEquals("sess-new", response.sessionId)
    }

    @Test
    fun `machine codex models decode and rpc_target_missing surfaces as coded ApiError`() {
        server.enqueue(
            ok(
                """{"success":true,"models":[{"id":"gpt-5.2-codex","displayName":"GPT-5.2 Codex","isDefault":true,"supportedReasoningEfforts":["low","high"],"serviceTiers":["standard","fast"]}]}"""
            )
        )

        val response = runBlocking { session.api.getMachineCodexModels("m1") }
        assertEquals("/v1/machines/m1/codex-models", server.takeRequest().path)
        assertTrue(response.success)
        val model = response.models!!.single()
        assertEquals("gpt-5.2-codex", model.id)
        assertTrue(model.isDefault)
        assertContentEquals(listOf("standard", "fast"), model.serviceTiers)

        // Runner without the machine RPC: 503 + code (the create form hides the picker).
        server.enqueue(
            MockResponse()
                .setResponseCode(503)
                .setHeader("Content-Type", "application/json")
                .setBody("""{"success":false,"error":"no rpc","code":"rpc_target_missing"}""")
        )
        val error = assertFailsWith<ApiError> {
            runBlocking { session.api.getMachineCodexModels("m1") }
        }
        assertEquals(503, error.status)
        assertEquals("rpc_target_missing", error.code)
    }

    @Test
    fun `machine grok models pass cwd and keep auto support nullable`() {
        server.enqueue(
            ok(
                """{"success":true,"availableModels":[{"modelId":"grok-4","name":"Grok 4"}],"currentModelId":"grok-4","autoPermissionModeSupported":false}"""
            )
        )

        val response = runBlocking { session.api.getMachineGrokModelsForCwd("m1", "/home/dev/proj") }
        val request = server.takeRequest()
        assertEquals("GET", request.method)
        assertEquals("/v1/machines/m1/grok-models", request.path!!.substringBefore('?'))
        assertEquals("/home/dev/proj", request.requestUrl!!.queryParameter("cwd"))
        assertTrue(response.success)
        assertEquals(false, response.autoPermissionModeSupported)
        assertEquals("grok-4", response.availableModels!!.single().modelId)
        assertEquals("Grok 4", response.availableModels!!.single().name)
        assertEquals("grok-4", response.currentModelId)

        // Field omitted (runner never reported it): null — must never read as false.
        server.enqueue(ok("""{"success":true,"availableModels":[]}"""))
        val omitted = runBlocking { session.api.getMachineGrokModelsForCwd("m1", "/cwd") }
        assertNull(omitted.autoPermissionModeSupported)
    }

    @Test
    fun `unregister device is a DELETE with a json body`() {
        server.enqueue(ok("""{"ok":true}"""))

        runBlocking { session.api.unregisterDevice("fcm-token") }

        val request = server.takeRequest()
        assertEquals("DELETE", request.method)
        assertEquals("/v1/devices/register", request.path)
        assertEquals("fcm-token", Json.parseToJsonElement(request.body.readUtf8()).jsonObject.getValue("token").jsonPrimitive.content)
    }

    @Test
    fun `register device sends the persisted encryption key along with the install id`() {
        server.enqueue(ok("""{"ok":true}"""))
        val key = java.util.Base64.getEncoder().encodeToString(ByteArray(32))
        runBlocking { session.api.registerDevice(token = "FCM:MixedCase", deviceId = "install", pushKey = key) }
        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/v1/devices/register", request.path)
        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals("FCM:MixedCase", body.getValue("token").jsonPrimitive.content)
        assertEquals("phone", body.getValue("platform").jsonPrimitive.content)
        assertEquals("install", body.getValue("deviceId").jsonPrimitive.content)
        assertEquals(key, body.getValue("pushKey").jsonPrimitive.content)
    }

    // --------------------------------------------------- health & binaries --

    @Test
    fun `usage summary sends range and timeZone and decodes with auth`() {
        server.enqueue(
            ok(
                """
                {"range":{"from":null,"to":1755600000000},
                 "totals":{"inputTokens":10,"outputTokens":2,"cacheReadTokens":4,"cacheCreationTokens":1,
                           "totalTokens":12,"uncachedTokens":6,"requests":3,"sessions":2},
                 "daily":[],"byAgent":[],"byModel":[],"updatedAt":1755600000000}
                """.trimIndent()
            )
        )

        val summary = runBlocking { session.api.getUsageSummary(range = "all", timeZone = "Asia/Shanghai") }

        val request = server.takeRequest()
        val url = requireNotNull(request.requestUrl)
        assertEquals("/v1/usage/summary", url.encodedPath)
        assertEquals("all", url.queryParameter("range"))
        assertEquals("Asia/Shanghai", url.queryParameter("timeZone"))
        assertEquals("Bearer $jwt", request.getHeader("Authorization"))
        assertNull(summary.range.from)
        assertEquals(12L, summary.totals.totalTokens)
    }

    @Test
    fun `sqlite storage usage decodes and a 403 surfaces as coded ApiError`() {
        server.enqueue(
            ok("""{"path":"/x/hapi.db","databaseBytes":100,"walBytes":20,"shmBytes":4,"totalBytes":124}""")
        )
        val storage = runBlocking { session.api.getSqliteStorageUsage() }
        assertEquals("/v1/storage/sqlite", server.takeRequest().path)
        assertEquals(124L, storage.totalBytes)

        server.enqueue(
            MockResponse().setResponseCode(403)
                .setBody("""{"error":"Storage usage is only available to the hub owner"}""")
        )
        val error = assertFailsWith<ApiError> { runBlocking { session.api.getSqliteStorageUsage() } }
        assertEquals(403, error.status)
    }

    @Test
    fun `health is fetched without an authorization header`() {
        server.enqueue(ok("""{"status":"ok","protocolVersion":1,"capabilities":{"titleSuggestion":true,"brandNew":true}}"""))

        val health = runBlocking { session.api.health() }

        val request = server.takeRequest()
        assertEquals("/health", request.path)
        assertNull(request.getHeader("Authorization"))
        assertEquals(1, health.protocolVersion)
        assertEquals(true, health.capabilities?.titleSuggestion)
    }

    @Test
    fun `generated images return raw bytes and mime type`() {
        val bytes = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A)
        server.enqueue(
            MockResponse()
                .setHeader("Content-Type", "image/png")
                .setHeader("ETag", "\"img-1\"")
                .setBody(Buffer().write(bytes))
        )

        val image = runBlocking { session.api.getGeneratedImage("s1", "img-1") }

        assertEquals("/v1/sessions/s1/blobs/img-1", server.takeRequest().path)
        assertContentEquals(bytes, image.bytes)
        assertEquals("image/png", image.mimeType)
    }

    @Test
    fun `transcription providers decode from the discovery endpoint`() {
        server.enqueue(
            ok(
                """{"providers":[
                    {"id":"openai","label":"OpenAI","modes":["standard","realtime"]},
                    {"id":"browser-local","label":"Browser on-device","modes":["realtime"]}
                ]}"""
            )
        )

        val result = runBlocking { session.api.getTranscriptionProviders() }

        assertEquals("/v1/voice/transcription/providers", server.takeRequest().path)
        assertEquals(listOf("openai", "browser-local"), result.providers.map { it.id })
        assertEquals(listOf("standard", "realtime"), result.providers.first().modes)
        assertEquals("OpenAI", result.providers.first().label)
    }

    @Test
    fun `transcription helper posts multipart form data`() {
        server.enqueue(ok("""{"text":"hello world","language":"en"}"""))

        val result = runBlocking {
            session.api.transcribeVoice(
                audio = byteArrayOf(1, 2, 3),
                filename = "clip.m4a",
                mimeType = "audio/mp4",
                provider = "openai",
                language = "en-US",
            )
        }

        val request = server.takeRequest()
        assertEquals("/v1/voice/transcription", request.path)
        assertTrue(request.getHeader("Content-Type")!!.startsWith("multipart/form-data"))
        val raw = request.body.readUtf8()
        assertTrue("""name="file"; filename="clip.m4a"""" in raw)
        assertTrue("""name="provider"""" in raw && "openai" in raw)
        assertTrue("""name="mode"""" in raw && "standard" in raw)
        assertTrue("""name="language"""" in raw && "en-US" in raw)
        assertEquals("hello world", result.text)
        assertEquals("en", result.language)
    }
}
