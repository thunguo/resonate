import Foundation

public struct ArrangementContext: Sendable {
    public var previous: Arrangement?
    public var queue: QueueState?
    public var excludedIDs: Set<Int64>
    public var seedTrack: Track?
    public var feedback: [ArrangementFeedback]
    public init(previous: Arrangement? = nil, queue: QueueState? = nil, excludedIDs: Set<Int64> = [], seedTrack: Track? = nil, feedback: [ArrangementFeedback] = []) {
        self.previous = previous; self.queue = queue; self.excludedIDs = excludedIDs.union(feedback.map(\.trackID)); self.seedTrack = seedTrack; self.feedback = feedback
    }
    public var retained: [QueueEntry] {
        guard let queue else { return [] }
        return [queue.current].compactMap { $0 } + queue.upcoming.filter(\.pinned)
    }
    public var reservedDuration: Double {
        max(0, retained.reduce(0) { $0 + $1.track.duration } - (queue?.position ?? 0))
    }
}

public enum CollectionRetrieval {
    public static func candidates(library: [Track], request: String, queries: [String], previous: [Track] = [], excluded: Set<Int64> = [], limit: Int = 80, seed: Track? = nil) -> [Track] {
        let request = request.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let terms = queries.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }.filter { !$0.isEmpty }
        let previousIDs = Set(previous.map(\.id))
        let eligible = library.enumerated().filter { !excluded.contains($0.element.id) }
        let scored: [(Track, Int, Int)] = eligible.map { pair in
            let (index, track) = pair
            let title = track.title.lowercased(), album = track.album.name.lowercased(), artist = track.artistName.lowercased()
            var score = previousIDs.contains(track.id) ? 20 : 0
            score += CandidateContext.related(track, to: seed, similarIDs: []).count * 90
            if title.count >= 2 && request.contains(title) { score += 120 }
            for person in track.artists where person.name.count >= 2 && request.contains(person.name.lowercased()) { score += 100 }
            if album.count >= 2 && request.contains(album) { score += 70 }
            for term in terms {
                if title.contains(term) { score += 80 }
                if artist.contains(term) { score += 70 }
                if album.contains(term) { score += 50 }
            }
            return (track, score, index)
        }
        let ranked = scored.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }
        var result: [Track] = ranked.filter { $0.1 > 0 }.prefix(limit).map { $0.0 }
        var seen = Set(result.map(\.id)), artists = Set(result.flatMap { $0.artists.map(\.id) })
        // Explicit matches come first; remaining slots first cover distinct artists.
        for (track, _, _) in ranked where result.count < limit && !seen.contains(track.id) {
            if track.artists.isEmpty || track.artists.contains(where: { !artists.contains($0.id) }) {
                result.append(track); seen.insert(track.id); artists.formUnion(track.artists.map(\.id))
            }
        }
        for (track, _, _) in ranked where result.count < limit && seen.insert(track.id).inserted { result.append(track) }
        return result
    }
    public static func reason(for track: Track, library: [Track]) -> String? {
        let liked = library.filter { $0.id != track.id }
        if liked.contains(where: { $0.album.id > 0 && $0.album.id == track.album.id }) { return "来自你收藏过的专辑" }
        let artists = Set(liked.flatMap { $0.artists.map(\.id) })
        if let artist = track.artists.first(where: { $0.id > 0 && artists.contains($0.id) }) { return "你收藏过\(artist.name)的音乐" }
        return nil
    }
}

public enum CitationValidator {
    public static func validate(_ text: String, sources: [MusicSource]) throws {
        let expression = try NSRegularExpression(pattern: #"\[([A-Za-z][A-Za-z0-9_-]*)\]"#)
        let allowed = Set(sources.map(\.id)), range = NSRange(text.startIndex..., in: text)
        for match in expression.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            guard allowed.contains(String(text[r])) else { throw MusicError.message("导读引用了未取得的资料，已保留文字，请结合来源核对后重试。") }
        }
    }
    public static func attributedText(_ text: String, sources: [MusicSource]) -> AttributedString {
        guard let regex = try? NSRegularExpression(pattern: #"\[([A-Za-z][A-Za-z0-9_-]*)\]"#) else { return AttributedString(text) }
        var result = AttributedString(), position = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let idRange = Range(match.range(at: 1), in: text) else { continue }
            result.append(AttributedString(String(text[position..<whole.lowerBound])))
            if let source = sources.first(where: { $0.id == text[idRange] }) {
                var link = AttributedString("[" + source.title + "]"); link.link = source.url; result.append(link)
            } else { result.append(AttributedString(String(text[whole]))) }
            position = whole.upperBound
        }
        result.append(AttributedString(String(text[position...])))
        return result
    }
    public static func linkedText(_ text: String, sources: [MusicSource]) -> String {
        var result = text
        for source in sources { result = result.replacingOccurrences(of: "[\(source.id)]", with: "[\(source.title)](\(source.url.absoluteString))") }
        return result
    }
}
