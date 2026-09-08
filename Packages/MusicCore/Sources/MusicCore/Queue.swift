import Foundation

public enum QueueOrigin: String, Codable, Sendable { case album, playlist, search, ai, manual }
public struct QueueEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var track: Track
    public var origin: QueueOrigin
    public var pinned: Bool
    public init(id: UUID = UUID(), track: Track, origin: QueueOrigin, pinned: Bool = false) { self.id = id; self.track = track; self.origin = origin; self.pinned = pinned }
}
public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one
    public var label: String { switch self { case .off: return "循环关闭"; case .all: return "列表循环"; case .one: return "单曲循环" } }
}
public struct QueueState: Codable, Equatable, Sendable {
    public var entries: [QueueEntry] = []
    public var currentID: UUID?
    public var position: Double = 0
    public var repeatMode: RepeatMode = .off
    public var shuffle = false
    public var autoplay = false
    public var shuffleVisited: Set<UUID> = []
    public var navigationHistory: [UUID] = []
    public init() {}
    public var arrangementSignature: String { ([currentID?.uuidString ?? ""] + upcoming.map { "\($0.id.uuidString):\($0.pinned)" }).joined(separator: "|") }
    public var currentIndex: Int? { entries.firstIndex { $0.id == currentID } }
    public var current: QueueEntry? { currentIndex.map { entries[$0] } }
    public var upcoming: [QueueEntry] { guard let i = currentIndex else { return entries }; return Array(entries.dropFirst(i + 1)) }
    public mutating func replace(_ tracks: [Track], startingAt index: Int = 0, origin: QueueOrigin) {
        entries = tracks.map { QueueEntry(track: $0, origin: origin) }
        currentID = entries.indices.contains(index) ? entries[index].id : entries.first?.id
        position = 0
        shuffleVisited = []; navigationHistory = []
    }
    public mutating func append(_ tracks: [Track], next: Bool = false, origin: QueueOrigin = .manual) {
        let additions = tracks.map { QueueEntry(track: $0, origin: origin, pinned: origin == .manual) }
        if next, let i = currentIndex { entries.insert(contentsOf: additions, at: i + 1) } else { entries.append(contentsOf: additions) }
        if currentID == nil { currentID = entries.first?.id }
    }
    public mutating func applyArrangement(_ tracks: [Track]) {
        guard let index = currentIndex else { replace(tracks, origin: .ai); return }
        let pinnedIDs = Set(upcoming.filter(\.pinned).map { $0.track.id })
        var replacements = tracks.filter { !pinnedIDs.contains($0.id) && $0.id != current?.track.id }.map { QueueEntry(track: $0, origin: .ai) }
        var tail: [QueueEntry] = []
        let lastPinnedIndex = upcoming.lastIndex { $0.pinned } ?? -1
        for (offset, entry) in upcoming.enumerated() {
            if entry.pinned { tail.append(entry) }
            else if !replacements.isEmpty { tail.append(replacements.removeFirst()) }
            else if offset < lastPinnedIndex { tail.append(entry) }
        }
        tail.append(contentsOf: replacements)
        entries = Array(entries.prefix(index + 1)) + tail
    }
    @discardableResult public mutating func advance(manual: Bool = false) -> Bool {
        guard let i = currentIndex else { return false }
        if repeatMode == .one && !manual { position = 0; return true }
        if shuffle, entries.count > 1 {
            if let currentID { shuffleVisited.insert(currentID) }
            var choices = entries.filter { !shuffleVisited.contains($0.id) }
            if choices.isEmpty && repeatMode == .all { shuffleVisited = Set([currentID].compactMap { $0 }); choices = entries.filter { $0.id != currentID } }
            guard let next = choices.randomElement() else { return false }
            if let currentID { navigationHistory.append(currentID) }
            currentID = next.id; position = 0; return true
        }
        if i + 1 < entries.count { currentID = entries[i + 1].id; position = 0; return true }
        if repeatMode == .all { currentID = entries.first?.id; position = 0; return true }
        return false
    }
    public mutating func previous() {
        guard let i = currentIndex else { return }
        if position > 3 { position = 0; return }
        if shuffle, let previous = navigationHistory.popLast(), entries.contains(where: { $0.id == previous }) { if let currentID { shuffleVisited.remove(currentID) }; currentID = previous; position = 0; return }
        currentID = entries[max(0, i - 1)].id; position = 0
    }
    public mutating func remove(_ id: UUID) { guard id != currentID else { return }; entries.removeAll { $0.id == id } }
    public mutating func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        var tail = upcoming
        let moving = offsets.sorted().compactMap { tail.indices.contains($0) ? tail[$0] : nil }
        for i in offsets.sorted(by: >) where tail.indices.contains(i) { tail.remove(at: i) }
        let adjusted = max(0, min(tail.count, destination - offsets.filter { $0 < destination }.count))
        tail.insert(contentsOf: moving.map { var e = $0; e.pinned = true; return e }, at: adjusted)
        let prefix = currentIndex.map { Array(entries.prefix($0 + 1)) } ?? []
        entries = prefix + tail
    }
}
