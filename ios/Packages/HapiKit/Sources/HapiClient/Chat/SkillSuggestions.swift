import Foundation
import HapiProtocol

/// Skills use the web's dollar token and name-only fuzzy ranking.
public enum SkillSuggestions {
    public struct Query: Equatable, Sendable {
        public let text: String
        public let range: NSRange
    }

    public static func query(in text: String, selection: NSRange, composing: Bool = false) -> Query? {
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
        return Query(text: String(token.dropFirst()), range: NSRange(location: start, length: end - start))
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

    public static func insert(_ name: String, text: String, query: Query) -> (String, NSRange) {
        let source = text as NSString
        let end = NSMaxRange(query.range)
        let space = end == source.length || source.substring(with: NSRange(location: end, length: 1)) != " " ? " " : ""
        let value = "$" + name + space
        return (source.replacingCharacters(in: query.range, with: value), NSRange(location: query.range.location + value.utf16.count, length: 0))
    }
}
