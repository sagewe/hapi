import Foundation
import HapiProtocol

/// Skills use the web's dollar token and name-only fuzzy ranking.
public enum SkillSuggestions {
    public struct Query: Equatable, Sendable {
        public let text: String
        public let range: NSRange
    }

    public static func query(in text: String, selection: NSRange, composing: Bool = false) -> Query? {
        guard !composing, selection.length == 0, selection.location > 0 else { return nil }
        let source = text as NSString
        guard selection.location <= source.length,
              source.range(of: "$", options: .literal, range: NSRange(location: 0, length: selection.location)).location != NSNotFound
        else { return nil }
        func isWhitespace(_ unit: unichar) -> Bool {
            UnicodeScalar(unit).map { $0.properties.isWhitespace } ?? false
        }
        var start = selection.location
        while start > 0 {
            start -= 1
            let unit = source.character(at: start)
            if isWhitespace(unit) { return nil }
            guard unit == 0x24 else { continue }
            guard start == 0 || isWhitespace(source.character(at: start - 1)) else { return nil }
            var end = selection.location
            while end < source.length, !isWhitespace(source.character(at: end)) { end += 1 }
            let prefix = NSRange(location: start + 1, length: selection.location - start - 1)
            return Query(text: source.substring(with: prefix), range: NSRange(location: start, length: end - start))
        }
        return nil
    }

    public static func matches(_ skills: [SkillSummary], query: String, recent: [String: Double] = [:]) -> [SkillSummary] {
        let term = query.lowercased()
        let queryCharacters = Array(term)
        let threshold = max(2, queryCharacters.count / 2)
        func distance(to name: String) -> Int {
            let b = Array(name)
            guard abs(queryCharacters.count - b.count) <= threshold else { return Int.max }
            var previous = Array(0...b.count)
            for (i, x) in queryCharacters.enumerated() {
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
            let d = distance(to: name)
            return d <= threshold ? 3 + d : Int.max
        }
        var seen = Set<String>()
        let ranked = skills.compactMap { skill -> (skill: SkillSummary, score: Int, recent: Double)? in
            guard seen.insert(skill.name).inserted else { return nil }
            let rank = score(skill)
            guard rank != Int.max else { return nil }
            return (skill, rank, recent[skill.name, default: 0])
        }
        return ranked.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.recent != $1.recent { return $0.recent > $1.recent }
            return $0.skill.name.localizedStandardCompare($1.skill.name) == .orderedAscending
        }.map(\.skill)
    }

    public static func insert(_ name: String, text: String, query: Query) -> (String, NSRange) {
        let source = text as NSString
        let end = NSMaxRange(query.range)
        let space = end == source.length || source.substring(with: NSRange(location: end, length: 1)) != " " ? " " : ""
        let value = "$" + name + space
        return (source.replacingCharacters(in: query.range, with: value), NSRange(location: query.range.location + value.utf16.count, length: 0))
    }
}
