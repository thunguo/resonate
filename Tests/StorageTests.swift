import XCTest
import SwiftData
import MusicCore
@testable import Yuyin

@MainActor final class StorageTests: XCTestCase {
    private func track(_ id: Int64) -> Track { .init(id: id, title: "歌曲 \(id)", artists: [], album: .init(id: 1, name: "专辑"), duration: 180) }
    func testLegacyLibraryMigrationKeepsOriginalAndSharesTrackRecords() async throws {
        let persistence = try LocalPersistence(inMemory: true)
        let worker = BackgroundPersistence(modelContainer: persistence.container)
        let original = LibrarySnapshot(accountID: 7, likedTracks: [track(1), track(2)])
        try persistence.save(original, key: "account.7.library")
        let originalData = try XCTUnwrap(persistence.context.fetch(FetchDescriptor<StoredRecord>()).first?.data)
        let migrated = try await worker.load(LibrarySnapshot.self, key: "account.7.library")
        XCTAssertEqual(migrated?.likedTracks.map(\.id), [1, 2])
        let repository = MusicRepository(storage: worker)
        try await repository.store([track(2), track(1)], key: "account.7.cache.playlist.8")
        let reopened = MusicRepository(storage: worker)
        let cached = try await reopened.cached([Track].self, key: "account.7.cache.playlist.8")
        XCTAssertEqual(cached?.value.map(\.id), [2, 1])
        let check = ModelContext(persistence.container)
        XCTAssertEqual(try check.fetch(FetchDescriptor<StoredTrack>()).count, 2)
        let saved = try check.fetch(FetchDescriptor<StoredRecord>()).first { $0.key == "account.7.library" }
        XCTAssertEqual(saved?.data, originalData)
        try await worker.remove(prefix: "account.7.cache.")
        let library = try await worker.load(LibrarySnapshot.self, key: "account.7.library")
        XCTAssertEqual(library?.likedTracks.map(\.id), [1, 2])
    }
    func testNewerLibraryFormatCannotBeOverwrittenDuringMigration() async throws {
        let persistence = try LocalPersistence(inMemory: true)
        let data = Data(#"{"schemaVersion":999,"payload":{}}"#.utf8)
        persistence.context.insert(StoredRecord(key: "account.7.library", data: data)); try persistence.context.save()
        let worker = BackgroundPersistence(modelContainer: persistence.container)
        do { try await worker.save(LibrarySnapshot(accountID: 7, likedTracks: [track(1)]), key: "account.7.library"); XCTFail("Incompatible data must remain intact") } catch { }
        let check = ModelContext(persistence.container)
        XCTAssertEqual(try check.fetch(FetchDescriptor<StoredRecord>()).first?.data, data)
    }
    func testCacheCleanupCannotDeleteOtherAccounts() async throws {
        let persistence = try LocalPersistence(inMemory: true), songs = [track(1)]
        let worker = BackgroundPersistence(modelContainer: persistence.container), key = "account.2.cache.playlist.1"
        let cache = MusicRepository(storage: worker)
        try await cache.store(songs, key: key); try await cache.store(songs, key: "account.1.cache.playlist.1")
        try await cache.reset(removing: "account.1.")
        let second = try await cache.cached([Track].self, key: key)
        XCTAssertEqual(second?.value.map(\.id), [1])
        let first = try await cache.cached([Track].self, key: "account.1.cache.playlist.1")
        XCTAssertNil(first)
    }
    func testCheckpointDoesNotReplaceQueue() async throws {
        let persistence = try LocalPersistence(inMemory: true)
        let worker = BackgroundPersistence(modelContainer: persistence.container)
        var queue = QueueState(); queue.replace([track(1), track(2)], origin: .playlist)
        try await worker.save(queue, key: "account.7.queue")
        try await worker.save(PlaybackCheckpoint(currentID: queue.currentID, position: 42), key: "account.7.checkpoint")
        let saved = try await worker.load(QueueState.self, key: "account.7.queue")
        XCTAssertEqual(saved?.entries.map(\.track.id), [1, 2]); XCTAssertEqual(saved?.position, 0)
    }
}
