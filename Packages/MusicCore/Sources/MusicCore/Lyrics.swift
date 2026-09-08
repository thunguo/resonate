import Foundation
public struct LyricWord: Codable, Equatable, Sendable { public var text: String; public var start: Double; public var duration: Double }
public struct LyricLine: Identifiable, Codable, Equatable, Sendable {
    public var id: Int
    public var start: Double?
    public var text: String
    public var words: [LyricWord]
}
public enum LyricsParser {
    public static func parse(yrc: String?, lrc: String?, plain: String? = nil) -> [LyricLine] {
        if let yrc, !yrc.isEmpty {
            let rows = parseYRC(yrc)
            if !rows.isEmpty { return rows }
        }
        if let lrc, !lrc.isEmpty {
            let rows = parseLRC(lrc)
            if !rows.isEmpty { return rows }
        }
        return (plain ?? lrc ?? "").components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("[") }.enumerated().map { LyricLine(id: $0.offset, start: nil, text: $0.element, words: []) }
    }
    static func parseLRC(_ text: String) -> [LyricLine] {
        let re = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        let offsetRE = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#)
        let offsetMatch = offsetRE.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        let offset = offsetMatch.flatMap { Range($0.range(at: 1), in: text) }.flatMap { Double(text[$0]) }.map { $0 / 1000 } ?? 0
        var lines: [LyricLine] = []
        for row in text.components(separatedBy: .newlines) {
            let matches = re.matches(in: row, range: NSRange(row.startIndex..., in: row))
            guard let last = matches.last, let end = Range(last.range, in: row)?.upperBound else { continue }
            let content = String(row[end...]).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            for match in matches {
                let minutes = Double((row as NSString).substring(with: match.range(at: 1))) ?? 0
                let seconds = Double((row as NSString).substring(with: match.range(at: 2))) ?? 0
                lines.append(.init(id: lines.count, start: max(0, minutes * 60 + seconds + offset), text: content, words: []))
            }
        }
        return lines.sorted { ($0.start ?? 0) < ($1.start ?? 0) }.enumerated().map { var l = $0.element; l.id = $0.offset; return l }
    }
    static func parseYRC(_ text: String) -> [LyricLine] {
        let lineRE = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
        let wordRE = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)([^\(]*)"#)
        var result: [LyricLine] = []
        for row in text.components(separatedBy: .newlines) {
            guard let match = lineRE.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)) else { continue }
            let ns = row as NSString
            let start = (Double(ns.substring(with: match.range(at: 1))) ?? 0) / 1000
            let body = ns.substring(with: match.range(at: 3))
            let words = wordRE.matches(in: body, range: NSRange(body.startIndex..., in: body)).map { m in
                LyricWord(text: (body as NSString).substring(with: m.range(at: 3)), start: (Double((body as NSString).substring(with: m.range(at: 1))) ?? 0) / 1000, duration: (Double((body as NSString).substring(with: m.range(at: 2))) ?? 0) / 1000)
            }
            if !words.isEmpty { result.append(.init(id: result.count, start: start, text: words.map(\.text).joined(), words: words)) }
        }
        return result
    }
    public static func activeIndex(_ lines: [LyricLine], time: Double) -> Int? { lines.lastIndex { ($0.start ?? .infinity) <= time } }
}
