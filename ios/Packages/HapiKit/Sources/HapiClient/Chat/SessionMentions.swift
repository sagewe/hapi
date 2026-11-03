import Foundation
import HapiProtocol

/// Native counterpart of findActiveWord.ts, sessionReference.ts and the
/// rich composer's Markdown serialization. Offsets use UIKit's UTF-16 units.
public enum SessionMentions {
    public struct Query: Equatable, Sendable {
        public let text: String
        public let range: NSRange
    }

    public static func query(in text: String, selection: NSRange, composing: Bool = false) -> Query? {
        let chars = Array(text.utf16)
        let cursor = selection.location
        guard !composing, selection.length == 0, cursor > 0, cursor <= chars.count else { return nil }
        let stops = Set("\n,()[]{}<>;!?\u{FFFC}.".utf16)
        var spaces = 0
        var start = cursor - 1
        while start >= 0 {
            let c = chars[start]
            if stops.contains(c) { return nil }
            if c == 32 {
                spaces += 1
                if spaces > 1 { return nil }
            }
            if c == 64 && (start == 0 || [32, 10, 0xFFFC].contains(chars[start - 1])) {
                guard chars[cursor - 1] != 32 else { return nil }
                var end = cursor
                while end < chars.count {
                    let next = chars[end]
                    if next == 32 || (stops.contains(next) && next != 46) { break }
                    end += 1
                }
                let value = (text as NSString).substring(with: NSRange(location: start + 1, length: cursor - start - 1))
                return Query(text: value, range: NSRange(location: start, length: end - start))
            }
            start -= 1
        }
        return nil
    }

    public static func reference(_ session: SessionSummary) -> String {
        let title = String(SessionListSearch.sessionTitle(session)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(120))
        let label = title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let id = session.id.addingPercentEncoding(withAllowedCharacters: allowed) ?? session.id
        return "[\(label.isEmpty ? String(session.id.prefix(8)) : label)](/sessions/\(id))"
    }

    public static func inserting(_ session: SessionSummary, into text: String, selection: NSRange) -> (text: String, selection: NSRange)? {
        guard let query = query(in: text, selection: selection) else { return nil }
        let end = NSMaxRange(query.range)
        let source = text as NSString
        let space = end == source.length || source.substring(with: NSRange(location: end, length: 1)) != " " ? " " : ""
        let replacement = reference(session) + space
        return (source.replacingCharacters(in: query.range, with: replacement),
                NSRange(location: query.range.location + replacement.utf16.count, length: 0))
    }

    public static func matches(_ sessions: [SessionSummary], query: String, excluding id: String,
                               machineLabel: (String?) -> String = { $0 ?? "" }) -> [SessionSummary] {
        // Match web dedup BEFORE eligibility: the live connection wins over its
        // stale predecessor, and the current session must never cite itself.
        var groups: [String: SessionSummary] = [:]
        for session in sessions {
            let agent = session.metadata?.agentSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = agent.isEmpty ? "id:\(session.id)" : "agent:\(session.metadata?.flavor ?? "unknown"):\(agent)"
            if let old = groups[key] {
                let left = [session.active, session.id == id, session.globalPinned == true, session.pinned == true]
                let right = [old.active, old.id == id, old.globalPinned == true, old.pinned == true]
                if let index = Array(zip(left, right)).firstIndex(where: { $0.0 != $0.1 }) {
                    if !left[index] { continue }
                } else if session.updatedAt <= old.updatedAt { continue }
            }
            groups[key] = session
        }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let eligible = groups.values.filter { $0.id != id && $0.hasConversationContent == true }
        let index = SessionListSearch.scoreIndex(sessions: Array(eligible), query: normalized, machineLabel: machineLabel)
        let filtered = eligible.filter { normalized.isEmpty ? $0.metadata?.lifecycleState != "archived" : index?.matches($0.id) == true }
        func score(_ session: SessionSummary) -> Int {
            if normalized.isEmpty { return session.active ? 1 : 0 }
            let title = SessionListSearch.sessionTitle(session).lowercased()
            let sid = session.id.lowercased()
            let base = title == normalized ? 500 : title.hasPrefix(normalized) ? 400 : title.contains(normalized) ? 300 : sid.hasPrefix(normalized) ? 200 : sid.contains(normalized) ? 100 : 150
            return base + (session.active ? 50 : 0) - (session.metadata?.lifecycleState == "archived" ? 25 : 0)
        }
        return Array(filtered.sorted {
            let a = score($0), b = score($1)
            if a != b { return a > b }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }.prefix(20))
    }
}

/// Skills use the web's dollar token and name-only fuzzy ranking.
public enum SkillSuggestions {
    public static func query(in text: String, selection: NSRange, composing: Bool = false) -> SessionMentions.Query? {
        let source = text as NSString
        guard !composing, selection.length == 0, selection.location > 0, selection.location <= source.length else { return nil }
        let before = source.substring(to: selection.location)
        guard let range = before.range(of: #"(?:^|\s)(\$[^\s$]*)$"#, options: .regularExpression) else { return nil }
        let matched = String(before[range])
        guard let dollar = matched.firstIndex(of: "$") else { return nil }
        let token = String(matched[dollar...])
        let start = selection.location - token.utf16.count
        var end = selection.location
        while end < source.length, let scalar = UnicodeScalar(source.character(at: end)), !CharacterSet.whitespacesAndNewlines.contains(scalar) { end += 1 }
        return SessionMentions.Query(text: String(token.dropFirst()), range: NSRange(location: start, length: end - start))
    }

    public static func matches(_ skills: [SkillSummary], query: String, recent: [String: Double] = [:]) -> [SkillSummary] {
        let term = query.lowercased()
        func distance(_ a: String, _ b: String) -> Int {
            let a = Array(a), b = Array(b)
            var previous = Array(0...b.count)
            for (i, x) in a.enumerated() {
                var next = [i + 1]
                for (j, y) in b.enumerated() { next.append(min(next[j] + 1, previous[j + 1] + 1, previous[j] + (x == y ? 0 : 1))) }
                previous = next
            }
            return previous[b.count]
        }
        func score(_ skill: SkillSummary) -> Int {
            let name = skill.name.lowercased()
            if term.isEmpty || name == term { return 0 }
            if name.hasPrefix(term) { return 1 }
            if name.contains(term) { return 2 }
            let d = distance(term, name)
            return d <= max(2, term.count / 2) ? 3 + d : Int.max
        }
        var seen = Set<String>()
        return skills.filter { seen.insert($0.name).inserted && score($0) < Int.max }.sorted {
            if score($0) != score($1) { return score($0) < score($1) }
            if recent[$0.name, default: 0] != recent[$1.name, default: 0] { return recent[$0.name, default: 0] > recent[$1.name, default: 0] }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func insert(_ name: String, text: String, query: SessionMentions.Query) -> (String, NSRange) {
        let source = text as NSString
        let end = NSMaxRange(query.range)
        let space = end == source.length || source.substring(with: NSRange(location: end, length: 1)) != " " ? " " : ""
        let value = "$" + name + space
        return (source.replacingCharacters(in: query.range, with: value), NSRange(location: query.range.location + value.utf16.count, length: 0))
    }
}
