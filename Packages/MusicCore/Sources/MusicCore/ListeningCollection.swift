import Foundation

public enum ArrangementArchive {
    public static func upserting(_ value: Arrangement, into items: [Arrangement], recentLimit: Int = 10) -> [Arrangement] {
        var result = items
        if let index = result.firstIndex(where: { $0.id == value.id }) {
            var updated = value
            updated.title = result[index].title
            updated.isKept = result[index].isKept
            updated.createdAt = result[index].createdAt
            updated.originalPrompt = result[index].originalPrompt ?? value.originalPrompt
            result[index] = updated
        } else { result.insert(value, at: 0) }
        return retaining(result, recentLimit: recentLimit)
    }

    public static func retaining(_ items: [Arrangement], recentLimit: Int = 10) -> [Arrangement] {
        var seen = Set<UUID>(), recent = 0
        return items.filter {
            guard seen.insert($0.id).inserted else { return false }
            if $0.isKept == true { return true }
            recent += 1
            return recent <= max(0, recentLimit)
        }
    }
}

public enum RediscoverySelection {
    public static func make(library: [Track], lastPlayed: [Int64: Date], avoiding: Set<Int64> = [], limit: Int = 12) -> [Track] {
        guard limit > 0 else { return [] }
        var seen = Set<Int64>()
        let candidates = library.filter {
            seen.insert($0.id).inserted && $0.availability != .unavailable && $0.availability != .preview && $0.metadataPending != true
        }.sorted {
            if avoiding.contains($0.id) != avoiding.contains($1.id) { return !avoiding.contains($0.id) }
            let a = lastPlayed[$0.id] ?? .distantPast, b = lastPlayed[$1.id] ?? .distantPast
            return a == b ? $0.id < $1.id : a < b
        }
        var selected: [Track] = [], selectedIDs = Set<Int64>()
        var artists: [String: Int] = [:], albums: [String: Int] = [:]
        for diversify in [true, false] {
            for track in candidates where selected.count < limit && !selectedIDs.contains(track.id) {
                let artistKeys = track.artists.map { $0.id == 0 ? "name:\($0.name)" : "id:\($0.id)" }
                let albumKey = track.album.id == 0 ? "name:\(track.album.name):\(track.artistName)" : "id:\(track.album.id)"
                if diversify && (artistKeys.contains { artists[$0, default: 0] >= 2 } || albums[albumKey, default: 0] >= 2) { continue }
                selected.append(track); selectedIDs.insert(track.id)
                for key in artistKeys { artists[key, default: 0] += 1 }
                albums[albumKey, default: 0] += 1
            }
        }
        return selected
    }

    public static func reason(lastPlayed: Date?, now: Date = .now) -> String {
        guard let lastPlayed else { return "来自你的收藏" }
        let days = Int(max(0, now.timeIntervalSince(lastPlayed)) / 86_400)
        if days >= 30 { return "很久没有重听" }
        if days >= 7 { return "最近一周没有重听" }
        return "再听一次熟悉的旋律"
    }
}
