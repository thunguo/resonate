import Foundation
import Testing
@testable import MusicCore

private func collectionTrack(_ id: Int64) -> Track {
    .init(id: id, title: "收藏 \(id)", artists: [.init(id: id / 3, name: "音乐人 \(id / 3)")], album: .init(id: id / 2, name: "专辑 \(id / 2)"), duration: 180, availability: .full)
}
private func arrangement(_ index: Int) -> Arrangement {
    .init(title: "编排 \(index)", explanation: "", tracks: [collectionTrack(Int64(index))], likedIDs: [], intent: .init())
}

@Test func archiveKeepsBookmarksBeyondRecentLimitAndPreservesSaveState() {
    var first = arrangement(0); first.isKept = true; first.saveConfirmed = true; first.savedPlaylist = .init(id: 7, name: "网易云歌单")
    var items = [first]
    for index in 1...30 { items = ArrangementArchive.upserting(arrangement(index), into: items) }
    #expect(items.count == 11)
    #expect(items.last?.id == first.id)
    #expect(items.last?.saveConfirmed == true)
    #expect(items.last?.savedPlaylist?.id == 7)
    #expect(items.first?.title == "编排 30")
}

@Test func lateResultSaveCannotUndoLocalNameOrBookmark() {
    var original = arrangement(1); original.createdAt = Date(timeIntervalSince1970: 100); original.originalPrompt = "夜晚散步"
    var local = original; local.title = "回家的路"; local.isKept = true
    original.saveConfirmed = true
    let values = ArrangementArchive.upserting(original, into: [local])
    #expect(values.count == 1)
    #expect(values[0].title == "回家的路")
    #expect(values[0].isKept == true)
    #expect(values[0].saveConfirmed == true)
    #expect(values[0].createdAt == local.createdAt)
    #expect(values[0].originalPrompt == "夜晚散步")
}

@Test func oldArrangementDecodesWithoutInventedCreationDate() throws {
    let old = arrangement(2)
    let data = try JSONEncoder().encode(old)
    let value = try JSONDecoder().decode(Arrangement.self, from: data)
    #expect(value.createdAt == nil)
    #expect(value.isKept == nil)
    #expect(value.originalPrompt == nil)
    #expect(value.tracks == old.tracks)
}

@Test func rediscoveryIsFiniteDiverseAndDeterministic() {
    let tracks = (1...60).map { collectionTrack(Int64($0)) }
    let selection = RediscoverySelection.make(library: tracks, lastPlayed: [:])
    #expect(selection.count == 12)
    #expect(Set(selection.map(\.id)).count == 12)
    #expect(Dictionary(grouping: selection, by: { $0.artists[0].id }).values.allSatisfy { $0.count <= 2 })
    #expect(RediscoverySelection.make(library: tracks.reversed(), lastPlayed: [:]) == selection)
    let next = RediscoverySelection.make(library: tracks, lastPlayed: [:], avoiding: Set(selection.map(\.id)))
    #expect(Set(next.map(\.id)).isDisjoint(with: selection.map(\.id)))
}

@Test func rediscoveryUsesActualHistoryAndExcludesKnownRestrictions() {
    var tracks = (1...6).map { collectionTrack(Int64($0)) }
    tracks[0].availability = .unavailable; tracks[1].availability = .preview; tracks[2].metadataPending = true
    let now = Date(timeIntervalSince1970: 5_000_000)
    let selected = RediscoverySelection.make(library: tracks, lastPlayed: [4: now], limit: 3)
    #expect(selected.map(\.id) == [5, 6, 4])
    #expect(RediscoverySelection.reason(lastPlayed: nil, now: now) == "来自你的收藏")
    #expect(RediscoverySelection.reason(lastPlayed: now, now: now) == "再听一次熟悉的旋律")
    #expect(RediscoverySelection.reason(lastPlayed: now.addingTimeInterval(-40 * 86400), now: now) == "很久没有重听")
}
