package app.hapi.data.api

import app.hapi.protocol.wire.SessionReadStateRequest
import app.hapi.protocol.wire.SessionReadStateResponse
import app.hapi.data.auth.HubUrls
import app.hapi.protocol.wire.AgentAvailabilityResponse
import app.hapi.protocol.wire.ApprovePermissionRequest
import app.hapi.protocol.wire.AuthRequest
import app.hapi.protocol.wire.AuthResponse
import app.hapi.protocol.wire.CancelMessageResponse
import app.hapi.protocol.wire.MessageContextResponse
import app.hapi.protocol.wire.RetryIndeterminateMessageResponse
import app.hapi.protocol.wire.RestartRunnerResponse
import app.hapi.protocol.wire.CodexModelsResponse
import app.hapi.protocol.wire.DeleteUploadRequest
import app.hapi.protocol.wire.DeleteUploadResponse
import app.hapi.protocol.wire.DenyPermissionRequest
import app.hapi.protocol.wire.FileReadResponse
import app.hapi.protocol.wire.FileSearchResponse
import app.hapi.protocol.wire.GitCommandResponse
import app.hapi.protocol.wire.GrokModelsResponse
import app.hapi.protocol.wire.HapiJson
import app.hapi.protocol.wire.HubHealthResponse
import app.hapi.protocol.wire.ListDirectoryResponse
import app.hapi.protocol.wire.MachineListDirectoryRequest
import app.hapi.protocol.wire.MachineListDirectoryResponse
import app.hapi.protocol.wire.MachinePathsExistsRequest
import app.hapi.protocol.wire.MachinePathsExistsResponse
import app.hapi.protocol.wire.MachinesResponse
import app.hapi.protocol.wire.MessagesResponse
import app.hapi.protocol.wire.QueuedStateRequest
import app.hapi.protocol.wire.QueuedStateResponse
import app.hapi.protocol.wire.RegisterDeviceRequest
import app.hapi.protocol.wire.RenameMachineRequest
import app.hapi.protocol.wire.RenameSessionRequest
import app.hapi.protocol.wire.ReopenSessionResponse
import app.hapi.protocol.wire.ResumeSessionRequest
import app.hapi.protocol.wire.ResumeSessionResponse
import app.hapi.protocol.wire.ScratchlistEntriesResponse
import app.hapi.protocol.wire.ScratchlistEntryCreateRequest
import app.hapi.protocol.wire.ScratchlistEntryResponse
import app.hapi.protocol.wire.ScratchlistEntryUpdateRequest
import app.hapi.protocol.wire.ScratchlistLimitsResponse
import app.hapi.protocol.wire.ScratchlistUploadResponse
import app.hapi.protocol.wire.SendMessageRequest
import app.hapi.protocol.wire.SessionResponse
import app.hapi.protocol.wire.SessionsResponse
import app.hapi.protocol.wire.SetSessionPinRequest
import app.hapi.protocol.wire.SkillsResponse
import app.hapi.protocol.wire.SlashCommandsResponse
import app.hapi.protocol.wire.SpawnResponse
import app.hapi.protocol.wire.SpawnSessionRequest
import app.hapi.protocol.wire.SqliteStorageUsageResponse
import app.hapi.protocol.wire.SteerQueuedMessageResponse
import app.hapi.protocol.wire.TranscriptionProvidersResponse
import app.hapi.protocol.wire.TranscriptionResponse
import app.hapi.protocol.wire.UnregisterDeviceRequest
import app.hapi.protocol.wire.UpdateSessionSummaryRequest
import app.hapi.protocol.wire.UploadFileRequest
import app.hapi.protocol.wire.UploadFileResponse
import app.hapi.protocol.wire.UsageSummaryResponse
import app.hapi.protocol.wire.VisibilityRequest
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

/** Raw generated-image payload (`GET /api/sessions/:id/generated-images/:imageId`). */
class GeneratedImage(
    val bytes: ByteArray,
    /** `Content-Type` response header, e.g. `image/png`. */
    val mimeType: String?,
)

/** Raw scratchlist-attachment payload (`GET /api/sessions/:id/scratchlist/attachments/:attachmentId`). */
class ScratchlistAttachmentFile(
    val bytes: ByteArray,
    /** `Content-Type` response header (stored attachment metadata). */
    val mimeType: String?,
)

/**
 * Typed REST surface of one hub — plain OkHttp + kotlinx.serialization
 * ([HapiJson]), one suspend method per endpoint, all funneled through
 * [request]. Paths/queries/bodies per `docs/api/client-contract/rest.md`;
 * `web/src/api/client.ts` is the reference consumer.
 *
 * - [client] carries `AuthInterceptor` + `TokenAuthenticator` (silent 401
 *   re-auth); every `/api` method uses it.
 * - [imageClient] is [client] plus a disk `Cache` for the immutable
 *   generated-image bytes (the hub sends `ETag` + `immutable`, so OkHttp
 *   revalidates with `If-None-Match` and answers 304s from disk).
 * - [authClient] is the bare client: `POST /api/auth` (unauthenticated by
 *   definition, and must not recurse into the authenticator) and `GET /health`
 *   (outside `/api`, no auth).
 *
 * Non-2xx responses throw [ApiError]. RPC-wrapped endpoints (slash-commands,
 * skills, uploads, list-directory, spawn, …) can also fail with HTTP 200 +
 * `{success: false}` — callers must check the envelope
 * (`docs/api/client-contract/errors.md#rpc-wrapped-endpoints`).
 */
class HapiApi internal constructor(
    baseUrl: HttpUrl,
    private val client: OkHttpClient,
    private val imageClient: OkHttpClient = client,
    private val authClient: OkHttpClient = client,
) : ChatSessionApi {
    /** Public production entry point: cleartext hub origins are rejected. */
    constructor(
        hubUrl: String,
        client: OkHttpClient,
        imageClient: OkHttpClient = client,
        authClient: OkHttpClient = client,
    ) : this(
        baseUrl = requireHttpsBaseUrl(hubUrl),
        client = client,
        imageClient = imageClient,
        authClient = authClient,
    )

    private val baseUrl: HttpUrl = baseUrl.newBuilder()
        .encodedPath("/")
        .query(null)
        .fragment(null)
        .build()

    /** Normalized hub origin this instance talks to. */
    val hubUrl: String = baseUrl.toString().removeSuffix("/")

    // ---------------------------------------------------------------- core --

    /**
     * Shared transport: build → await → status check → decode. `Unit` reads
     * skip decoding (the many `{ok: true}` bodies carry no information beyond
     * 2xx). OkHttp follows the request's `Accept-Encoding: gzip` default, so
     * hub-gzipped JSON is decompressed transparently.
     */
    @Suppress("UNCHECKED_CAST")
    private suspend inline fun <reified T> request(
        method: String,
        url: HttpUrl,
        body: RequestBody? = null,
        client: OkHttpClient = this.client,
    ): T {
        val request = Request.Builder().url(url).method(method, body).build()
        return client.newCall(request).await().use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw ApiError.from(response.code, text)
            if (T::class == Unit::class) Unit as T else HapiJson.decodeFromString(text)
        }
    }

    /** URL builder; each segment is percent-encoded (`encodeURIComponent` twin). */
    private fun url(vararg segments: String): HttpUrl.Builder =
        baseUrl.newBuilder().apply { segments.forEach(::addPathSegment) }

    private inline fun <reified T> T.toJsonBody(): RequestBody =
        HapiJson.encodeToString(this).toRequestBody(JSON_MEDIA_TYPE)

    private fun jsonBody(element: JsonElement): RequestBody =
        element.toString().toRequestBody(JSON_MEDIA_TYPE)

    // ------------------------------------------------------ health & auth --

    /** `GET /v1/voice/asr-config` — streaming ASR availability probe. */
    suspend fun streamingAsrAvailable(): Boolean =
        request<kotlinx.serialization.json.JsonObject>("GET", url("v1", "voice", "asr-config").build())["available"].toString() == "true"

    suspend fun prepareStreamingAsr(draft: String, recordingId: String, sessionId: String? = null) {
        request<Unit>("POST", url("v1", "voice", "asr-context").build(), jsonBody(kotlinx.serialization.json.buildJsonObject {
            put("draft", kotlinx.serialization.json.JsonPrimitive(draft.take(8000)))
            put("recording_id", kotlinx.serialization.json.JsonPrimitive(recordingId))
            sessionId?.takeIf { it.isNotBlank() }?.let { put("session_id", kotlinx.serialization.json.JsonPrimitive(it)) }
        }))
    }

    fun openStreamingAsr(
        draft: String,
        listener: okhttp3.WebSocketListener,
        recordingId: String? = null,
        sessionId: String? = null,
    ): okhttp3.WebSocket {
        val target = url("v1", "voice", "asr-ws")
            .addQueryParameter("sample_rate", "16000")
            .apply {
                recordingId?.takeIf { it.isNotBlank() }?.let { addQueryParameter("recording_id", it) }
                sessionId?.takeIf { it.isNotBlank() }?.let { addQueryParameter("session_id", it) }
            }
            .build()
        return client.newWebSocket(
            okhttp3.Request.Builder()
                .url(target)
                .header("X-ASR-Draft", java.util.Base64.getEncoder().encodeToString(draft.take(2000).toByteArray()))
                .build(),
            listener,
        )
    }

    suspend fun health(): HubHealthResponse =
        request("GET", url("health").build(), client = authClient)

    /**
     * `POST /v1/auth/login` — exchanges the pairing access token for a JWT.
     * Initial pairing entry point; steady-state refresh belongs to
     * `TokenAuthenticator`. 401 here means the token was rejected (re-pair).
     */
    suspend fun authenticate(accessToken: String): AuthResponse =
        request("POST", url("v1", "auth", "login").build(), AuthRequest(accessToken).toJsonBody(), authClient)

    // ------------------------------------------------------------ sessions --

    /** `GET /v1/sessions` — `order = "updatedAt"` for pure recency. */
    suspend fun getSessions(limit: Int? = null, order: String? = null): SessionsResponse {
        val target = url("v1", "sessions").apply {
            limit?.let { addQueryParameter("limit", it.toString()) }
            order?.let { addQueryParameter("order", it) }
        }
        return request("GET", target.build())
    }

    /** `PUT /v1/sessions/:id/read-state`. */
    suspend fun updateSessionReadState(sessionId: String, state: SessionReadStateRequest): SessionReadStateResponse {
        val manualUnread = state.manualUnread ?: (state.type == "unread")
        val body = buildJsonObject {
            state.readRevision?.let { put("readRevision", it) }
            put("manualUnread", manualUnread)
            put("expectedVersion", state.expectedVersion)
        }
        return request("PUT", url("v1", "sessions", sessionId, "read-state").build(), jsonBody(body))
    }

    suspend fun getSession(sessionId: String): SessionResponse =
        request("GET", url("v1", "sessions", sessionId).build())

    /**
     * `GET /v1/sessions/:id/messages`. Cursors are `(seq, at)` pairs that
     * always travel together; `epoch` accompanies the `after` cursor and a
     * mismatch makes the hub answer the latest page with `reset: true`
     * (`docs/api/client-contract/pagination.md`). Parameters pass through
     * unvalidated, like the web reference — the hub 400s bad combinations.
     */
    suspend fun getMessages(
        sessionId: String,
        limit: Int? = null,
        beforeSeq: Long? = null,
        beforeAt: Long? = null,
        afterSeq: Long? = null,
        afterAt: Long? = null,
        untilSeq: Long? = null,
        untilAt: Long? = null,
        epoch: Long? = null,
    ): MessagesResponse {
        val target = url("v1", "sessions", sessionId, "messages").apply {
            beforeAt?.let { addQueryParameter("beforeAt", it.toString()) }
            beforeSeq?.let { addQueryParameter("beforeSeq", it.toString()) }
            afterAt?.let { addQueryParameter("afterAt", it.toString()) }
            afterSeq?.let { addQueryParameter("afterSeq", it.toString()) }
            untilAt?.let { addQueryParameter("untilAt", it.toString()) }
            untilSeq?.let { addQueryParameter("untilSeq", it.toString()) }
            epoch?.let { addQueryParameter("epoch", it.toString()) }
            limit?.let { addQueryParameter("limit", it.toString()) }
        }
        return request("GET", target.build())
    }

    /** [MessagesApi] seam over [getMessages] — the window store's transport. */
    override suspend fun getMessages(sessionId: String, query: MessagesQuery): MessagesResponse = when (query) {
        is MessagesQuery.Latest -> getMessages(sessionId, limit = query.limit)
        is MessagesQuery.Before -> getMessages(
            sessionId,
            limit = query.limit,
            beforeSeq = query.beforeSeq,
            beforeAt = query.beforeAt,
        )
        is MessagesQuery.After -> getMessages(
            sessionId,
            limit = query.limit,
            afterSeq = query.afterSeq,
            afterAt = query.afterAt,
            untilSeq = query.untilSeq,
            untilAt = query.untilAt,
            epoch = query.epoch,
        )
    }

    /**
     * `GET /v1/sessions/:id/messages/:messageId/context` — a bounded history
     * window centered on one message, or null when it does not resolve.
     */
    override suspend fun getMessageContext(sessionId: String, messageId: String): MessageContextResponse? = try {
        request("GET", url("v1", "sessions", sessionId, "messages", messageId, "context").build())
    } catch (error: ApiError) {
        if (error.status == 404) null else throw error
    }

    /**
     * `POST /v1/sessions/:id/messages` — submits a user message; the row also
     * arrives via SSE (`message_received`), reconciled by `localId`.
     */
    override suspend fun sendMessage(sessionId: String, message: SendMessageRequest) {
        request<Unit>("POST", url("v1", "sessions", sessionId, "messages").build(), message.toJsonBody())
    }

    /** `DELETE /v1/sessions/:id/messages/:messageId` — cancel a queued message. */
    override suspend fun cancelMessage(sessionId: String, messageId: String): CancelMessageResponse =
        request("DELETE", url("v1", "sessions", sessionId, "messages", messageId).build())

    override suspend fun retryIndeterminateMessage(sessionId: String, messageId: String): RetryIndeterminateMessageResponse =
        request("POST", url("v1", "sessions", sessionId, "messages", messageId, "retry").build(), EMPTY_JSON)

    /** `POST /v1/sessions/:id/messages/:messageId/steer`. */
    override suspend fun steerMessage(sessionId: String, messageId: String): SteerQueuedMessageResponse =
        request("POST", url("v1", "sessions", sessionId, "messages", messageId, "steer").build(), EMPTY_JSON)

    /** `POST /v1/sessions/:id/messages/queued-state` — resync optimistic sends after reconnect. */
    override suspend fun getQueuedState(sessionId: String, localIds: List<String>): QueuedStateResponse =
        request(
            "POST",
            url("v1", "sessions", sessionId, "messages", "queued-state").build(),
            QueuedStateRequest(localIds).toJsonBody(),
        )

    /** `POST /v1/sessions/:id/clear` — shared sessions; returns an independent root. */
    override suspend fun clearConversation(sessionId: String): ResumeSessionResponse =
        request("POST", url("v1", "sessions", sessionId, "clear").build(), EMPTY_JSON)

    /** CLI validates the proposal, switches to Default, then queues implementation. */
    override suspend fun implementCodexPlan(sessionId: String, planId: String) {
        request<Unit>(
            "POST",
            url("v1", "sessions", sessionId, "codex", "plan", "implement").build(),
            jsonBody(buildJsonObject { put("planId", planId) }),
        )
    }

    /** `POST /v1/sessions/:id/abort` — active sessions only. */
    override suspend fun abortSession(sessionId: String) {
        request<Unit>("POST", url("v1", "sessions", sessionId, "abort").build(), EMPTY_JSON)
    }

    /** `POST /v1/sessions/:id/switch` — hand a terminal-controlled session to remote control. */
    suspend fun switchSession(sessionId: String) {
        request<Unit>("POST", url("v1", "sessions", sessionId, "switch").build(), EMPTY_JSON)
    }

    /**
     * `POST /v1/sessions/:id/resume`. The returned `sessionId` may differ
     * from [sessionId] (superseding spawn) — migrate drafts and navigation.
     */
    override suspend fun resumeSession(sessionId: String, permissionMode: String?): ResumeSessionResponse {
        val resp = request<ResumeSessionResponse>(
            "POST",
            url("v1", "sessions", sessionId, "resume").build(),
            ResumeSessionRequest(permissionMode).toJsonBody(),
        )
        if (permissionMode != null) {
            setPermissionMode(resp.sessionId, permissionMode)
        }
        return resp
    }

    /** `POST /v1/sessions/:id/resume` — reopens an archived/inactive session. */
    suspend fun reopenSession(sessionId: String): ReopenSessionResponse =
        request("POST", url("v1", "sessions", sessionId, "resume").build(), EMPTY_JSON)

    /** `POST /v1/sessions/:id/archive`. */
    suspend fun archiveSession(sessionId: String) {
        request<Unit>("POST", url("v1", "sessions", sessionId, "archive").build(), EMPTY_JSON)
    }

    /** `DELETE /v1/sessions/:id`. */
    suspend fun deleteSession(sessionId: String) {
        request<Unit>("DELETE", url("v1", "sessions", sessionId).build())
    }

    /** `PATCH /v1/sessions/:id` (+ optional `POST /v1/sessions/:id/tags`). */
    suspend fun renameInvestigation(sessionId: String, name: String, tags: List<String>) {
        request<Unit>("PATCH", url("v1", "sessions", sessionId).build(), jsonBody(buildJsonObject {
            put("title", name)
            put("title_locked", true)
        }))
        val trimmedTags = tags.map(String::trim).filter(String::isNotEmpty).take(3)
        if (trimmedTags.isNotEmpty()) {
            request<Unit>("POST", url("v1", "sessions", sessionId, "tags").build(), jsonBody(buildJsonObject {
                put("tags", kotlinx.serialization.json.JsonArray(trimmedTags.map(::JsonPrimitive)))
            }))
        }
    }

    /** `PATCH /v1/sessions/:id` — rename (1–255 chars). */
    suspend fun renameSession(sessionId: String, name: String) {
        request<Unit>("PATCH", url("v1", "sessions", sessionId).build(), jsonBody(buildJsonObject {
            put("title", name)
            put("title_locked", true)
        }))
    }

    /** `PATCH /v1/sessions/:id` — updates session title/summary. */
    suspend fun updateSessionSummary(sessionId: String, text: String) {
        request<Unit>(
            "PATCH",
            url("v1", "sessions", sessionId).build(),
            jsonBody(buildJsonObject { put("title", text) }),
        )
    }

    /** `PATCH /v1/sessions/:id` — `pin_mode` `'none' | 'project' | 'global'`. */
    suspend fun setSessionPinMode(sessionId: String, mode: String) {
        request<Unit>(
            "PATCH",
            url("v1", "sessions", sessionId).build(),
            jsonBody(buildJsonObject { put("pin_mode", mode) }),
        )
    }

    // --------------------------------------------------------- permissions --

    /**
     * `POST /v1/sessions/:id/permissions/:requestId/approve`. 409 `request_not_found`
     * when the request is no longer pending; 409 `session_inactive` on an inactive
     * session (offer Reopen).
     */
    override suspend fun approvePermission(
        sessionId: String,
        requestId: String,
        options: ApprovePermissionRequest,
    ) {
        request<Unit>(
            "POST",
            url("v1", "sessions", sessionId, "permissions", requestId, "approve").build(),
            options.toJsonBody(),
        )
    }

    /** `POST /v1/sessions/:id/permissions/:requestId/deny`. */
    override suspend fun denyPermission(sessionId: String, requestId: String, decision: String?) {
        request<Unit>(
            "POST",
            url("v1", "sessions", sessionId, "permissions", requestId, "deny").build(),
            DenyPermissionRequest(decision).toJsonBody(),
        )
    }

    // ------------------------------------------- session config (per flavor) --

    /** `PATCH /v1/sessions/:id` — `permission_mode`. */
    override suspend fun setPermissionMode(sessionId: String, mode: String) {
        request<Unit>(
            "PATCH",
            url("v1", "sessions", sessionId).build(),
            jsonBody(buildJsonObject { put("permission_mode", mode) }),
        )
    }

    /** `PATCH /v1/sessions/:id` — `model` string id, or null to clear back to default. */
    override suspend fun setModel(sessionId: String, model: String?) {
        setModelElement(sessionId, model?.let(::JsonPrimitive) ?: JsonNull)
    }

    /** `PATCH /v1/sessions/:id` — `model` `"$provider/$modelId"` variant. */
    suspend fun setModel(sessionId: String, provider: String, modelId: String) {
        setModelElement(sessionId, JsonPrimitive("$provider/$modelId"))
    }

    private suspend fun setModelElement(sessionId: String, model: JsonElement) {
        request<Unit>(
            "PATCH",
            url("v1", "sessions", sessionId).build(),
            jsonBody(buildJsonObject { put("model", model) }),
        )
    }

    /** `PATCH /v1/sessions/:id` — `effort` (codex, opencode) — null clears. */
    override suspend fun setModelReasoningEffort(sessionId: String, modelReasoningEffort: String?) {
        request<Unit>(
            "PATCH",
            url("v1", "sessions", sessionId).build(),
            jsonBody(
                buildJsonObject {
                    put("effort", modelReasoningEffort?.let(::JsonPrimitive) ?: JsonNull)
                }
            ),
        )
    }

    /** `PATCH /v1/sessions/:id` — `effort` (claude, grok, pi) — null clears. */
    override suspend fun setEffort(sessionId: String, effort: String?) {
        request<Unit>(
            "PATCH",
            url("v1", "sessions", sessionId).build(),
            jsonBody(buildJsonObject { put("effort", effort?.let(::JsonPrimitive) ?: JsonNull) }),
        )
    }

    /** `POST /v1/sessions/:id/service-tier` (codex) — `'fast' | 'standard'`. */
    suspend fun setServiceTier(sessionId: String, serviceTier: String) {
        request<Unit>(
            "POST",
            url("v1", "sessions", sessionId, "service-tier").build(),
            jsonBody(buildJsonObject { put("serviceTier", serviceTier) }),
        )
    }

    /** `POST /v1/sessions/:id/collaboration-mode` (codex) — `'default' | 'plan'`. */
    suspend fun setCollaborationMode(sessionId: String, mode: String) {
        request<Unit>(
            "POST",
            url("v1", "sessions", sessionId, "collaboration-mode").build(),
            jsonBody(buildJsonObject { put("mode", mode) }),
        )
    }

    /** `POST /v1/sessions/:id/copilot-agent-mode` (copilot). */
    suspend fun setCopilotAgentMode(sessionId: String, mode: String) {
        request<Unit>(
            "POST",
            url("v1", "sessions", sessionId, "copilot-agent-mode").build(),
            jsonBody(buildJsonObject { put("mode", mode) }),
        )
    }

    /**
     * `GET /v1/sessions/:id/codex-models` — active codex session's model
     * catalog (RPC-wrapped: check `success`; 400 on other flavors).
     */
    override suspend fun getSessionCodexModels(sessionId: String): CodexModelsResponse =
        request("GET", url("v1", "sessions", sessionId, "codex-models").build())

    // ------------------------------------------------- commands & skills --

    /** `GET /v1/sessions/:id/slash-commands` (RPC-wrapped: check `success`). */
    override suspend fun getSlashCommands(sessionId: String): SlashCommandsResponse =
        request("GET", url("v1", "sessions", sessionId, "slash-commands").build())

    /** `GET /v1/sessions/:id/skills` (RPC-wrapped: check `success`). */
    suspend fun getSkills(sessionId: String): SkillsResponse =
        request("GET", url("v1", "sessions", sessionId, "skills").build())

    // ------------------------------------------------------------ machines --

    /** `GET /v1/machines` — online machines in the caller's namespace. */
    suspend fun getMachines(): MachinesResponse =
        request("GET", url("v1", "machines").build())

    /** `PATCH /v1/machines/:id` — empty [displayName] clears back to the hostname. */
    suspend fun renameMachine(machineId: String, displayName: String) {
        request<Unit>(
            "PATCH",
            url("v1", "machines", machineId).build(),
            RenameMachineRequest(displayName).toJsonBody(),
        )
    }

    /** `POST /v1/machines/:id/restart-runner`. */
    suspend fun restartMachineRunner(machineId: String): RestartRunnerResponse =
        request("POST", url("v1", "machines", machineId, "restart-runner").build(), EMPTY_JSON)

    /** `GET /v1/app-updates/android/latest`. */
    suspend fun getAndroidRelease(): app.hapi.protocol.wire.AndroidRelease =
        request("GET", url("v1", "app-updates", "android", "latest").build())

    suspend fun downloadAndroidRelease(release: app.hapi.protocol.wire.AndroidRelease, destination: java.io.File, progress: (Long) -> Unit) {
        app.hapi.data.update.AndroidUpdatePolicy.validate(release)
        val temporary = java.io.File(destination.parentFile, destination.name + ".part")
        try {
            val request = Request.Builder().url(url("v1", "app-updates", "android", "download", release.fileName).build()).build()
            val downloadClient = client.newBuilder().followRedirects(false).followSslRedirects(false).build()
            downloadClient.newCall(request).await().use { response ->
                if (!response.isSuccessful) throw ApiError.from(response.code, "更新下载失败")
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    val body = requireNotNull(response.body)
                    val length = body.contentLength()
                    require(length == -1L || length == release.size) { "更新大小不匹配" }
                    body.byteStream().use { input -> temporary.outputStream().use { output ->
                        val buffer = ByteArray(65536); var total = 0L
                        while(true) {
                            kotlinx.coroutines.currentCoroutineContext().ensureActive()
                            val count = input.read(buffer); if(count < 0) break
                            total += count; require(total <= release.size) { "更新超过声明大小" }
                            output.write(buffer,0,count); progress(total)
                        }
                    } }
                    app.hapi.data.update.AndroidUpdatePolicy.verify(temporary, release)
                    check(temporary.renameTo(destination)) { "无法保存更新文件" }
                }
            }
        } catch(e: Exception) { temporary.delete(); destination.delete(); throw e }
    }

    suspend fun getHubSettings(): app.hapi.protocol.wire.HubSettingsResponse =
        request("GET", url("v1", "settings").build())

    /** Model and effort are committed atomically by the hub via `PATCH /v1/sessions/:id`. */
    override suspend fun setModelPreset(sessionId: String, model: String, effort: String?) {
        request<Unit>("PATCH", url("v1", "sessions", sessionId).build(),
            jsonBody(buildJsonObject { put("model", model); effort?.let { put("effort", it) } }))
    }

    /** `POST /v1/sessions` — spawns a new session on [machineId]. */
    suspend fun spawnSession(machineId: String, spawn: SpawnSessionRequest): SpawnResponse {
        val body = buildJsonObject {
            put("machine_id", machineId)
            put("directory", spawn.directory)
            spawn.agent?.let { put("agent", it) }
            spawn.model?.let { put("model", it) }
            (spawn.effort ?: spawn.modelReasoningEffort)?.let { put("effort", it) }
            val perm = spawn.permissionMode ?: if (spawn.yolo == true) "yolo" else null
            perm?.let { put("permission_mode", it) }
        }
        return request("POST", url("v1", "sessions").build(), jsonBody(body))
    }

    /** Installed/static-configured Agents reported by the selected runner. */
    suspend fun getMachineAgentAvailability(machineId: String): AgentAvailabilityResponse =
        request("GET", url("v1", "machines", machineId, "agent-availability").build())

    /** `POST /v1/machines/:id/list-directory` (RPC-wrapped: check `success`). */
    suspend fun listMachineDirectory(
        machineId: String,
        path: String,
        includeHidden: Boolean = false,
    ): MachineListDirectoryResponse =
        request(
            "POST",
            url("v1", "machines", machineId, "list-directory").build(),
            MachineListDirectoryRequest(path, includeHidden).toJsonBody(),
        )

    /** `POST /v1/machines/:id/paths/exists` (≤ 1000 paths). */
    suspend fun checkMachinePathsExist(machineId: String, paths: List<String>): MachinePathsExistsResponse =
        request(
            "POST",
            url("v1", "machines", machineId, "paths", "exists").build(),
            MachinePathsExistsRequest(paths).toJsonBody(),
        )

    /** `GET /v1/machines/:id/codex-models`. */
    suspend fun getMachineCodexModels(machineId: String): CodexModelsResponse =
        request("GET", url("v1", "machines", machineId, "codex-models").build())

    /** `GET /v1/machines/:id/grok-models?cwd=`. */
    suspend fun getMachineGrokModelsForCwd(machineId: String, cwd: String): GrokModelsResponse =
        request(
            "GET",
            url("v1", "machines", machineId, "grok-models")
                .apply { addQueryParameter("cwd", cwd) }
                .build(),
        )

    // --------------------------------------------------------- git & files --

    /** `GET /v1/sessions/:id/git-status` — raw `git status --porcelain=v2 --branch` stdout. */
    suspend fun getGitStatus(sessionId: String): GitCommandResponse =
        request("GET", url("v1", "sessions", sessionId, "git-status").build())

    /** `GET /v1/sessions/:id/git-diff-numstat?staged=` — raw `git diff --numstat` stdout. */
    suspend fun getGitDiffNumstat(sessionId: String, staged: Boolean): GitCommandResponse {
        val target = url("v1", "sessions", sessionId, "git-diff-numstat")
            .addQueryParameter("staged", staged.toString())
        return request("GET", target.build())
    }

    /** `GET /v1/sessions/:id/git-diff-file?path=&staged=` — raw unified diff for one file. */
    suspend fun getGitDiffFile(sessionId: String, path: String, staged: Boolean? = null): GitCommandResponse {
        val target = url("v1", "sessions", sessionId, "git-diff-file")
            .addQueryParameter("path", path)
            .apply { staged?.let { addQueryParameter("staged", it.toString()) } }
        return request("GET", target.build())
    }

    /** `GET /v1/sessions/:id/file?path=` — `content` is base64; decode before display. */
    suspend fun readSessionFile(sessionId: String, path: String): FileReadResponse {
        val target = url("v1", "sessions", sessionId, "file")
            .addQueryParameter("path", path)
        return request("GET", target.build())
    }

    /** `GET /v1/sessions/:id/files?query=&limit=` — ripgrep-backed search (limit 1–500, default 200). */
    override suspend fun searchSessionFiles(sessionId: String, query: String, limit: Int?): FileSearchResponse {
        val target = url("v1", "sessions", sessionId, "files").apply {
            if (query.isNotEmpty()) addQueryParameter("query", query)
            limit?.let { addQueryParameter("limit", it.toString()) }
        }
        return request("GET", target.build())
    }

    /** `GET /v1/sessions/:id/directory?path=` — omitted path lists the session root. */
    suspend fun listSessionDirectory(sessionId: String, path: String? = null): ListDirectoryResponse {
        val target = url("v1", "sessions", sessionId, "directory").apply {
            if (!path.isNullOrEmpty()) addQueryParameter("path", path)
        }
        return request("GET", target.build())
    }

    // ---------------------------------------------------------- visibility --

    /**
     * `POST /v1/visibility` — report foreground/background for the SSE
     * subscription so the hub can suppress redundant push.
     */
    suspend fun setVisibility(subscriptionId: String, visibility: String) {
        request<Unit>(
            "POST",
            url("v1", "visibility").build(),
            VisibilityRequest(subscriptionId, visibility).toJsonBody(),
        )
    }

    suspend fun getCaseFiles(sessionId: String): app.hapi.protocol.wire.CaseFilesResponse =
        request("GET", url("v1", "sessions", sessionId, "case-files").build())

    suspend fun getCaseFile(sessionId: String, file: app.hapi.protocol.wire.CaseFile): GeneratedImage {
        require(file.category == "uploads" || file.category == "deliverables")
        return downloadBlobBytes(url("v1", "sessions", sessionId, "blobs", file.id).build())
    }

    suspend fun getRecentDeliverables(limit: Int = 50): app.hapi.protocol.wire.RecentDeliverablesResponse =
        request(
            "GET",
            url("v1", "library", "deliverables")
                .addQueryParameter("limit", limit.coerceIn(1, 100).toString())
                .build(),
        )

    suspend fun getDeliverableBytes(sessionId: String, mediaId: String): GeneratedImage =
        downloadBlobBytes(url("v1", "sessions", sessionId, "blobs", mediaId).build())

    suspend fun getReferenceDocs(): app.hapi.protocol.wire.ReferenceDocsResponse =
        request("GET", url("v1", "library", "reference-docs").build())

    suspend fun uploadReferenceDoc(
        req: app.hapi.protocol.wire.UploadReferenceDocRequest,
    ): app.hapi.protocol.wire.ReferenceDocResponse =
        request("POST", url("v1", "library", "reference-docs").build(), req.toJsonBody())

    suspend fun updateReferenceDoc(
        docId: String,
        req: app.hapi.protocol.wire.UpdateReferenceDocRequest,
    ): app.hapi.protocol.wire.ReferenceDocResponse =
        request("PATCH", url("v1", "library", "reference-docs", docId).build(), req.toJsonBody())

    suspend fun getReferenceDocBytes(docId: String): GeneratedImage =
        downloadBlobBytes(url("v1", "library", "reference-docs", docId, "blob").build())

    suspend fun deleteReferenceDoc(docId: String) {
        request<Unit>("DELETE", url("v1", "library", "reference-docs", docId).build())
    }

    suspend fun getLibraryScenarios(): app.hapi.protocol.wire.ScenariosPayload =
        request("GET", url("v1", "library", "scenarios").build())

    suspend fun saveLibraryScenarios(
        scenarios: List<app.hapi.protocol.wire.ClientQuickAction>,
    ): app.hapi.protocol.wire.ScenariosPayload =
        request(
            "PUT",
            url("v1", "library", "scenarios").build(),
            app.hapi.protocol.wire.PutScenariosRequest(scenarios).toJsonBody(),
        )

    suspend fun resetLibraryScenarios(): app.hapi.protocol.wire.ScenariosPayload =
        request("POST", url("v1", "library", "scenarios", "reset").build(), "{}".toRequestBody("application/json".toMediaType()))

    private suspend fun downloadBlobBytes(target: HttpUrl): GeneratedImage {
        return imageClient.newCall(Request.Builder().url(target).build()).await().use { response ->
            if (!response.isSuccessful) throw ApiError.from(response.code, response.body?.string().orEmpty())
            val body = requireNotNull(response.body)
            require(body.contentLength() <= 50L * 1024 * 1024) { "文件超过 50 MB" }
            val bytes = body.byteStream().use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(output.size().toLong() + count <= 50L * 1024 * 1024) { "文件超过 50 MB" }
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            require(bytes.size <= 50 * 1024 * 1024) { "文件超过 50 MB" }
            GeneratedImage(bytes, response.header("Content-Type"))
        }
    }

    // ------------------------------------------------------------- images --

    /**
     * `GET /v1/sessions/:id/blobs/:imageId` — raw bytes. Rides
     * [imageClient]'s disk cache (immutable + ETagged).
     */
    suspend fun getGeneratedImage(sessionId: String, imageId: String): GeneratedImage {
        val target = url("v1", "sessions", sessionId, "blobs", imageId).build()
        return imageClient.newCall(Request.Builder().url(target).build()).await().use { response ->
            if (!response.isSuccessful) {
                throw ApiError.from(response.code, response.body?.string().orEmpty())
            }
            GeneratedImage(
                bytes = response.body?.bytes() ?: ByteArray(0),
                mimeType = response.header("Content-Type"),
            )
        }
    }

    // ------------------------------------------------------------ uploads --

    /**
     * `POST /v1/sessions/:id/uploads` — JSON + base64 [contentBase64] (NOT
     * multipart), ≤ 50 MB decoded → 413. The returned `path` feeds the
     * `attachments` of send-message.
     */
    override suspend fun uploadFile(
        sessionId: String,
        filename: String,
        contentBase64: String,
        mimeType: String,
    ): UploadFileResponse =
        request(
            "POST",
            url("v1", "sessions", sessionId, "uploads").build(),
            UploadFileRequest(filename, contentBase64, mimeType).toJsonBody(),
        )

    /** `DELETE /v1/sessions/:id/uploads`. */
    override suspend fun deleteUpload(sessionId: String, path: String): DeleteUploadResponse =
        request(
            "DELETE",
            url("v1", "sessions", sessionId, "uploads").build(),
            DeleteUploadRequest(path).toJsonBody(),
        )

    // ---------------------------------------------------- usage & storage --

    /** `GET /v1/usage/summary?range=7d|30d|all&timeZone=<IANA>`. */
    suspend fun getUsageSummary(range: String = "7d", timeZone: String = "UTC"): UsageSummaryResponse {
        val target = url("v1", "usage", "summary")
            .addQueryParameter("range", range)
            .addQueryParameter("timeZone", timeZone)
        return request("GET", target.build())
    }

    /** `GET /v1/storage/sqlite` — hub db/wal/shm file sizes. */
    suspend fun getSqliteStorageUsage(): SqliteStorageUsageResponse =
        request("GET", url("v1", "storage", "sqlite").build())

    // --------------------------------------------------------- scratchlist --

    /** `GET /v1/sessions/:id/scratchlist` — all entries, `createdAt DESC`. */
    suspend fun getScratchlist(sessionId: String): ScratchlistEntriesResponse =
        request("GET", url("v1", "sessions", sessionId, "scratchlist").build())

    /** `POST /v1/sessions/:id/scratchlist`. */
    suspend fun createScratchlistEntry(
        sessionId: String,
        body: ScratchlistEntryCreateRequest,
    ): ScratchlistEntryResponse =
        request("POST", url("v1", "sessions", sessionId, "scratchlist").build(), body.toJsonBody())

    /** `PUT /v1/sessions/:id/scratchlist/:entryId` — 404 when the entry is gone. */
    suspend fun updateScratchlistEntry(
        sessionId: String,
        entryId: String,
        body: ScratchlistEntryUpdateRequest,
    ): ScratchlistEntryResponse =
        request("PUT", url("v1", "sessions", sessionId, "scratchlist", entryId).build(), body.toJsonBody())

    /** `DELETE /v1/sessions/:id/scratchlist/:entryId` — 404 when already gone. */
    suspend fun deleteScratchlistEntry(sessionId: String, entryId: String) {
        request<Unit>("DELETE", url("v1", "sessions", sessionId, "scratchlist", entryId).build())
    }

    /** `GET /v1/sessions/:id/scratchlist/limits` — attachment size/count/byte budgets. */
    suspend fun getScratchlistLimits(sessionId: String): ScratchlistLimitsResponse =
        request("GET", url("v1", "sessions", sessionId, "scratchlist", "limits").build())

    /** `POST /v1/sessions/:id/uploads` — JSON + base64; adapts `{success, path}` to [ScratchlistUploadResponse]. */
    suspend fun uploadScratchlistAttachment(
        sessionId: String,
        filename: String,
        contentBase64: String,
        mimeType: String,
    ): ScratchlistUploadResponse {
        val raw = request<ScratchlistUploadResponse>(
            "POST",
            url("v1", "sessions", sessionId, "uploads").build(),
            UploadFileRequest(filename, contentBase64, mimeType).toJsonBody(),
        )
        val uploadedPath = raw.path
        if (raw.attachment != null || !raw.success || uploadedPath.isNullOrBlank()) return raw
        val decodedBytes = runCatching {
            java.util.Base64.getDecoder().decode(contentBase64).size.toLong()
        }.getOrDefault(0L)
        val mediaId = raw.mediaId?.takeIf { it.isNotBlank() }
            ?: java.security.MessageDigest.getInstance("SHA-256")
                .digest(uploadedPath.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        return raw.copy(
            attachment = app.hapi.protocol.wire.ScratchlistAttachment(
                id = mediaId,
                filename = filename,
                mimeType = mimeType,
                size = decodedBytes,
                path = uploadedPath,
            ),
        )
    }

    /** `GET /v1/sessions/:id/blobs/:attachmentId` — raw bytes. */
    suspend fun getScratchlistAttachment(sessionId: String, attachmentId: String): ScratchlistAttachmentFile {
        val target = url("v1", "sessions", sessionId, "blobs", attachmentId).build()
        return imageClient.newCall(Request.Builder().url(target).build()).await().use { response ->
            if (!response.isSuccessful) {
                throw ApiError.from(response.code, response.body?.string().orEmpty())
            }
            ScratchlistAttachmentFile(
                bytes = response.body?.bytes() ?: ByteArray(0),
                mimeType = response.header("Content-Type"),
            )
        }
    }

    /** `DELETE /v1/sessions/:id/uploads` — deletes a staged upload by path/id. */
    suspend fun deleteScratchlistAttachment(sessionId: String, attachmentId: String) {
        request<Unit>(
            "DELETE",
            url("v1", "sessions", sessionId, "uploads").build(),
            DeleteUploadRequest(attachmentId).toJsonBody(),
        )
    }

    // ------------------------------------------------------------- devices --

    /** `POST /v1/devices/register` (upsert). */
    suspend fun registerDevice(token: String, deviceId: String, pushKey: String, platform: String = "phone") {
        request<Unit>(
            "POST",
            url("v1", "devices", "register").build(),
            RegisterDeviceRequest(token = token, platform = platform, deviceId = deviceId, pushKey = pushKey).toJsonBody(),
        )
    }

    /** `DELETE /v1/devices/register` — call on unpair while the JWT is still valid. */
    suspend fun unregisterDevice(token: String) {
        request<Unit>(
            "DELETE",
            url("v1", "devices", "register").build(),
            UnregisterDeviceRequest(token).toJsonBody(),
        )
    }

    // --------------------------------------------------------------- voice --

    /** `GET /v1/voice/transcription/providers`. */
    suspend fun getTranscriptionProviders(): TranscriptionProvidersResponse =
        request("GET", url("v1", "voice", "transcription", "providers").build())

    /** `POST /v1/voice/transcription` — multipart/form-data. */
    suspend fun transcribeVoice(
        audio: ByteArray,
        filename: String,
        mimeType: String,
        provider: String,
        mode: String = "standard",
        language: String? = null,
    ): TranscriptionResponse {
        val body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("file", filename, audio.toRequestBody(mimeType.toMediaType()))
            .addFormDataPart("provider", provider)
            .addFormDataPart("mode", mode)
            .apply { language?.let { addFormDataPart("language", it) } }
            .build()
        return request("POST", url("v1", "voice", "transcription").build(), body)
    }

    private companion object {
        fun requireHttpsBaseUrl(raw: String): HttpUrl = HubUrls.normalize(raw)
            ?.toHttpUrl()
            ?: throw IllegalArgumentException("Invalid HTTPS hub URL: $raw")

        val JSON_MEDIA_TYPE = "application/json".toMediaType()

        /** Reusable `{}` body for POSTs whose zod schema is an empty object. */
        val EMPTY_JSON: RequestBody = "{}".toRequestBody(JSON_MEDIA_TYPE)
    }
}

/** Suspends over [Call.enqueue]; cancelling the coroutine cancels the call. */
internal suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) {
            // Close the response when the coroutine was cancelled in the
            // hand-off window, so the connection is not leaked.
            continuation.resume(response) { _, resp, _ -> resp.close() }
        }

        override fun onFailure(call: Call, e: IOException) {
            if (!continuation.isCancelled) continuation.resumeWithException(e)
        }
    })
    continuation.invokeOnCancellation { cancel() }
}
