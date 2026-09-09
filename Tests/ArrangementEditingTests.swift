import XCTest
import MusicCore
@testable import Yuyin

@MainActor final class ArrangementEditingTests: XCTestCase {
    private func song(_ id: Int64) -> Track { .init(id: id, title: "歌曲 \(id)", artists: [], album: .init(id: id, name: "专辑"), duration: 180, availability: .full) }
    private func original() throws -> Arrangement { try ArrangementValidator.build(.init(title: "原编排", explanation: "", trackIDs: [1, 2, 3, 4, 5]), candidates: (1...5).map { song(Int64($0)) }, likedIDs: [1, 2, 3, 4, 5], intent: .init(durationMinutes: 15, allowDiscovery: false)) }
    func testFeedbackAndRevisionPersistWithoutChangingPreferencesOrQueue() throws {
        let persistence = try LocalPersistence(inMemory: true), store = AppStore(persistence: try LocalPersistence(inMemory: true))
        let s = AppStore(persistence: persistence)
        var before = try original(); before.saveConfirmed = true; before.savedPlaylist = .init(id: 90, name: "原歌单")
        before.seedTrack = song(1); before.feedback = [.init(track: song(2), reason: .repeated)]
        var queue = QueueState(); queue.replace([song(90), song(91)], origin: .album); queue.position = 24; s.player.restore(queue)
        s.preferences.musicTaste = "已有偏好"
        XCTAssertTrue(s.saveArrangement(before, for: s.accountGeneration))
        let revised = try ArrangementPatchValidator.build(.init(replacements: [.init(originalID: 2, replacementID: 8)]), replacing: [2], in: before, candidates: [song(8)], likedIDs: [1, 3, 4, 5, 8])
        XCTAssertTrue(s.saveArrangement(revised, for: s.accountGeneration)); XCTAssertEqual(s.player.queue, queue); XCTAssertEqual(s.preferences.musicTaste, "已有偏好")
        let loaded = AppStore(persistence: persistence)
        XCTAssertEqual(loaded.recentArrangements.count, 2); XCTAssertEqual(loaded.recentArrangements.first?.feedback, before.feedback)
        XCTAssertEqual(loaded.recentArrangements.last?.saveConfirmed, true); XCTAssertNil(loaded.recentArrangements.first?.savedPlaylist)
        XCTAssertFalse(s.saveArrangement(revised, for: store.accountGeneration))
    }
    func testPatchAppliesOnlyAfterCommandAndRejectsChangedQueue() throws {
        let player = PlaybackController(music: MusicService())
        var queue = QueueState(); queue.replace((1...5).map { song(Int64($0)) }, origin: .ai); queue.entries[2].pinned = true; queue.position = 35; player.restore(queue)
        var before = try original(); before.previewEntries = queue.entries; before.tracks = [song(2), song(4), song(5)]; before.queueSignature = queue.arrangementSignature; before.expectedDuration = 865
        let revised = try ArrangementPatchValidator.build(.init(replacements: [.init(originalID: 2, replacementID: 8)]), replacing: [2], in: before, candidates: [song(8)], likedIDs: [1, 3, 4, 5, 8])
        XCTAssertEqual(player.queue, queue); XCTAssertTrue(player.apply(revised))
        XCTAssertEqual(player.queue.entries.map { $0.track.id }, [1, 8, 3, 4, 5]); XCTAssertEqual(player.queue.entries[2], queue.entries[2]); XCTAssertEqual(player.position, 35)
        player.undo(); XCTAssertEqual(player.queue, queue)
        player.enqueue([song(9)], next: true); let changed = player.queue
        XCTAssertFalse(player.apply(revised)); XCTAssertEqual(player.queue, changed)
    }
    func testRevisionKeepsOldestOriginalAndNewResultInOneArchiveWrite() throws {
        let persistence = try LocalPersistence(inMemory: true), store = AppStore(persistence: try LocalPersistence(inMemory: true))
        let s = AppStore(persistence: persistence)
        var original = try original(); original.saveConfirmed = true; original.savedPlaylist = .init(id: 90, name: "原歌单")
        XCTAssertTrue(s.saveArrangement(original, for: s.accountGeneration))
        for _ in 0..<9 { XCTAssertTrue(s.saveArrangement(try self.original(), for: s.accountGeneration)) }
        let revised = try ArrangementPatchValidator.build(.init(replacements: [.init(originalID: 2, replacementID: 8)]), replacing: [2], in: original, candidates: [song(8)], likedIDs: [1, 3, 4, 5, 8])
        XCTAssertTrue(s.saveRevision(revised, from: original, for: s.accountGeneration))
        XCTAssertEqual(s.recentArrangements.count, 10); XCTAssertEqual(s.recentArrangements.prefix(2).map(\.id), [revised.id, original.id])
        XCTAssertEqual(s.recentArrangements[1].saveConfirmed, true); XCTAssertEqual(s.recentArrangements[1].savedPlaylist?.id, 90)
        XCTAssertFalse(s.saveRevision(revised, from: original, for: store.accountGeneration))
        var modified = original; modified.feedback = [.init(track: song(3), reason: .version)]
        XCTAssertTrue(s.saveArrangement(modified, for: s.accountGeneration)); XCTAssertFalse(s.saveRevision(revised, from: original, for: s.accountGeneration))
    }

}
