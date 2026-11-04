import Foundation
import HapiProtocol

/// Machines and spawning (`docs/api/client-contract/rest.md`).
extension APIClient {
    /// `GET /api/machines` — online machines in the caller's namespace.
    public func listMachines() async throws -> [Machine] {
        let response: MachinesResponse = try await request(.get, "/api/machines")
        return response.machines
    }

    /// `PATCH /api/machines/:id` — rename (≤ 64 chars; empty string clears
    /// the custom name back to the hostname).
    public func renameMachine(id: String, displayName: String) async throws {
        struct RenameMachineRequest: Encodable {
            let displayName: String
        }
        try await requestVoid(
            .patch,
            "/api/machines/\(encodePathComponent(id))",
            body: RenameMachineRequest(displayName: displayName)
        )
    }

    /// `POST /api/machines/:id/spawn`. The response is discriminated on
    /// `type`, not HTTP status — a failed spawn is still HTTP 200 with
    /// `.error`.
    public func spawnSession(machineId: String, _ spawn: SpawnRequest) async throws -> SpawnResponse {
        try await request(
            .post,
            "/api/machines/\(encodePathComponent(machineId))/spawn",
            body: spawn
        )
    }

    /// `GET /api/machines/:id/agent-availability` — executable/static-config
    /// availability for every supported Agent. A runner lacking the RPC
    /// answers 409 `runner_upgrade_required`.
    public func machineAgentAvailability(machineId: String) async throws -> AgentAvailabilityResponse {
        try await request(.get, "/api/machines/\(encodePathComponent(machineId))/agent-availability")
    }

    /// `POST /api/machines/:id/list-directory` (RPC envelope — check
    /// `success`).
    public func listMachineDirectory(
        machineId: String,
        path: String,
        includeHidden: Bool = false
    ) async throws -> MachineListDirectoryResponse {
        struct ListDirectoryRequest: Encodable {
            let path: String
            let includeHidden: Bool
        }
        return try await request(
            .post,
            "/api/machines/\(encodePathComponent(machineId))/list-directory",
            body: ListDirectoryRequest(path: path, includeHidden: includeHidden)
        )
    }

    /// `POST /api/machines/:id/paths/exists` (≤ 1000 paths).
    public func machinePathsExist(
        machineId: String,
        paths: [String]
    ) async throws -> MachinePathsExistsResponse {
        struct PathsExistsRequest: Encodable {
            let paths: [String]
        }
        return try await request(
            .post,
            "/api/machines/\(encodePathComponent(machineId))/paths/exists",
            body: PathsExistsRequest(paths: paths)
        )
    }

    /// `GET /api/machines/:id/codex-models` — pre-spawn codex model catalog
    /// (RPC envelope — check `success`). A runner without the machine-scoped
    /// RPC answers 503 `rpc_target_missing`, surfaced as an ``APIError``
    /// whose `code` the new-session form uses to hide the picker. Added in
    /// A-M3c (endpoint documented in `docs/api/client-contract/rest.md`).
    public func machineCodexModels(machineId: String) async throws -> CodexModelsResponse {
        try await request(.get, "/api/machines/\(encodePathComponent(machineId))/codex-models")
    }

    /// `GET /api/machines/:id/usage-query/settings?agent=...`
    public func machineUsageQuerySettings(
        machineId: String,
        agent: UsageQueryAgent
    ) async throws -> UsageQuerySettingsResponse {
        try await request(
            .get,
            "/api/machines/\(encodePathComponent(machineId))/usage-query/settings",
            query: [URLQueryItem(name: "agent", value: agent.rawValue)]
        )
    }

    /// `PUT /api/machines/:id/usage-query/settings`
    public func saveMachineUsageQuerySettings(
        machineId: String,
        agent: UsageQueryAgent,
        enabled: Bool,
        templateId: String,
        template: JSONValue
    ) async throws -> UsageQuerySettingsResponse {
        struct SaveRequest: Encodable {
            let agent: UsageQueryAgent
            let enabled: Bool
            let templateId: String
            let template: JSONValue
        }
        return try await request(
            .put,
            "/api/machines/\(encodePathComponent(machineId))/usage-query/settings",
            body: SaveRequest(agent: agent, enabled: enabled, templateId: templateId, template: template)
        )
    }

    /// `POST /api/machines/:id/usage-query/test`
    public func testMachineUsageQuery(
        machineId: String,
        agent: UsageQueryAgent,
        template: JSONValue
    ) async throws -> UsageQueryResult {
        struct TestRequest: Encodable {
            let agent: UsageQueryAgent
            let template: JSONValue
        }
        return try await request(
            .post,
            "/api/machines/\(encodePathComponent(machineId))/usage-query/test",
            body: TestRequest(agent: agent, template: template)
        )
    }

    /// `POST /api/machines/:id/usage-query/query`
    public func queryMachineUsage(
        machineId: String,
        agent: UsageQueryAgent,
        force: Bool = false
    ) async throws -> UsageQueryResult {
        struct QueryRequest: Encodable {
            let agent: UsageQueryAgent
            let force: Bool
        }
        return try await request(
            .post,
            "/api/machines/\(encodePathComponent(machineId))/usage-query/query",
            body: QueryRequest(agent: agent, force: force)
        )
    }
}

// MARK: - Usage query models

/// Supported agents for Runner-side subscription quota queries.
public enum UsageQueryAgent: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case kimi
    case agy

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .kimi: "Kimi CLI"
        case .agy: "Antigravity"
        }
    }

    public static func from(flavor: String?) -> UsageQueryAgent? {
        guard let flavor else { return nil }
        return UsageQueryAgent(rawValue: flavor)
    }
}

public struct UsageQueryWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Double?

    public init(usedPercent: Double, resetsAt: Double? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var usedPercentInt: Int {
        max(0, min(100, Int(usedPercent.rounded())))
    }

    public var remainingPercentInt: Int {
        max(0, min(100, Int((100.0 - usedPercent).rounded())))
    }

    public func formatResetCountdown(nowMs: Double = Date().timeIntervalSince1970 * 1000) -> String {
        guard let resetsAt else { return "—" }
        let totalMinutes = max(0, Int(floor((resetsAt - nowMs) / 60_000)))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

public struct UsageQueryGroup: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let fiveHour: UsageQueryWindow?
    public let sevenDay: UsageQueryWindow?

    public init(id: String, name: String, fiveHour: UsageQueryWindow? = nil, sevenDay: UsageQueryWindow? = nil) {
        self.id = id
        self.name = name
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public struct UsageQueryResult: Codable, Equatable, Sendable {
    public let agent: UsageQueryAgent
    public let templateId: String
    public let status: String
    public let fiveHour: UsageQueryWindow?
    public let sevenDay: UsageQueryWindow?
    public let groups: [UsageQueryGroup]?
    public let planType: String?
    public let queriedAt: Double
    public let stale: Bool
    public let error: String?

    public init(
        agent: UsageQueryAgent,
        templateId: String,
        status: String,
        fiveHour: UsageQueryWindow? = nil,
        sevenDay: UsageQueryWindow? = nil,
        groups: [UsageQueryGroup]? = nil,
        planType: String? = nil,
        queriedAt: Double,
        stale: Bool,
        error: String? = nil
    ) {
        self.agent = agent
        self.templateId = templateId
        self.status = status
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.groups = groups
        self.planType = planType
        self.queriedAt = queriedAt
        self.stale = stale
        self.error = error
    }
}

public struct UsageQueryCredentialStatus: Codable, Equatable, Sendable {
    public let configured: Bool
    public let source: String

    public init(configured: Bool, source: String) {
        self.configured = configured
        self.source = source
    }
}

public struct UsageQueryCredentials: Codable, Equatable, Sendable {
    public let baseUrl: UsageQueryCredentialStatus
    public let apiKey: UsageQueryCredentialStatus

    public init(baseUrl: UsageQueryCredentialStatus, apiKey: UsageQueryCredentialStatus) {
        self.baseUrl = baseUrl
        self.apiKey = apiKey
    }
}

public struct UsageQuerySettingsResponse: Codable, Equatable, Sendable {
    public let agent: UsageQueryAgent
    public let enabled: Bool
    public let templateId: String
    public let template: JSONValue
    public let credentials: UsageQueryCredentials

    public init(
        agent: UsageQueryAgent,
        enabled: Bool,
        templateId: String,
        template: JSONValue,
        credentials: UsageQueryCredentials
    ) {
        self.agent = agent
        self.enabled = enabled
        self.templateId = templateId
        self.template = template
        self.credentials = credentials
    }
}

public struct UsageQueryPresetTemplate: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let template: JSONValue

    public static let all: [UsageQueryPresetTemplate] = [
        UsageQueryPresetTemplate(
            id: "codex-subscription",
            name: "Codex subscription",
            template: .object([
                "id": .string("codex-subscription"),
                "name": .string("Codex subscription"),
                "description": .string("Codex native rate-limit windows via local Codex App Server or session logs."),
                "adapter": .string("codex-native"),
                "request": .object([
                    "url": .string("https://chatgpt.com/backend-api/wham/usage"),
                    "method": .string("GET"),
                    "headers": .object(["Accept": .string("application/json")])
                ]),
                "fiveHour": .object([:]),
                "sevenDay": .object([:])
            ])
        ),
        UsageQueryPresetTemplate(
            id: "agy-subscription",
            name: "Antigravity subscription",
            template: .object([
                "id": .string("agy-subscription"),
                "name": .string("Antigravity subscription"),
                "description": .string("Antigravity CLI 5-hour and weekly model group quota windows."),
                "adapter": .string("agy-cli"),
                "request": .object([
                    "url": .string("https://antigravity.google/usage"),
                    "method": .string("GET"),
                    "headers": .object(["Accept": .string("application/json")])
                ]),
                "fiveHour": .object([:]),
                "sevenDay": .object([:])
            ])
        ),
        UsageQueryPresetTemplate(
            id: "kimi-coding-plan",
            name: "Kimi Coding Plan",
            template: .object([
                "id": .string("kimi-coding-plan"),
                "name": .string("Kimi Coding Plan"),
                "description": .string("Kimi For Coding 5-hour and 7-day windows."),
                "adapter": .string("kimi-coding"),
                "request": .object([
                    "url": .string("{{baseOrigin}}/coding/v1/usages"),
                    "method": .string("GET"),
                    "headers": .object([
                        "Accept": .string("application/json"),
                        "Authorization": .string("Bearer {{apiKey}}")
                    ])
                ]),
                "fiveHour": .object([
                    "remainingPath": .string("limits[0].detail.remaining"),
                    "limitPath": .string("limits[0].detail.limit"),
                    "resetPath": .string("limits[0].detail.resetTime"),
                    "resetUnit": .string("iso")
                ]),
                "sevenDay": .object([
                    "remainingPath": .string("usage.remaining"),
                    "limitPath": .string("usage.limit"),
                    "resetPath": .string("usage.resetTime"),
                    "resetUnit": .string("iso")
                ])
            ])
        ),
        UsageQueryPresetTemplate(
            id: "zenmux-subscription",
            name: "ZenMux subscription",
            template: .object([
                "id": .string("zenmux-subscription"),
                "name": .string("ZenMux subscription"),
                "description": .string("ZenMux management API subscription 5-hour and 7-day windows."),
                "adapter": .string("zenmux-subscription"),
                "request": .object([
                    "url": .string("{{baseOrigin}}/api/v1/management/subscription/detail"),
                    "method": .string("GET"),
                    "headers": .object([
                        "Accept": .string("application/json"),
                        "Authorization": .string("Bearer {{apiKey}}")
                    ])
                ]),
                "fiveHour": .object([:]),
                "sevenDay": .object([:])
            ])
        ),
        UsageQueryPresetTemplate(
            id: "zhipu-coding-plan",
            name: "Zhipu GLM Coding Plan",
            template: .object([
                "id": .string("zhipu-coding-plan"),
                "name": .string("Zhipu GLM Coding Plan"),
                "description": .string("Zhipu GLM personal Coding Plan quota windows."),
                "adapter": .string("zhipu-coding"),
                "request": .object([
                    "url": .string("{{baseOrigin}}/api/monitor/usage/quota/limit"),
                    "method": .string("GET"),
                    "headers": .object([
                        "Accept": .string("application/json"),
                        "Authorization": .string("{{apiKey}}")
                    ])
                ]),
                "fiveHour": .object([:]),
                "sevenDay": .object([:])
            ])
        ),
        UsageQueryPresetTemplate(
            id: "minimax-coding-plan",
            name: "MiniMax Coding Plan",
            template: .object([
                "id": .string("minimax-coding-plan"),
                "name": .string("MiniMax Coding Plan"),
                "description": .string("MiniMax Coding Plan general-model 5-hour and weekly windows."),
                "adapter": .string("minimax-coding"),
                "request": .object([
                    "url": .string("{{baseOrigin}}/v1/api/openplatform/coding_plan/remains"),
                    "method": .string("GET"),
                    "headers": .object([
                        "Accept": .string("application/json"),
                        "Authorization": .string("Bearer {{apiKey}}")
                    ])
                ]),
                "fiveHour": .object([:]),
                "sevenDay": .object([:])
            ])
        ),
        UsageQueryPresetTemplate(
            id: "generic-rate-limits",
            name: "Generic rate-limit windows",
            template: .object([
                "id": .string("generic-rate-limits"),
                "name": .string("Generic rate-limit windows"),
                "description": .string("Example for APIs exposing used/limit/reset fields; edit paths as needed."),
                "adapter": .string("json-path"),
                "request": .object([
                    "url": .string("{{baseUrl}}/usage"),
                    "method": .string("GET"),
                    "headers": .object([
                        "Accept": .string("application/json"),
                        "Authorization": .string("Bearer {{apiKey}}")
                    ])
                ]),
                "fiveHour": .object([
                    "usedPath": .string("limits[0].used"),
                    "limitPath": .string("limits[0].limit"),
                    "resetPath": .string("limits[0].resetTime"),
                    "resetUnit": .string("iso")
                ]),
                "sevenDay": .object([
                    "usedPath": .string("usage.used"),
                    "limitPath": .string("usage.limit"),
                    "resetPath": .string("usage.resetTime"),
                    "resetUnit": .string("iso")
                ])
            ])
        )
    ]
}
