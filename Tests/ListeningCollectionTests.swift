import XCTest
import SwiftData
import MusicCore
@testable import Yuyin

private actor ListeningFixture: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(#"{"code":200,"result":[],"data":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor final class ListeningCollectionTests: XCTestCase {
    private func track(_ id: Int64) -> Track { .init(id: id, title: "歌曲 \(id)", artists: [.init(id: id, name: "音乐人")], album: .init(id: id, name: "专辑"), duration: 180, availability: .full) }
    private func store(_ persistence: LocalPersistence) -> AppStore { AppStore(persistence: persistence, music: MusicService(transport: ListeningFixture())) }
    private func result(_ id: Int64) -> Arrangement { try! ArrangementValidator.build(.init(title: "编排 \(id)", explanation: "", trackIDs: [id]), candidates: [track(id)], likedIDs: [id], intent: .init(allowDiscovery: false)) }

    func testHistoryRestoresLegacyDataAndSingleRemovalLeavesQueueAndSearch() async throws {
        let persistence = try LocalPersistence(inMemory: true)
        let old = ListeningHistory(lastPlayed: [1: Date(timeIntervalSince1970: 100)], recent: [track(1)])
        try persistence.save(old, key: "account.0.history")
        let s = store(persistence)
        await s.start()
        XCTAssertEqual(s.history.recent.map(\.id), [1]); XCTAssertEqual(s.history.lastPlayed[1], old.lastPlayed[1])
        var queue = QueueState(); queue.replace([track(2), track(3)], origin: .album); s.player.restore(queue)
        s.recordSearch("仍保留的搜索")
        s.player.onTrackPlayed?(track(4)); s.player.onTrackPlayed?(track(4))
        XCTAssertEqual(s.history.recent.map(\.id), [4, 1])
        XCTAssertTrue(s.removeHistoryTrack(4)); XCTAssertEqual(s.history.recent.map(\.id), [1])
        XCTAssertNil(s.history.lastPlayed[4]); XCTAssertEqual(s.player.queue, queue)
        XCTAssertTrue(s.clearListeningHistory()); XCTAssertEqual(s.searchHistory, ["仍保留的搜索"])
        let reloaded = store(persistence); await reloaded.start(); XCTAssertTrue(reloaded.history.recent.isEmpty)
    }

    func testArchiveRenameBookmarkAndCloudSaveSurviveReopening() throws {
        let persistence = try LocalPersistence(inMemory: true), s = store(persistence)
        var first = result(1); first.createdAt = .now
        XCTAssertTrue(s.saveArrangement(first, for: s.accountGeneration))
        XCTAssertTrue(s.keepArrangement(first.id, kept: true))
        XCTAssertTrue(s.renameArrangement(first.id, title: "回家的路"))
        for index in 2...16 { XCTAssertTrue(s.saveArrangement(result(Int64(index)), for: s.accountGeneration)) }
        first.saveConfirmed = true; first.savedPlaylist = .init(id: 7, name: "远端名字")
        XCTAssertTrue(s.saveArrangement(first, for: s.accountGeneration))
        let reopened = store(persistence)
        XCTAssertEqual(reopened.recentArrangements.count, 11)
        let saved = try XCTUnwrap(reopened.recentArrangements.first { $0.id == first.id })
        XCTAssertEqual(saved.title, "回家的路"); XCTAssertEqual(saved.isKept, true); XCTAssertEqual(saved.saveConfirmed, true)
        XCTAssertTrue(reopened.keepArrangement(first.id, kept: false)); XCTAssertEqual(reopened.recentArrangements.count, 10)
        XCTAssertTrue(reopened.recentArrangements.contains { $0.id == first.id })
        XCTAssertTrue(reopened.removeArrangement(first.id)); XCTAssertEqual(reopened.recentArrangements.count, 9)
    }

    func testIncompatibleArchiveCannotReportSuccessfulBookmarkOrDeletion() throws {
        let persistence = try LocalPersistence(inMemory: true), s = store(persistence), item = result(1)
        XCTAssertTrue(s.saveArrangement(item, for: s.accountGeneration))
        let key = "account.0.ai.arrangements"
        let record = try XCTUnwrap(persistence.context.fetch(FetchDescriptor<StoredRecord>()).first { $0.key == key })
        let original = Data(#"{"schemaVersion":999,"payload":{}}"#.utf8)
        record.data = original; try persistence.context.save()
        _ = persistence.load([Arrangement].self, key: key)
        XCTAssertFalse(s.keepArrangement(item.id, kept: true)); XCTAssertFalse(s.removeArrangement(item.id))
        XCTAssertEqual(s.recentArrangements.count, 1); XCTAssertNotEqual(s.recentArrangements[0].isKept, true)
        XCTAssertEqual(record.data, original)
    }

    func testRediscoveryStaysStableWhenSongStartsAndRefreshDoesNotTouchQueue() async throws {
        let persistence = try LocalPersistence(inMemory: true), s = store(persistence)
        try persistence.save(LibrarySnapshot(accountID: 0, likedTracks: (1...40).map { track(Int64($0)) }), key: "account.0.library")
        await s.start()
        for _ in 0..<100 where s.isRefreshingRediscoveries { try await Task.sleep(for: .milliseconds(10)) }
        let initial = s.rediscoveries.map(\.id), revision = s.libraryRevision
        XCTAssertEqual(initial.count, 12)
        s.player.onTrackPlayed?(track(initial[0]))
        XCTAssertEqual(s.rediscoveries.map(\.id), initial); XCTAssertEqual(s.libraryRevision, revision)
        var queue = QueueState(); queue.replace([track(90), track(91)], origin: .album); queue.position = 45; s.player.restore(queue)
        s.refreshRediscoverySelection()
        for _ in 0..<100 where s.isRefreshingRediscoveries { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(s.rediscoveries.count, 12)
        XCTAssertTrue(Set(s.rediscoveries.map(\.id)).isDisjoint(with: initial)); XCTAssertEqual(s.player.queue, queue)
    }

    func testAccountSwitchDiscardsHistoryAndRejectsLateArrangement() async throws {
        let persistence = try LocalPersistence(inMemory: true)
        try persistence.save(UserProfile(id: 7, name: "测试"), key: "activeProfile")
        let s = store(persistence), generation = s.accountGeneration
        s.player.onTrackPlayed?(track(1)); XCTAssertTrue(s.saveArrangement(result(1), for: generation))
        await s.logout()
        XCTAssertTrue(s.history.recent.isEmpty); XCTAssertTrue(s.recentArrangements.isEmpty)
        XCTAssertFalse(s.saveArrangement(result(2), for: generation))
    }
}

extension ListeningCollectionTests {
    func testPlaybackDuringHistoryRestoreMergesWithOlderRecords() async throws {
        let persistence = try LocalPersistence(inMemory: true)
        try persistence.save(ListeningHistory(lastPlayed: [1: Date(timeIntervalSince1970: 100)], recent: [track(1)]), key: "account.0.history")
        let s = store(persistence)
        s.player.onTrackPlayed?(track(2))
        XCTAssertTrue(s.isRestoringHistory)
        await s.start()
        XCTAssertFalse(s.isRestoringHistory)
        XCTAssertEqual(s.history.recent.map(\.id), [2, 1])
        XCTAssertEqual(s.history.lastPlayed[1], Date(timeIntervalSince1970: 100))
        XCTAssertEqual(persistence.load(ListeningHistory.self, key: "account.0.history")?.recent.map(\.id), [2, 1])
    }
}
