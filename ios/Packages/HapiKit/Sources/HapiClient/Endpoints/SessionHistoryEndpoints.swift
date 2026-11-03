import Foundation
import HapiProtocol

/// `GET /api/sessions/:id/export` outcome.
public enum SessionExportResult: Equatable, Sendable {
    /// The `HapiSessionExport` JSON, ready to save.
    case file(SessionExportFile)
    /// Above the hub's message limit: confirm, then export with `force`.
    case warning(count: Int, limit: Int, estimatedBytes: Int)
    /// 413 — beyond the hub's resource limit even with `force`.
    case tooLarge(count: Int, estimatedBytes: Int, maxBytes: Int)
}

/// A JSON export named like the web download
/// (`<title-slug>-<id8>-<yyyy-mm-dd>.json`).
public struct SessionExportFile: Equatable, Sendable {
    public let filename: String
    public let data: Data
    public let messageCount: Int
}

/// Conversation history: fork, rewind and export (`docs/api/client-contract/rest.md`).
extension APIClient {
    /// `POST /api/sessions/:id/fork` — a new session from the current
    /// conversation, or from before `messageLocalId`. Returns its id.
    public func forkConversation(sessionId: String, messageLocalId: String? = nil) async throws -> String {
        struct ForkRequest: Encodable {
            let messageLocalId: String?
        }
        let response: ResumeSessionResponse = try await request(
            .post,
            "/api/sessions/\(encodePathComponent(sessionId))/fork",
            body: ForkRequest(messageLocalId: messageLocalId)
        )
        return response.sessionId
    }

    /// `POST /api/sessions/:id/rewind` — drop the conversation from
    /// `messageLocalId` on. A 409 `ambiguous_native_boundary_fork_safe`
    /// means only a fork can preserve the point.
    public func rewindConversation(sessionId: String, messageLocalId: String) async throws {
        struct RewindRequest: Encodable {
            let messageLocalId: String
        }
        try await requestVoid(
            .post,
            "/api/sessions/\(encodePathComponent(sessionId))/rewind",
            body: RewindRequest(messageLocalId: messageLocalId)
        )
    }

    /// `GET /api/sessions/:id/export[?force=true]`, saved as pretty JSON.
    public func exportSession(sessionId: String, force: Bool = false) async throws -> SessionExportResult {
        let data: Data
        do {
            (data, _) = try await send(
                .get,
                path: "/api/sessions/\(encodePathComponent(sessionId))/export",
                query: force ? [URLQueryItem(name: "force", value: "true")] : []
            )
        } catch let error as APIError where error.status == 413 {
            let body = error.body.flatMap { try? HapiJSON.decoder.decode(ExportLimits.self, from: Data($0.utf8)) }
            return .tooLarge(
                count: body?.count ?? 0,
                estimatedBytes: body?.estimatedBytes ?? 0,
                maxBytes: body?.maxBytes ?? 0
            )
        }
        return try SessionExportFormatting.result(from: data)
    }
}

private struct ExportLimits: Decodable {
    let type: String?
    let count: Int?
    let limit: Int?
    let estimatedBytes: Int?
    let maxBytes: Int?
}

enum SessionExportFormatting {
    struct Payload: Decodable {
        struct Session: Decodable {
            struct Metadata: Decodable {
                struct Summary: Decodable { let text: String? }
                let host: String?
                let flavor: String?
                let name: String?
                let summary: Summary?
                let path: String?
            }
            let id: String
            let metadata: Metadata?
        }
        struct Note: Decodable {
            struct Attachment: Decodable { let filename: String; let mimeType: String; let size: Int }
            let createdAt: Int
            let text: String
            let attachments: [Attachment]?
        }
        let scratchlist: [Note]?
        let exportedAt: Int
        let session: Session
        let messages: [JSONValue]
    }

    static func result(from data: Data) throws -> SessionExportResult {
        let limits = try? HapiJSON.decoder.decode(ExportLimits.self, from: data)
        if limits?.type == "warning" {
            return .warning(
                count: limits?.count ?? 0,
                limit: limits?.limit ?? 0,
                estimatedBytes: limits?.estimatedBytes ?? 0
            )
        }
        let payload = try HapiJSON.decoder.decode(Payload.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data)
        var pretty = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        pretty.append(0x0A)
        return .file(SessionExportFile(
            filename: filename(payload),
            data: pretty,
            messageCount: payload.messages.count
        ))
    }

    /// `buildSessionExportFilename`: title slug (≤ 80), id prefix, UTC date.
    private static func filename(_ payload: Payload) -> String {
        let metadata = payload.session.metadata
        let title = [metadata?.name, metadata?.summary?.text].compactMap { $0 }.first { !$0.isEmpty }
            ?? metadata?.path?.split(separator: "/").last.map(String.init)
            ?? String(payload.session.id.prefix(8))
        var slug = ""
        var pendingDash = false
        for scalar in title.lowercased().unicodeScalars {
            let keep = ("a"..."z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar))
                || (0x4E00...0x9FFF).contains(scalar.value)
            if keep {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        if slug.isEmpty { slug = "session" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date(timeIntervalSince1970: Double(payload.exportedAt) / 1000))
        return "\(String(slug.prefix(80)))-\(payload.session.id.prefix(8))-\(date).json"
    }
}

extension SessionExportFile {
    /// Readable view of the same full export payload as JSON (web markdown.ts).
    public func markdown(eventLabel: (AgentEvent) -> String = { $0.type }) throws -> SessionExportFile {
        let payload = try HapiJSON.decoder.decode(SessionExportFormatting.Payload.self, from: data)
        let meta = payload.session.metadata
        let title = [meta?.name, meta?.summary?.text].compactMap { $0 }.first { !$0.isEmpty }
            ?? meta?.path?.split(separator: "/").last.map(String.init) ?? String(payload.session.id.prefix(8))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ ms: Int) -> String { formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }
        func quote(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        }
        func json(_ value: JSONValue?) -> String {
            guard let value else { return "undefined" }
            if case .string(let string) = value { return string }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard let encoded = try? encoder.encode(value) else { return "" }
            return String(decoding: encoded, as: UTF8.self)
        }
        func short(_ value: String, _ limit: Int) -> String {
            let line = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }
        var front = ["---", "title: \"\(quote(title))\"", "sessionId: \"\(quote(payload.session.id))\"", "exportedAt: \"\(date(payload.exportedAt))\"", "messageCount: \(payload.messages.count)", "scratchlistCount: \(payload.scratchlist?.count ?? 0)"]
        for (key, value) in [("path", meta?.path), ("host", meta?.host), ("agent", meta?.flavor)] {
            if let value, !value.isEmpty { front.append("\(key): \"\(quote(value))\"") }
        }
        front.append("---")
        var sections = [front.joined(separator: "\n"), "# " + title, "Session: `\(payload.session.id)`", "Exported: \(date(payload.exportedAt))"]
        if let notes = payload.scratchlist, !notes.isEmpty {
            sections.append("## Scratchlist")
            for note in notes {
                let attachments = (note.attachments ?? []).map { "- Attachment: \($0.filename) (\($0.mimeType), \($0.size) bytes)" }.joined(separator: "\n")
                sections.append("### Note\n\n_Time: \(date(note.createdAt))_\n\n" + note.text + (attachments.isEmpty ? "" : "\n\n" + attachments))
            }
        }
        for raw in payload.messages {
            guard let message = try? HapiJSON.decoder.decode(DecryptedMessage.self, from: HapiJSON.encoder.encode(raw)),
                  let normalized = normalizeDecryptedMessage(message) else { continue }
            let role: String
            let text: String
            switch normalized.content {
            case .user(let value, let files):
                role = "User"
                let attachments = (files ?? []).map { "- Attachment: \($0.filename) (\($0.mimeType), \($0.size) bytes)" }.joined(separator: "\n")
                text = value + (attachments.isEmpty ? "" : "\n\n" + attachments)
            case .event(let event): role = "Event"; text = eventLabel(event)
            case .agent(let blocks):
                role = "Assistant"
                text = blocks.compactMap { block -> String? in
                    switch block {
                    case .text(let value): return value.text
                    case .reasoning(let value): return "> Reasoning: " + value.text
                    case .summary(let value): return "> Summary: " + value
                    case .toolCall(let value):
                        let input = value.input == nil || value.input == .null ? "" : json(value.input)
                        return "- Tool: " + value.name + (input.isEmpty ? "" : " — " + short(input, 160))
                    case .toolResult(let value):
                        let content = json(value.content)
                        return "- " + (value.isError ? "Tool error" : "Tool result") + (content.isEmpty ? "" : ": " + short(content, 240))
                    case .generatedImage(let value): return "- Generated image: " + value.fileName
                    case .codexReview(let review, _, _): return "- Codex review: \(review.overallCorrectness ?? "review") (\(review.findings.count) findings)"
                    case .sidechain: return nil
                    }
                }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
            }
            if role != "Assistant" || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append("## \(role)\n\n_Time: \(date(normalized.createdAt))_\n\n" + text)
            }
        }
        let name = (filename as NSString).deletingPathExtension + ".md"
        return SessionExportFile(filename: name, data: Data((sections.joined(separator: "\n\n") + "\n").utf8), messageCount: messageCount)
    }
}
