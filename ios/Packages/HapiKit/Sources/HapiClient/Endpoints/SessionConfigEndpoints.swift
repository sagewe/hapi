import Foundation
import HapiProtocol

/// Per-flavor session configuration (`docs/api/client-contract/rest.md`).
/// Wrong-flavor calls answer 400 (hide the control); remote-only controls
/// answer 409 while the session is terminal-controlled. All respond
/// `{ok: true}`.
///
/// The nullable bodies (`model`, `effort`, `modelReasoningEffort`,
/// `serviceTier`) encode an **explicit JSON null** when the value is absent —
/// "reset to default" — matching the reference client's `JSON.stringify`
/// output; an omitted key would fail the hub's schema.
extension APIClient {
    /// `PATCH /v1/sessions/:id` (`permission_mode`).
    public func setPermissionMode(sessionId: String, mode: PermissionMode) async throws {
        struct PermissionModeRequest: Encodable {
            let permissionMode: PermissionMode
            enum CodingKeys: String, CodingKey {
                case permissionMode = "permission_mode"
            }
        }
        try await requestVoid(
            .patch,
            "/v1/sessions/\(encodePathComponent(sessionId))",
            body: PermissionModeRequest(permissionMode: mode)
        )
    }

    /// `PATCH /v1/sessions/:id` (`model`, optional `effort`).
    public func setModel(sessionId: String, model: ModelSelection?, effort: String? = nil) async throws {
        struct SetModelRequest: Encodable {
            let model: String?
            let effort: String?

            enum CodingKeys: String, CodingKey {
                case model, effort
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(effort, forKey: .effort)
                if let model {
                    try container.encode(model, forKey: .model)
                } else {
                    try container.encodeNil(forKey: .model)
                }
            }
        }
        let modelId: String? = switch model {
        case .id(let id): id
        case .catalogReference(let provider, let id): "\(provider)/\(id)"
        case nil: nil
        }
        try await requestVoid(
            .patch,
            "/v1/sessions/\(encodePathComponent(sessionId))",
            body: SetModelRequest(model: modelId, effort: effort)
        )
    }

    /// `PATCH /v1/sessions/:id` (`effort`).
    public func setEffort(sessionId: String, effort: String?) async throws {
        struct SetEffortRequest: Encodable {
            let effort: String?

            enum CodingKeys: String, CodingKey {
                case effort
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let effort {
                    try container.encode(effort, forKey: .effort)
                } else {
                    try container.encodeNil(forKey: .effort)
                }
            }
        }
        try await requestVoid(
            .patch,
            "/v1/sessions/\(encodePathComponent(sessionId))",
            body: SetEffortRequest(effort: effort)
        )
    }

    /// `PATCH /v1/sessions/:id` (`effort` for codex/opencode reasoning effort).
    public func setModelReasoningEffort(sessionId: String, modelReasoningEffort: String?) async throws {
        struct SetEffortRequest: Encodable {
            let effort: String?

            enum CodingKeys: String, CodingKey {
                case effort
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let effort {
                    try container.encode(effort, forKey: .effort)
                } else {
                    try container.encodeNil(forKey: .effort)
                }
            }
        }
        try await requestVoid(
            .patch,
            "/v1/sessions/\(encodePathComponent(sessionId))",
            body: SetEffortRequest(effort: modelReasoningEffort)
        )
    }

    /// `POST /v1/sessions/:id/service-tier` — codex (remote-only).
    public func setServiceTier(sessionId: String, serviceTier: ServiceTier?) async throws {
        struct SetServiceTierRequest: Encodable {
            let serviceTier: ServiceTier?

            enum CodingKeys: String, CodingKey {
                case serviceTier
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let serviceTier {
                    try container.encode(serviceTier, forKey: .serviceTier)
                } else {
                    try container.encodeNil(forKey: .serviceTier)
                }
            }
        }
        try await requestVoid(
            .post,
            "/v1/sessions/\(encodePathComponent(sessionId))/service-tier",
            body: SetServiceTierRequest(serviceTier: serviceTier)
        )
    }

    /// `POST /v1/sessions/:id/collaboration-mode` — codex (remote-only).
    public func setCollaborationMode(sessionId: String, mode: CodexCollaborationMode) async throws {
        struct CollaborationModeRequest: Encodable {
            let mode: CodexCollaborationMode
        }
        try await requestVoid(
            .post,
            "/v1/sessions/\(encodePathComponent(sessionId))/collaboration-mode",
            body: CollaborationModeRequest(mode: mode)
        )
    }

    /// `POST /v1/sessions/:id/copilot-agent-mode` — copilot (remote-only).
    public func setCopilotAgentMode(sessionId: String, mode: CopilotAgentMode) async throws {
        struct CopilotAgentModeRequest: Encodable {
            let mode: CopilotAgentMode
        }
        try await requestVoid(
            .post,
            "/v1/sessions/\(encodePathComponent(sessionId))/copilot-agent-mode",
            body: CopilotAgentModeRequest(mode: mode)
        )
    }
}
