import Foundation

public enum ClientMode: String, Codable, Sendable {
    case developer, assistant
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = ClientMode(rawValue: value) ?? .developer
    }
}

public struct ClientQuickAction: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: String?
    public var prompt: String
    public var opensAttachment: Bool?
    public var isCustom: Bool?
    public var hidden: Bool?
    public var skillSlug: String?
    public var referenceDocIds: [String]?
    public var summaryPoints: [String]?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        prompt: String,
        opensAttachment: Bool? = nil,
        isCustom: Bool? = nil,
        hidden: Bool? = nil,
        skillSlug: String? = nil,
        referenceDocIds: [String]? = nil,
        summaryPoints: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.prompt = prompt
        self.opensAttachment = opensAttachment
        self.isCustom = isCustom
        self.hidden = hidden
        self.skillSlug = skillSlug
        self.referenceDocIds = referenceDocIds
        self.summaryPoints = summaryPoints
    }
}

public struct ClientModelPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var subtitle: String?
    public var model: String
    public var effort: String?
    public var isDefault: Bool?

    public func matches(model current: String?, effort currentEffort: String?) -> Bool {
        let base = effort.flatMap { model.hasSuffix("-\($0)") ? String(model.dropLast($0.count + 1)) : nil } ?? model
        return (current == model || current == base) && (effort == nil || currentEffort == effort || (current == model && currentEffort == nil))
    }
}

public struct ClientProfile: Codable, Equatable, Sendable {
    public var mode: ClientMode?
    public var appTitle: String?
    public var defaultAgent: AgentFlavor?
    public var defaultModel: String?
    public var modelPresets: [ClientModelPreset]?
    public var defaultModelPreset: ClientModelPreset? {
        modelPresets?.first(where: { $0.isDefault == true })
            ?? modelPresets?.first(where: { $0.model == defaultModel }) ?? modelPresets?.first
    }
    public var defaultPermissionMode: String?
    public var defaultDirectory: String?
    public var hideExecutionDetails: Bool?
    public var quickActions: [ClientQuickAction]?
    public var isAssistant: Bool { mode == .assistant }
    public var hidesExecutionDetails: Bool { isAssistant && hideExecutionDetails != false }

    public func assistantPermissionMode(for agent: AgentFlavor) -> PermissionMode? {
        if agent == .codex {
            return ["always-proceed", "yolo"].contains(defaultPermissionMode ?? "") ? .yolo : .default
        }
        return defaultPermissionMode.flatMap(PermissionMode.init(rawValue:))
    }
}

public struct HubSettingsResponse: Decodable, Sendable {
    public var clientProfile: ClientProfile?

    private enum CodingKeys: String, CodingKey {
        case clientProfile
        case client_profile
    }

    public init(clientProfile: ClientProfile? = nil) {
        self.clientProfile = clientProfile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientProfile = try c.decodeIfPresent(ClientProfile.self, forKey: .client_profile)
            ?? c.decodeIfPresent(ClientProfile.self, forKey: .clientProfile)
    }
}
