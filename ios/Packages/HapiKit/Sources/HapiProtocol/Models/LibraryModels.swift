import Foundation

public struct RecentDeliverable: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let sessionId: String
    public let sessionTitle: String
    public let category: String
    public let fileName: String
    public let mimeType: String
    public let size: Int
    public let createdAt: Double
    public let downloadPath: String

    public init(
        id: String,
        sessionId: String,
        sessionTitle: String,
        category: String = "deliverables",
        fileName: String,
        mimeType: String,
        size: Int,
        createdAt: Double,
        downloadPath: String = ""
    ) {
        self.id = id
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.category = category
        self.fileName = fileName
        self.mimeType = mimeType
        self.size = size
        self.createdAt = createdAt
        self.downloadPath = downloadPath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionId, session_id
        case sessionTitle, session_title
        case category
        case fileName, filename
        case mimeType, mime_type
        case size
        case createdAt, created_at
        case downloadPath, download_path
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decodeIfPresent(String.self, forKey: .session_id)
            ?? c.decode(String.self, forKey: .sessionId)
        sessionTitle = try c.decodeIfPresent(String.self, forKey: .session_title)
            ?? c.decodeIfPresent(String.self, forKey: .sessionTitle)
            ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "deliverables"
        fileName = try c.decodeIfPresent(String.self, forKey: .filename)
            ?? c.decode(String.self, forKey: .fileName)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mime_type)
            ?? c.decodeIfPresent(String.self, forKey: .mimeType)
            ?? "application/octet-stream"
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        createdAt = try c.decodeIfPresent(Double.self, forKey: .created_at)
            ?? c.decodeIfPresent(Double.self, forKey: .createdAt)
            ?? 0
        downloadPath = try c.decodeIfPresent(String.self, forKey: .download_path)
            ?? c.decodeIfPresent(String.self, forKey: .downloadPath)
            ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sessionId, forKey: .session_id)
        try c.encode(sessionTitle, forKey: .session_title)
        try c.encode(category, forKey: .category)
        try c.encode(fileName, forKey: .filename)
        try c.encode(mimeType, forKey: .mime_type)
        try c.encode(size, forKey: .size)
        try c.encode(createdAt, forKey: .created_at)
        try c.encode(downloadPath, forKey: .download_path)
    }

    public var isPDF: Bool { fileName.lowercased().hasSuffix(".pdf") }
    public var isZIP: Bool { fileName.lowercased().hasSuffix(".zip") }
    public var isImage: Bool { mimeType.hasPrefix("image/") }
    public var uniqueKey: String { "\(sessionId):\(id)" }
}

public struct ReferenceDoc: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let fileName: String
    public let mimeType: String
    public let size: Int
    public let scope: String
    public let scenarioIds: [String]
    public let createdAt: Double
    public let updatedAt: Double
    public let downloadPath: String

    public init(
        id: String,
        fileName: String,
        mimeType: String,
        size: Int,
        scope: String = "library",
        scenarioIds: [String] = [],
        createdAt: Double = 0,
        updatedAt: Double = 0,
        downloadPath: String = ""
    ) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.size = size
        self.scope = scope
        self.scenarioIds = scenarioIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.downloadPath = downloadPath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case fileName, filename
        case mimeType, mime_type
        case size
        case scope
        case scenarioIds, scenario_ids
        case createdAt, created_at
        case updatedAt, updated_at
        case downloadPath, download_path
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fileName = try c.decodeIfPresent(String.self, forKey: .filename)
            ?? c.decode(String.self, forKey: .fileName)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mime_type)
            ?? c.decodeIfPresent(String.self, forKey: .mimeType)
            ?? "application/octet-stream"
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "library"
        scenarioIds = try c.decodeIfPresent([String].self, forKey: .scenario_ids)
            ?? c.decodeIfPresent([String].self, forKey: .scenarioIds)
            ?? []
        createdAt = try c.decodeIfPresent(Double.self, forKey: .created_at)
            ?? c.decodeIfPresent(Double.self, forKey: .createdAt)
            ?? 0
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updated_at)
            ?? c.decodeIfPresent(Double.self, forKey: .updatedAt)
            ?? createdAt
        downloadPath = try c.decodeIfPresent(String.self, forKey: .download_path)
            ?? c.decodeIfPresent(String.self, forKey: .downloadPath)
            ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fileName, forKey: .filename)
        try c.encode(mimeType, forKey: .mime_type)
        try c.encode(size, forKey: .size)
        try c.encode(scope, forKey: .scope)
        try c.encode(scenarioIds, forKey: .scenario_ids)
        try c.encode(createdAt, forKey: .created_at)
        try c.encode(updatedAt, forKey: .updated_at)
        try c.encode(downloadPath, forKey: .download_path)
    }

    public var isGlobal: Bool { scope == "global" }
    public var isImage: Bool { mimeType.hasPrefix("image/") }
    public var isPDF: Bool { fileName.lowercased().hasSuffix(".pdf") }
}

public struct ScenariosPayload: Codable, Equatable, Sendable {
    public let scenarios: [ClientQuickAction]
    public let defaults: [ClientQuickAction]
    public let customized: Bool

    public init(scenarios: [ClientQuickAction], defaults: [ClientQuickAction] = [], customized: Bool = false) {
        self.scenarios = scenarios
        self.defaults = defaults
        self.customized = customized
    }
}

public struct SceneDraft: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: String?
    public var opensAttachment: Bool
    public var skillSlug: String?
    public var referenceDocIds: [String]
    public var summaryPoints: [String]
    public var prompt: String

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, icon, opensAttachment, skillSlug, referenceDocIds, summaryPoints, prompt
    }

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        opensAttachment: Bool = false,
        skillSlug: String? = nil,
        referenceDocIds: [String] = [],
        summaryPoints: [String] = [],
        prompt: String
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.opensAttachment = opensAttachment
        self.skillSlug = skillSlug
        self.referenceDocIds = referenceDocIds
        self.summaryPoints = summaryPoints
        self.prompt = prompt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawTitle = (try c.decode(String.self, forKey: .title)).trimmingCharacters(in: .whitespacesAndNewlines)
        title = rawTitle
        let rawId = (try c.decodeIfPresent(String.self, forKey: .id))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        id = rawId.isEmpty ? "custom-\(UUID().uuidString.prefix(8).lowercased())" : rawId
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        opensAttachment = try c.decodeIfPresent(Bool.self, forKey: .opensAttachment) ?? false
        skillSlug = try c.decodeIfPresent(String.self, forKey: .skillSlug)
        referenceDocIds = try c.decodeIfPresent([String].self, forKey: .referenceDocIds) ?? []
        summaryPoints = try c.decodeIfPresent([String].self, forKey: .summaryPoints) ?? []
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    }

    public func toQuickAction() -> ClientQuickAction {
        ClientQuickAction(
            id: id,
            title: title,
            subtitle: subtitle,
            icon: icon,
            prompt: prompt,
            opensAttachment: opensAttachment,
            isCustom: true,
            hidden: false,
            skillSlug: skillSlug,
            referenceDocIds: referenceDocIds.isEmpty ? nil : referenceDocIds,
            summaryPoints: summaryPoints.isEmpty ? nil : summaryPoints
        )
    }
}

public enum SceneDraftParser {
    public struct Extraction: Equatable, Sendable {
        public let markdown: String
        public let drafts: [SceneDraft]
        public init(markdown: String, drafts: [SceneDraft]) {
            self.markdown = markdown
            self.drafts = drafts
        }
    }

    /// Extracts fenced ```` ```qiqi-scene-draft ... ``` ```` blocks from assistant markdown,
    /// returning the remaining prose markdown and all valid decoded ``SceneDraft`` cards.
    public static func extract(from text: String) -> Extraction {
        guard text.contains("qiqi-scene-draft") else {
            return Extraction(markdown: text, drafts: [])
        }
        let pattern = #"(?s)```qiqi-scene-draft\s*\n(.*?)\n```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return Extraction(markdown: text, drafts: [])
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else {
            return Extraction(markdown: text, drafts: [])
        }
        var drafts: [SceneDraft] = []
        var cleaned = text
        let decoder = JSONDecoder()
        for match in matches.reversed() {
            let bodyRange = match.range(at: 1)
            let jsonText = nsText.substring(with: bodyRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = jsonText.data(using: .utf8),
               let draft = try? decoder.decode(SceneDraft.self, from: data),
               !draft.title.isEmpty
            {
                drafts.insert(draft, at: 0)
                if let swiftRange = Range(match.range, in: cleaned) {
                    cleaned.replaceSubrange(swiftRange, with: "")
                }
            }
        }
        cleaned = cleaned
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Extraction(markdown: cleaned, drafts: drafts)
    }
}
