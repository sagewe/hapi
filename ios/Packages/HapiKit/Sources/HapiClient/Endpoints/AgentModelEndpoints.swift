import Foundation
import HapiProtocol

/// Model catalogs of the dynamically discovered agents (RPC-wrapped — check
/// `success`). Claude and Codex keep their own endpoints.
extension APIClient {
    /// `GET /v1/machines/:id/<flavor>-models`. Directory-scoped flavors
    /// (copilot, grok, kimi, opencode) require `cwd`.
    public func machineAgentModels(
        machineId: String,
        flavor: AgentFlavor,
        cwd: String? = nil
    ) async throws -> AgentModelsResponse {
        try await request(
            .get,
            "/v1/machines/\(encodePathComponent(machineId))/\(flavor.rawValue)-models",
            query: cwd.map { [URLQueryItem(name: "cwd", value: $0)] } ?? []
        )
    }

    /// `GET /v1/machines/:id/opencode-model-variants?cwd=`.
    public func machineOpencodeModelVariants(
        machineId: String,
        cwd: String
    ) async throws -> OpencodeModelVariantsResponse {
        try await request(
            .get,
            "/v1/machines/\(encodePathComponent(machineId))/opencode-model-variants",
            query: [URLQueryItem(name: "cwd", value: cwd)]
        )
    }

    /// `GET /v1/sessions/:id/<flavor>-models` (active sessions only).
    public func sessionAgentModels(
        sessionId: String,
        flavor: AgentFlavor
    ) async throws -> AgentModelsResponse {
        try await request(
            .get,
            "/v1/sessions/\(encodePathComponent(sessionId))/\(flavor.rawValue)-models"
        )
    }

    /// `GET /v1/sessions/:id/{grok,opencode}-reasoning-effort-options`.
    public func sessionReasoningEffortOptions(
        sessionId: String,
        flavor: AgentFlavor
    ) async throws -> ReasoningEffortOptionsResponse {
        try await request(
            .get,
            "/v1/sessions/\(encodePathComponent(sessionId))/\(flavor.rawValue)-reasoning-effort-options"
        )
    }
}
