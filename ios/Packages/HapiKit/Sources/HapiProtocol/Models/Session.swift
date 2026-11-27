import Foundation

/// The full session record returned by `GET /api/sessions/:id` and carried by
/// full-payload `session-updated` SSE events.
///
/// Mirrors `SessionSchema` (`shared/src/schemas.ts:304-338`) field by field.
/// `metadataVersion` / `agentStateVersion` / `todosUpdatedAt` /
/// `teamStateUpdatedAt` are the watermarks the versioned-patch gate in
/// `applySessionDetailPatch(session:patch:)` checks against.
public struct Session: Codable, Equatable, Sendable {
    public var contentRevision: Int?
    public var readState: SessionReadState?
    public var hasConversationContent: Bool?
    public var id: String
    public var namespace: String
    public var seq: Int
    public var createdAt: Int
    public var lastUserMessageAt: Int?
    public var updatedAt: Int
    public var pinned: Bool?
    public var globalPinned: Bool?
    public var active: Bool
    /// Last keep-alive stamp (epoch ms). The wire may carry `null` for legacy
    /// rows; zod coerces to `0` and this decoder replicates that.
    public var activeAt: Int
    public var metadata: SessionMetadata?
    public var metadataVersion: Int
    public var agentState: AgentState?
    public var agentStateVersion: Int
    public var thinking: Bool
    public var thinkingAt: Int
    public var activeTurnStartedAt: Int?
    public var backgroundTaskCount: Int?
    public var todos: [TodoItem]?
    /// Team-mode state, kept wire-verbatim (no v1 UI consumes its internals).
    public var teamState: JSONValue?
    /// Version watermark for `todos` patches (absent = 0 when gating).
    public var todosUpdatedAt: Int?
    /// Version watermark for `teamState` patches (absent = 0 when gating).
    public var teamStateUpdatedAt: Int?
    public var model: String?
    public var modelReasoningEffort: String?
    public var effort: String?
    public var serviceTier: String?
    public var permissionMode: PermissionMode?
    public var collaborationMode: CodexCollaborationMode?
    public var copilotAgentMode: CopilotAgentMode?

    public init(
        contentRevision: Int? = nil,
        readState: SessionReadState? = nil,
        hasConversationContent: Bool? = nil,
        id: String,
        namespace: String,
        seq: Int,
        createdAt: Int,
        updatedAt: Int,
        lastUserMessageAt: Int? = nil,
        pinned: Bool? = nil,
        globalPinned: Bool? = nil,
        active: Bool,
        activeAt: Int,
        metadata: SessionMetadata? = nil,
        metadataVersion: Int,
        agentState: AgentState? = nil,
        agentStateVersion: Int,
        thinking: Bool,
        thinkingAt: Int,
        activeTurnStartedAt: Int? = nil,
        backgroundTaskCount: Int? = nil,
        todos: [TodoItem]? = nil,
        teamState: JSONValue? = nil,
        todosUpdatedAt: Int? = nil,
        teamStateUpdatedAt: Int? = nil,
        model: String? = nil,
        modelReasoningEffort: String? = nil,
        effort: String? = nil,
        serviceTier: String? = nil,
        permissionMode: PermissionMode? = nil,
        collaborationMode: CodexCollaborationMode? = nil,
        copilotAgentMode: CopilotAgentMode? = nil
    ) {
        self.id = id
        self.namespace = namespace
        self.seq = seq
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUserMessageAt = lastUserMessageAt
        self.pinned = pinned
        self.globalPinned = globalPinned
        self.contentRevision = contentRevision
        self.readState = readState
        self.hasConversationContent = hasConversationContent
        self.active = active
        self.activeAt = activeAt
        self.metadata = metadata
        self.metadataVersion = metadataVersion
        self.agentState = agentState
        self.agentStateVersion = agentStateVersion
        self.thinking = thinking
        self.thinkingAt = thinkingAt
        self.activeTurnStartedAt = activeTurnStartedAt
        self.backgroundTaskCount = backgroundTaskCount
        self.todos = todos
        self.teamState = teamState
        self.todosUpdatedAt = todosUpdatedAt
        self.teamStateUpdatedAt = teamStateUpdatedAt
        self.model = model
        self.modelReasoningEffort = modelReasoningEffort
        self.effort = effort
        self.serviceTier = serviceTier
        self.permissionMode = permissionMode
        self.collaborationMode = collaborationMode
        self.copilotAgentMode = copilotAgentMode
    }

    private enum V1CodingKeys: String, CodingKey {
        case id
        case namespace
        case machine_id
        case agent
        case directory
        case title
        case title_locked
        case prompt_title
        case model
        case effort
        case permission_mode
        case status
        case pinned
        case pin_mode
        case archived
        case meta_rev
        case state_rev
        case content_rev
        case read_rev
        case read_state_ver
        case manual_unread
        case pending_requests
        case metadata
        case created_at
        case updated_at
        case seq
        case message_count
        case last_preview
    }

    public init(from decoder: Decoder) throws {
        let v1 = try decoder.container(keyedBy: V1CodingKeys.self)
        let legacy = try decoder.container(keyedBy: CodingKeys.self)

        // Native Reins v1 `Session` carries `created_at` / `updated_at` / `meta_rev`
        // (snake_case) instead of `metadataVersion`.
        if !legacy.contains(.metadataVersion) && (v1.contains(.created_at) || v1.contains(.meta_rev) || v1.contains(.machine_id)) {
            id = try v1.decode(String.self, forKey: .id)
            namespace = try v1.decode(String.self, forKey: .namespace)
            seq = try v1.decodeIfPresent(Int.self, forKey: .seq) ?? 0
            createdAt = try v1.decode(Int.self, forKey: .created_at)
            updatedAt = try v1.decode(Int.self, forKey: .updated_at)
            lastUserMessageAt = nil

            let pinMode = try v1.decodeIfPresent(String.self, forKey: .pin_mode) ?? "none"
            let rawPinned = try v1.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            globalPinned = pinMode == "global"
            pinned = pinMode == "global" ? false : (rawPinned || pinMode == "project")

            let status = try v1.decodeIfPresent(String.self, forKey: .status) ?? "idle"
            let archived = try v1.decodeIfPresent(Bool.self, forKey: .archived) ?? (status == "archived")
            active = !archived && status != "archived"
            activeAt = updatedAt
            thinking = status == "thinking"
            thinkingAt = updatedAt
            activeTurnStartedAt = nil
            backgroundTaskCount = 0

            metadataVersion = try v1.decodeIfPresent(Int.self, forKey: .meta_rev) ?? 0
            agentStateVersion = try v1.decodeIfPresent(Int.self, forKey: .state_rev) ?? 0
            contentRevision = try v1.decodeIfPresent(Int.self, forKey: .content_rev)
            let readRev = try v1.decodeIfPresent(Int.self, forKey: .read_rev) ?? 0
            let readVer = try v1.decodeIfPresent(Int.self, forKey: .read_state_ver) ?? 0
            let manualUnread = try v1.decodeIfPresent(Bool.self, forKey: .manual_unread) ?? false
            readState = SessionReadState(readRevision: readRev, manualUnread: manualUnread, version: readVer)
            let msgCount = try v1.decodeIfPresent(Int.self, forKey: .message_count) ?? 0
            hasConversationContent = msgCount > 0

            let rawModel = try v1.decodeIfPresent(String.self, forKey: .model)
            model = rawModel.flatMap { $0.isEmpty ? nil : $0 }
            let rawEffort = try v1.decodeIfPresent(String.self, forKey: .effort)
            effort = rawEffort
            modelReasoningEffort = rawEffort
            serviceTier = nil
            if let pmRaw = try v1.decodeIfPresent(String.self, forKey: .permission_mode) {
                permissionMode = PermissionMode(rawValue: pmRaw)
            } else {
                permissionMode = nil
            }
            collaborationMode = nil
            copilotAgentMode = nil
            todos = nil
            teamState = nil
            todosUpdatedAt = 0
            teamStateUpdatedAt = nil

            // `pending_requests` holds the agentState object (`{ requests, completedRequests, ... }`).
            if let pendingVal = try v1.decodeIfPresent(JSONValue.self, forKey: .pending_requests),
               case .object = pendingVal,
               let encoded = try? JSONEncoder().encode(pendingVal) {
                agentState = try? JSONDecoder().decode(AgentState.self, from: encoded)
            } else {
                agentState = nil
            }

            // Merge top-level v1 session fields with the free-form `metadata` JSON object.
            let rawMeta = (try? v1.decodeIfPresent(JSONValue.self, forKey: .metadata))?.objectValue ?? [:]
            let directory = try v1.decodeIfPresent(String.self, forKey: .directory) ?? rawMeta["path"]?.stringValue ?? ""
            let host = rawMeta["host"]?.stringValue ?? ""
            let title = try v1.decodeIfPresent(String.self, forKey: .title)
            let titleLocked = try v1.decodeIfPresent(Bool.self, forKey: .title_locked)
            let promptTitle = try v1.decodeIfPresent(String.self, forKey: .prompt_title)
            let machineId = try v1.decodeIfPresent(String.self, forKey: .machine_id)
            let agent = try v1.decodeIfPresent(String.self, forKey: .agent)

            var mergedObj = rawMeta
            mergedObj["path"] = .string(directory)
            if mergedObj["host"] == nil { mergedObj["host"] = .string(host) }
            if let title, !title.isEmpty { mergedObj["name"] = .string(title) }
            if let titleLocked { mergedObj["titleLocked"] = .bool(titleLocked) }
            if let promptTitle { mergedObj["promptTitle"] = .string(promptTitle) }
            if let machineId { mergedObj["machineId"] = .string(machineId) }
            if let agent { mergedObj["flavor"] = .string(agent) }
            mergedObj["lifecycleState"] = .string(archived ? "archived" : "running")
            if case .string(let sumText)? = mergedObj["summary"] {
                mergedObj["summary"] = .object(["text": .string(sumText), "updatedAt": .number(Double(updatedAt))])
            } else if mergedObj["summary"] == nil,
                      let preview = try v1.decodeIfPresent(String.self, forKey: .last_preview),
                      !preview.isEmpty {
                mergedObj["summary"] = .object(["text": .string(preview), "updatedAt": .number(Double(updatedAt))])
            }
            if let encoded = try? JSONEncoder().encode(JSONValue.object(mergedObj)),
               let decodedMeta = try? JSONDecoder().decode(SessionMetadata.self, from: encoded) {
                metadata = decodedMeta
            } else {
                metadata = SessionMetadata(
                    path: directory,
                    host: host,
                    titleLocked: titleLocked,
                    name: title,
                    promptTitle: promptTitle,
                    machineId: machineId,
                    flavor: agent,
                    lifecycleState: archived ? "archived" : "running"
                )
            }
            return
        }

        contentRevision = try legacy.decodeIfPresent(Int.self, forKey: .contentRevision)
        readState = try legacy.decodeIfPresent(SessionReadState.self, forKey: .readState)
        hasConversationContent = try legacy.decodeIfPresent(Bool.self, forKey: .hasConversationContent)
        id = try legacy.decode(String.self, forKey: .id)
        namespace = try legacy.decode(String.self, forKey: .namespace)
        seq = try legacy.decode(Int.self, forKey: .seq)
        createdAt = try legacy.decode(Int.self, forKey: .createdAt)
        updatedAt = try legacy.decode(Int.self, forKey: .updatedAt)
        lastUserMessageAt = try legacy.decodeIfPresent(Int.self, forKey: .lastUserMessageAt)
        pinned = try legacy.decodeIfPresent(Bool.self, forKey: .pinned)
        globalPinned = try legacy.decodeIfPresent(Bool.self, forKey: .globalPinned)
        active = try legacy.decode(Bool.self, forKey: .active)
        // zod: `z.number().nullish().transform((value) => value ?? 0)`.
        activeAt = try legacy.decodeIfPresent(Int.self, forKey: .activeAt) ?? 0
        metadata = try legacy.decodeIfPresent(SessionMetadata.self, forKey: .metadata)
        metadataVersion = try legacy.decode(Int.self, forKey: .metadataVersion)
        agentState = try legacy.decodeIfPresent(AgentState.self, forKey: .agentState)
        agentStateVersion = try legacy.decode(Int.self, forKey: .agentStateVersion)
        thinking = try legacy.decode(Bool.self, forKey: .thinking)
        thinkingAt = try legacy.decode(Int.self, forKey: .thinkingAt)
        activeTurnStartedAt = try legacy.decodeIfPresent(Int.self, forKey: .activeTurnStartedAt)
        backgroundTaskCount = try legacy.decodeIfPresent(Int.self, forKey: .backgroundTaskCount)
        todos = try legacy.decodeIfPresent([TodoItem].self, forKey: .todos)
        teamState = try legacy.decodeIfPresent(JSONValue.self, forKey: .teamState)
        todosUpdatedAt = try legacy.decodeIfPresent(Int.self, forKey: .todosUpdatedAt)
        teamStateUpdatedAt = try legacy.decodeIfPresent(Int.self, forKey: .teamStateUpdatedAt)
        model = try legacy.decodeIfPresent(String.self, forKey: .model)
        modelReasoningEffort = try legacy.decodeIfPresent(String.self, forKey: .modelReasoningEffort)
        effort = try legacy.decodeIfPresent(String.self, forKey: .effort)
        serviceTier = try legacy.decodeIfPresent(String.self, forKey: .serviceTier)
        permissionMode = try legacy.decodeIfPresent(PermissionMode.self, forKey: .permissionMode)
        collaborationMode = try legacy.decodeIfPresent(CodexCollaborationMode.self, forKey: .collaborationMode)
        copilotAgentMode = try legacy.decodeIfPresent(CopilotAgentMode.self, forKey: .copilotAgentMode)
    }
}
