import Foundation

// Response shapes for the REST surface (`docs/api/client-contract/rest.md`).
// Field names mirror `shared/src/apiTypes.ts` / `shared/src/schemas.ts`
// one-to-one — no CodingKeys anywhere in this file. Discriminated unions
// (`SpawnResponse`, `CancelMessageResponse`, `SteerQueuedMessageResponse`)
// are decode-only: the client never sends them.

// MARK: - Auth & health

/// The `user` object of the auth response.
public struct AuthUser: Codable, Equatable, Sendable {
    public var id: Int
    public var username: String?
    public var firstName: String?
    public var lastName: String?

    public init(id: Int, username: String? = nil, firstName: String? = nil, lastName: String? = nil) {
        self.id = id
        self.username = username
        self.firstName = firstName
        self.lastName = lastName
    }
}

/// Success body of `POST /v1/auth/login`.
public struct AuthResponse: Codable, Equatable, Sendable {
    /// The JWT (HS256, `{uid, ns}`, 4 h expiry).
    public var token: String
    public var namespace: String?
    public var isOwner: Bool?
    public var user: AuthUser?

    public init(token: String, user: AuthUser) {
        self.token = token
        self.namespace = nil
        self.isOwner = nil
        self.user = user
    }

    public init(token: String, namespace: String? = nil, isOwner: Bool? = nil, user: AuthUser? = nil) {
        self.token = token
        self.namespace = namespace
        self.isOwner = isOwner
        self.user = user
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case namespace
        case isOwner
        case is_owner
        case user
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        namespace = try container.decodeIfPresent(String.self, forKey: .namespace)
        isOwner = try container.decodeIfPresent(Bool.self, forKey: .is_owner)
            ?? container.decodeIfPresent(Bool.self, forKey: .isOwner)
        user = try container.decodeIfPresent(AuthUser.self, forKey: .user)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encodeIfPresent(namespace, forKey: .namespace)
        try container.encodeIfPresent(isOwner, forKey: .is_owner)
        try container.encodeIfPresent(user, forKey: .user)
    }
}

/// Additive capability flags of `GET /health`. Unknown keys are ignored.
public struct HubCapabilities: Codable, Equatable, Sendable {
    public var workGraph: Bool?
    public var titleSuggestion: Bool?

    public init(workGraph: Bool? = nil, titleSuggestion: Bool? = nil) {
        self.workGraph = workGraph
        self.titleSuggestion = titleSuggestion
    }
}

/// Body of `GET /health` (unauthenticated).
public struct HubHealthResponse: Codable, Equatable, Sendable {
    public var status: String
    public var protocolVersion: Int
    public var capabilities: HubCapabilities?

    public init(status: String, protocolVersion: Int, capabilities: HubCapabilities? = nil) {
        self.status = status
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

// MARK: - Envelopes

/// Envelope of `GET /api/sessions`.
public struct SessionsResponse: Codable, Equatable, Sendable {
    public var sessions: [SessionSummary]

    public init(sessions: [SessionSummary]) {
        self.sessions = sessions
    }
}

/// Envelope of `GET /api/sessions/:id`.
public struct SessionResponse: Codable, Equatable, Sendable {
    public var session: Session

    public init(session: Session) {
        self.session = session
    }
}

/// Envelope of `GET /api/machines`.
public struct MachinesResponse: Codable, Equatable, Sendable {
    public var machines: [Machine]

    public init(machines: [Machine]) {
        self.machines = machines
    }
}

// MARK: - Session lifecycle

/// Body of `POST /v1/sessions/:id/resume` — `{ok: true, session: {...}}` or `{type: 'success', sessionId}`.
public struct ResumeSessionResponse: Codable, Equatable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }

    private struct SessionIDBox: Decodable {
        let id: String
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case session_id
        case session
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(String.self, forKey: .sessionId)
            ?? container.decodeIfPresent(String.self, forKey: .session_id) {
            self.sessionId = id
        } else if let box = try container.decodeIfPresent(SessionIDBox.self, forKey: .session) {
            self.sessionId = box.id
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.sessionId,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing sessionId or session.id")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
    }
}

/// Body of `POST /api/sessions/:id/reopen`.
///
/// Mirrors `ReopenSessionResponseSchema` (`shared/src/apiTypes.ts`). As with
/// resume, `sessionId` may differ from the id the call was made on.
public struct ReopenSessionResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var sessionId: String
    public var resumed: Bool
    /// `'acp' | 'stream-json'`; kept open for forward compatibility.
    public var cursorSessionProtocol: String?

    public init(ok: Bool, sessionId: String, resumed: Bool, cursorSessionProtocol: String? = nil) {
        self.ok = ok
        self.sessionId = sessionId
        self.resumed = resumed
        self.cursorSessionProtocol = cursorSessionProtocol
    }

    private struct SessionIDBox: Decodable { let id: String }

    private enum CodingKeys: String, CodingKey {
        case ok, sessionId, session_id, session, resumed, cursorSessionProtocol
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        if let id = try c.decodeIfPresent(String.self, forKey: .sessionId)
            ?? c.decodeIfPresent(String.self, forKey: .session_id) {
            sessionId = id
        } else if let box = try c.decodeIfPresent(SessionIDBox.self, forKey: .session) {
            sessionId = box.id
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.sessionId,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing sessionId or session.id")
            )
        }
        resumed = try c.decodeIfPresent(Bool.self, forKey: .resumed) ?? true
        cursorSessionProtocol = try c.decodeIfPresent(String.self, forKey: .cursorSessionProtocol)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ok, forKey: .ok)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(resumed, forKey: .resumed)
        try c.encodeIfPresent(cursorSessionProtocol, forKey: .cursorSessionProtocol)
    }
}

// MARK: - Spawning

/// Body of `POST /api/machines/:id/spawn`, discriminated on `type` — a failed
/// spawn is still HTTP 200 with `type: 'error'`.
public enum SpawnResponse: Equatable, Sendable {
    case success(sessionId: String)
    case error(message: String, code: String?, agent: AgentFlavor?)
}

extension SpawnResponse: Decodable {
    private struct SessionIDBox: Decodable {
        let id: String
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case sessionId
        case session_id
        case session
        case message
        case error
        case code
        case agent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let type = try container.decodeIfPresent(String.self, forKey: .type) {
            switch type {
            case "success":
                let id = try container.decodeIfPresent(String.self, forKey: .sessionId)
                    ?? container.decode(String.self, forKey: .session_id)
                self = .success(sessionId: id)
            case "error":
                self = .error(
                    message: try container.decodeIfPresent(String.self, forKey: .message) ?? "",
                    code: try container.decodeIfPresent(String.self, forKey: .code),
                    agent: try container.decodeIfPresent(AgentFlavor.self, forKey: .agent)
                )
            default:
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown SpawnResponse type '\(type)'"
                ))
            }
            return
        }
        if let box = try container.decodeIfPresent(SessionIDBox.self, forKey: .session) {
            self = .success(sessionId: box.id)
            return
        }
        if let err = try container.decodeIfPresent(String.self, forKey: .error) {
            self = .error(
                message: err,
                code: try container.decodeIfPresent(String.self, forKey: .code),
                agent: try container.decodeIfPresent(AgentFlavor.self, forKey: .agent)
            )
            return
        }
        throw DecodingError.keyNotFound(
            CodingKeys.session,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing session or type in SpawnResponse")
        )
    }
}

// MARK: - Message queue operations

public struct RetryIndeterminateMessageResponse: Decodable, Equatable, Sendable {
    public let status: String
    public let localId: String?
    public let message: DecryptedMessage?
}

/// Body of `DELETE /api/sessions/:id/messages/:messageId`, discriminated on
/// `status`. `invoked` means the cancel arrived too late — the message was
/// already handed to the agent.
public enum CancelMessageResponse: Equatable, Sendable {
    case cancelled(localId: String?)
    case invoked(message: DecryptedMessage)
    case busy(localId: String)
}

extension CancelMessageResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case status
        case localId
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "cancelled":
            self = .cancelled(localId: try container.decodeIfPresent(String.self, forKey: .localId))
        case "invoked":
            self = .invoked(message: try container.decode(DecryptedMessage.self, forKey: .message))
        case "busy":
            self = .busy(localId: try container.decode(String.self, forKey: .localId))
        default:
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown CancelMessageResponse status '\(status)'"
            ))
        }
    }
}

/// Body of `POST /api/sessions/:id/messages/:messageId/steer`, discriminated
/// on `status`.
public enum SteerQueuedMessageResponse: Equatable, Sendable {
    case steered(localId: String)
    case invoked(message: DecryptedMessage)
    case failed(error: String, localId: String?)
}

extension SteerQueuedMessageResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case status
        case localId
        case message
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "steered":
            self = .steered(localId: try container.decode(String.self, forKey: .localId))
        case "invoked":
            self = .invoked(message: try container.decode(DecryptedMessage.self, forKey: .message))
        case "failed":
            self = .failed(
                error: try container.decode(String.self, forKey: .error),
                localId: try container.decodeIfPresent(String.self, forKey: .localId)
            )
        default:
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown SteerQueuedMessageResponse status '\(status)'"
            ))
        }
    }
}

/// One invoked entry of the queued-state response.
public struct InvokedLocalMessage: Codable, Equatable, Sendable {
    public var localId: String
    public var invokedAt: Int

    public init(localId: String, invokedAt: Int) {
        self.localId = localId
        self.invokedAt = invokedAt
    }
}

/// Body of `POST /api/sessions/:id/messages/queued-state` — resyncs
/// optimistic sends after a reconnect.
public struct QueuedStateResponse: Codable, Equatable, Sendable {
    public var queuedLocalIds: [String]
    public var invokedLocalMessages: [InvokedLocalMessage]
    public var indeterminateLocalIds: [String]?
    public var dispatchingLocalIds: [String]?

    public init(
        queuedLocalIds: [String],
        invokedLocalMessages: [InvokedLocalMessage],
        indeterminateLocalIds: [String]? = nil,
        dispatchingLocalIds: [String]? = nil
    ) {
        self.queuedLocalIds = queuedLocalIds
        self.invokedLocalMessages = invokedLocalMessages
        self.indeterminateLocalIds = indeterminateLocalIds
        self.dispatchingLocalIds = dispatchingLocalIds
    }
}

// MARK: - Session catalogs (RPC-wrapped)

/// One slash command of the session catalog. `source` is kept as a raw string
/// (`'builtin' | 'user' | 'plugin' | 'project'` today) so a new source never
/// breaks decoding.
public struct SlashCommand: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var source: String
    public var content: String?
    public var pluginName: String?

    public init(
        name: String,
        description: String? = nil,
        source: String,
        content: String? = nil,
        pluginName: String? = nil
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.content = content
        self.pluginName = pluginName
    }
}

/// Body of `GET /api/sessions/:id/slash-commands` (RPC envelope — check
/// `success`, HTTP 200 alone means nothing).
public struct SlashCommandsResponse: Codable, Equatable, Sendable {
    public var success: Bool
    public var commands: [SlashCommand]?
    public var error: String?

    public init(success: Bool, commands: [SlashCommand]? = nil, error: String? = nil) {
        self.success = success
        self.commands = commands
        self.error = error
    }
}

/// One skill of the session catalog.
public struct SkillSummary: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

/// Body of `GET /api/sessions/:id/skills` (RPC envelope).
public struct SkillsResponse: Codable, Equatable, Sendable {
    public var success: Bool
    public var skills: [SkillSummary]?
    public var error: String?

    public init(success: Bool, skills: [SkillSummary]? = nil, error: String? = nil) {
        self.success = success
        self.skills = skills
        self.error = error
    }
}

// MARK: - Machine directory browsing

/// Entry type of a directory listing.
public enum DirectoryEntryType: String, Codable, Sendable {
    case file
    case directory
    case other
}

/// One entry of `GET /api/sessions/:id/directory`.
public struct DirectoryEntry: Codable, Equatable, Sendable {
    public var name: String
    public var type: DirectoryEntryType
    /// Size in bytes (files only).
    public var size: Int?
    /// mtime, epoch ms.
    public var modified: Double?

    public init(name: String, type: DirectoryEntryType, size: Int? = nil, modified: Double? = nil) {
        self.name = name
        self.type = type
        self.size = size
        self.modified = modified
    }
}

/// One entry of `POST /api/machines/:id/list-directory`
/// (`DirectoryEntry & {isGitRepo?}` flattened).
public struct MachineDirectoryEntry: Codable, Equatable, Sendable {
    public var name: String
    public var type: DirectoryEntryType
    public var size: Int?
    public var modified: Double?
    public var isGitRepo: Bool?

    public init(
        name: String,
        type: DirectoryEntryType,
        size: Int? = nil,
        modified: Double? = nil,
        isGitRepo: Bool? = nil
    ) {
        self.name = name
        self.type = type
        self.size = size
        self.modified = modified
        self.isGitRepo = isGitRepo
    }
}

/// Body of `POST /api/machines/:id/list-directory` (RPC envelope).
public struct MachineListDirectoryResponse: Codable, Equatable, Sendable {
    public var success: Bool
    public var entries: [MachineDirectoryEntry]?
    public var error: String?

    public init(success: Bool, entries: [MachineDirectoryEntry]? = nil, error: String? = nil) {
        self.success = success
        self.entries = entries
        self.error = error
    }
}

/// Body of `POST /api/machines/:id/paths/exists`.
public struct MachinePathsExistsResponse: Codable, Equatable, Sendable {
    public var exists: [String: Bool]
    public var outsideWorkspaceRoots: [String]?

    public init(exists: [String: Bool], outsideWorkspaceRoots: [String]? = nil) {
        self.exists = exists
        self.outsideWorkspaceRoots = outsideWorkspaceRoots
    }
}

// MARK: - Agent availability

/// Installed/static-configured Agent status reported by a machine runner.
public struct AgentAvailabilityEntry: Codable, Equatable, Sendable {
    public var agent: AgentFlavor
    public var available: Bool
    /// `not_found | invalid_configuration`; open string for forward compatibility.
    public var reason: String?

    public init(agent: AgentFlavor, available: Bool, reason: String? = nil) {
        self.agent = agent
        self.available = available
        self.reason = reason
    }
}

/// Body of `GET /api/machines/:id/agent-availability`.
public struct AgentAvailabilityResponse: Codable, Equatable, Sendable {
    public var agents: [AgentAvailabilityEntry]

    public init(agents: [AgentAvailabilityEntry]) {
        self.agents = agents
    }
}

// MARK: - Codex model catalog

/// One row of `GET /api/machines/:id/codex-models` (also the session-level
/// twin). Mirrors `CodexModelSummary` (`shared/src/apiTypes.ts`).
public struct CodexModelSummary: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var isDefault: Bool
    public var defaultReasoningEffort: String?
    public var defaultServiceTier: String?
    public var supportedReasoningEfforts: [String]?
    /// Service tier ids advertised for this model in the current auth/plan
    /// context (e.g. `fast`).
    public var serviceTiers: [String]?

    public init(
        id: String,
        displayName: String,
        isDefault: Bool,
        defaultReasoningEffort: String? = nil,
        defaultServiceTier: String? = nil,
        supportedReasoningEfforts: [String]? = nil,
        serviceTiers: [String]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isDefault = isDefault
        self.defaultReasoningEffort = defaultReasoningEffort
        self.defaultServiceTier = defaultServiceTier
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.serviceTiers = serviceTiers
    }
}

/// Body of `GET /api/machines/:id/codex-models` and the session-level twin
/// `GET /api/sessions/:id/codex-models` (RPC envelope — check `success`). A
/// runner that does not expose the machine-scoped RPC answers HTTP 503
/// `{success:false, code:'rpc_target_missing'}`, which surfaces as the
/// transport `APIError`, not this body. Mirrors `CodexModelsResponse`
/// (`shared/src/apiTypes.ts`).
public struct CodexModelsResponse: Codable, Equatable, Sendable {
    public var success: Bool
    public var models: [CodexModelSummary]?
    public var error: String?

    public init(success: Bool, models: [CodexModelSummary]? = nil, error: String? = nil) {
        self.success = success
        self.models = models
        self.error = error
    }
}

// MARK: - Uploads

/// Body of `POST /api/sessions/:id/upload` (RPC envelope). `path` feeds the
/// `attachments` metadata of a subsequent send-message.
public struct UploadFileResponse: Codable, Equatable, Sendable {
    public var success: Bool
    public var path: String?
    public var error: String?

    public init(success: Bool, path: String? = nil, error: String? = nil) {
        self.success = success
        self.path = path
        self.error = error
    }
}

/// Body of `POST /api/sessions/:id/upload/delete` (RPC envelope).
public struct DeleteUploadResponse: Codable, Equatable, Sendable {
    public var success: Bool
    public var error: String?

    public init(success: Bool, error: String? = nil) {
        self.success = success
        self.error = error
    }
}
