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
}

public struct ClientProfile: Codable, Equatable, Sendable {
    public var mode: ClientMode?
    public var appTitle: String?
    public var defaultAgent: AgentFlavor?
    public var defaultModel: String?
    public var defaultPermissionMode: String?
    public var defaultDirectory: String?
    public var hideExecutionDetails: Bool?
    public var quickActions: [ClientQuickAction]?
    public var isAssistant: Bool { mode == .assistant }
}

public struct HubSettingsResponse: Decodable, Sendable {
    public var clientProfile: ClientProfile?
}
