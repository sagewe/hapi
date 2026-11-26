import Foundation
import HapiProtocol

/// `order` query of `GET /api/sessions`. The default (absent) order is the
/// hub's ranked one (globalPinned → pinned → user-input recency);
/// `updatedAt` explicitly requests pure activity recency.
public enum SessionsListOrder: String, Sendable {
    case updatedAt
}

/// Session list, detail, and lifecycle endpoints
/// (`docs/api/client-contract/rest.md`).
extension APIClient {
    public func updateSessionReadState(id: String, state: SessionReadStateRequest) async throws -> SessionReadStateResponse {
        try await request(.put, "/v1/sessions/\(encodePathComponent(id))/read-state", body: state)
    }

    /// `GET /v1/sessions`.
    public func listSessions(
        limit: Int? = nil,
        order: SessionsListOrder? = nil
    ) async throws -> [SessionSummary] {
        var query: [URLQueryItem] = []
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let order {
            query.append(URLQueryItem(name: "order", value: order.rawValue))
        }
        let response: SessionsResponse = try await request(.get, "/v1/sessions", query: query)
        return response.sessions
    }

    /// `GET /v1/sessions/:id`.
    public func session(id: String) async throws -> Session {
        let response: SessionResponse = try await request(
            .get,
            "/v1/sessions/\(encodePathComponent(id))"
        )
        return response.session
    }

    /// `POST /v1/sessions/:id/resume`. The returned session id **may differ**
    /// from `id` (fresh spawn superseding the old row) — navigate to it and
    /// migrate composer drafts.
    public func resumeSession(id: String, permissionMode: PermissionMode? = nil) async throws -> String {
        struct ResumeSessionRequest: Encodable {
            let permissionMode: PermissionMode
        }
        let path = "/v1/sessions/\(encodePathComponent(id))/resume"
        let response: ResumeSessionResponse
        if let permissionMode {
            response = try await request(.post, path, body: ResumeSessionRequest(permissionMode: permissionMode))
        } else {
            response = try await request(.post, path)
        }
        return response.sessionId
    }

    /// `POST /v1/sessions/:id/resume` (reopen). As with resume, follow the returned
    /// session id.
    public func reopenSession(id: String) async throws -> ReopenSessionResponse {
        try await request(
            .post,
            "/v1/sessions/\(encodePathComponent(id))/resume",
            body: EmptyRequestBody()
        )
    }

    /// Create a new shared root; only the caller follows the returned ID.
    public func clearConversation(id: String) async throws -> ResumeSessionResponse {
        try await request(.post, "/v1/sessions/\(encodePathComponent(id))/clear", body: EmptyRequestBody())
    }

    /// Shared Codex client action, NOT a tool approval. The CLI
    /// validates the proposal, switches to Default and queues implementation.
    /// Never emulate this with separate config/message requests or auto-retry
    /// an unconfirmed result.
    public func implementCodexPlan(sessionId: String, planId: String) async throws {
        struct ImplementPlanRequest: Encodable {
            let planId: String
        }
        try await requestVoid(
            .post,
            "/v1/sessions/\(encodePathComponent(sessionId))/codex/plan/implement",
            body: ImplementPlanRequest(planId: planId)
        )
    }

    /// `POST /v1/sessions/:id/abort` (active sessions only).
    public func abortSession(id: String) async throws {
        try await requestVoid(
            .post,
            "/v1/sessions/\(encodePathComponent(id))/abort",
            body: EmptyRequestBody()
        )
    }

    /// `POST /v1/sessions/:id/switch` — hands a terminal-controlled session
    /// over to remote control.
    public func switchSession(id: String) async throws {
        try await requestVoid(
            .post,
            "/v1/sessions/\(encodePathComponent(id))/switch",
            body: EmptyRequestBody()
        )
    }

    /// `POST /v1/sessions/:id/archive` (409 for a plain inactive session).
    public func archiveSession(id: String) async throws {
        try await requestVoid(
            .post,
            "/v1/sessions/\(encodePathComponent(id))/archive",
            body: EmptyRequestBody()
        )
    }

    /// `DELETE /v1/sessions/:id` (409 while active — archive first).
    public func deleteSession(id: String) async throws {
        try await requestVoid(.delete, "/v1/sessions/\(encodePathComponent(id))")
    }

    /// `PATCH /v1/sessions/:id` — rename / lock (plus `POST /v1/sessions/:id/tags` when tags are non-empty).
    public func renameSession(id: String, name: String? = nil, titleLocked: Bool? = nil, tags: [String]? = nil) async throws {
        struct PatchSessionRequest: Encodable {
            let title: String?
            let titleLocked: Bool?
            let tags: [String]?
        }
        let encodedId = encodePathComponent(id)
        if name != nil || titleLocked != nil || tags == nil {
            try await requestVoid(
                .patch,
                "/v1/sessions/\(encodedId)",
                body: PatchSessionRequest(title: name, titleLocked: titleLocked, tags: tags)
            )
        }
        if let tags, !tags.isEmpty {
            struct TagsRequest: Encodable { let tags: [String] }
            try await requestVoid(
                .post,
                "/v1/sessions/\(encodedId)/tags",
                body: TagsRequest(tags: Array(tags.prefix(3)))
            )
        }
    }

    /// `PATCH /v1/sessions/:id` (`title`, 1–255 chars).
    public func updateSessionSummary(id: String, text: String) async throws {
        struct UpdateSummaryRequest: Encodable {
            let title: String
        }
        try await requestVoid(
            .patch,
            "/v1/sessions/\(encodePathComponent(id))",
            body: UpdateSummaryRequest(title: text)
        )
    }

    /// `PATCH /v1/sessions/:id` (`pin_mode`).
    public func setSessionPinMode(id: String, mode: SessionPinMode) async throws {
        struct PinRequest: Encodable {
            let pinMode: SessionPinMode
            enum CodingKeys: String, CodingKey {
                case pinMode = "pin_mode"
            }
        }
        try await requestVoid(
            .patch,
            "/v1/sessions/\(encodePathComponent(id))",
            body: PinRequest(pinMode: mode)
        )
    }

    // MARK: - Session catalogs (RPC-wrapped — check `success`)

    /// `GET /v1/sessions/:id/slash-commands`.
    public func slashCommands(sessionId: String) async throws -> SlashCommandsResponse {
        try await request(.get, "/v1/sessions/\(encodePathComponent(sessionId))/slash-commands")
    }

    /// `GET /v1/sessions/:id/skills`.
    public func skills(sessionId: String) async throws -> SkillsResponse {
        try await request(.get, "/v1/sessions/\(encodePathComponent(sessionId))/skills")
    }

    /// `GET /v1/sessions/:id/codex-models` — the per-session codex model
    /// catalog for the config sheet's model picker (A-M3ab).
    public func sessionCodexModels(sessionId: String) async throws -> CodexModelsResponse {
        try await request(.get, "/v1/sessions/\(encodePathComponent(sessionId))/codex-models")
    }
}
