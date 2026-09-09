import Foundation
import Testing
@testable import MusicCore

private actor MemoryResources: ResourceStorage {
    var values: [String: Data] = [:]
    func read(_ key: String) -> Data? { values[key] }
    func write(_ data: Data, key: String) { values[key] = data }
    func remove(prefix: String) { values = values.filter { !$0.key.hasPrefix(prefix) } }
}
private actor ReadCounter {
    var calls = 0
    func fetch() async throws -> [Int] { calls += 1; try await Task.sleep(for: .milliseconds(40)); return [2] }
}

@Test func freshCacheAvoidsRepeatedRequests() async throws {
    let cache = MusicRepository(storage: MemoryResources()), counter = ReadCounter()
    for _ in 0..<5 {
        let result = try await cache.value([Int].self, key: "account.1.album.1", lifetime: 100) { try await counter.fetch() }
        #expect(result == [2])
    }
    #expect(await counter.calls == 1)
}
@Test func tenConcurrentReadsShareOneRequest() async throws {
    let cache = MusicRepository(storage: MemoryResources()), counter = ReadCounter()
    try await withThrowingTaskGroup(of: [Int].self) { group in
        for _ in 0..<10 { group.addTask { try await cache.value([Int].self, key: "account.1.album.1", lifetime: 100) { try await counter.fetch() } } }
        for try await result in group { #expect(result == [2]) }
    }
    #expect(await counter.calls == 1)
}
@Test func staleSnapshotArrivesBeforeRefresh() async throws {
    let cache = MusicRepository(storage: MemoryResources()), counter = ReadCounter()
    try await cache.store([1], key: "account.1.playlist.1", updatedAt: .distantPast)
    var iterator = cache.updates([Int].self, key: "account.1.playlist.1", lifetime: 100) { try await counter.fetch() }.makeAsyncIterator()
    #expect(try await iterator.next() == [1])
    #expect(try await iterator.next() == [2])
    #expect(try await iterator.next() == nil)
}
@Test func failedRefreshPreservesReadableSnapshot() async throws {
    let cache = MusicRepository(storage: MemoryResources())
    try await cache.store([1], key: "account.1.playlist.1", updatedAt: .distantPast)
    var received: [[Int]] = []
    do {
        for try await value in cache.updates([Int].self, key: "account.1.playlist.1", lifetime: 100, fetch: { throw MusicError.invalidResponse }) { received.append(value) }
        Issue.record("A failed refresh must remain distinguishable from a successful sync")
    } catch { #expect(error as? MusicError == .invalidResponse) }
    #expect(received == [[1]])
    #expect(try await cache.cached([Int].self, key: "account.1.playlist.1")?.value == [1])
}
@Test func invalidationRetainsContentAndRevalidates() async throws {
    let cache = MusicRepository(storage: MemoryResources()), counter = ReadCounter()
    try await cache.store([1], key: "account.1.playlist.1")
    try await cache.invalidate("account.1.playlist.1")
    #expect(try await cache.cached([Int].self, key: "account.1.playlist.1")?.value == [1])
    let fresh = try await cache.value([Int].self, key: "account.1.playlist.1", lifetime: 100) { try await counter.fetch() }
    #expect(fresh == [2]); #expect(await counter.calls == 1)
}
@Test func accountResetRejectsLateResponses() async throws {
    let storage = MemoryResources(), cache = MusicRepository(storage: MemoryResources())
    let isolated = MusicRepository(storage: storage)
    let task = Task { try await isolated.value([Int].self, key: "account.1.album.1", lifetime: 100) { try? await Task.sleep(for: .milliseconds(80)); return [1] } }
    try await Task.sleep(for: .milliseconds(15)); try await isolated.reset(removing: "account.1.")
    do { _ = try await task.value; Issue.record("A previous account response was accepted") } catch { }
    #expect(await storage.read("account.1.album.1") == nil)
    try await cache.store([2], key: "account.2.album.1")
    #expect(try await cache.cached([Int].self, key: "account.1.album.1") == nil)
}
@Test func screenCancellationDoesNotCancelAnotherReader() async throws {
    let cache = MusicRepository(storage: MemoryResources()), counter = ReadCounter()
    let first = Task { for try await _ in cache.updates([Int].self, key: "account.1.album.1", lifetime: 100, fetch: { try await counter.fetch() }) { } }
    let second = Task { try await cache.value([Int].self, key: "account.1.album.1", lifetime: 100) { try await counter.fetch() } }
    try await Task.sleep(for: .milliseconds(10)); first.cancel()
    #expect(try await second.value == [2]); #expect(await counter.calls == 1)
    #expect(try await cache.cached([Int].self, key: "account.1.album.1")?.value == [2])
}
@Test func localIndexFindsMusicBeyondFirstPage() async {
    let index = LocalMusicIndex()
    let tracks = (1...10000).map { Track(id: Int64($0), title: "歌 \($0)", artists: [.init(id: 1, name: "音乐人")], album: .init(id: 1, name: "专辑"), duration: 180) }
    await index.replace(tracks)
    #expect(await index.search("歌 10000").map(\.id) == [10000])
    #expect(await index.search("歌", limit: 8).count == 8)
    await index.replace([]); #expect(await index.search("歌").isEmpty)
}
@Test func expandedPreheatHonorsEveryDeviceBoundary() {
    let ready = PreheatConditions(wifi: true, constrained: false, lowPower: false, nominalTemperature: true, charging: false, battery: 0.8, freeBytes: 2_000_000_000, foreground: true)
    #expect(ready.allowsExpandedPreheat)
    var variants = [PreheatConditions]()
    var value = ready; value.wifi = false; variants.append(value)
    value = ready; value.constrained = true; variants.append(value)
    value = ready; value.lowPower = true; variants.append(value)
    value = ready; value.nominalTemperature = false; variants.append(value)
    value = ready; value.battery = 0.4; variants.append(value)
    value = ready; value.freeBytes = 1_000_000_000; variants.append(value)
    value = ready; value.foreground = false; variants.append(value)
    #expect(variants.allSatisfy { !$0.allowsExpandedPreheat })
    value = ready; value.charging = true; value.battery = 0.2; #expect(value.allowsExpandedPreheat)
}

private actor ProgressivePlaylistTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let value: [String: Any]
        if request.url!.path == "/playlist/detail" {
            value = ["code": 200, "playlist": ["trackCount": 405, "trackIds": (1...405).map { ["id": $0] }, "tracks": [["id": 1, "name": "歌曲1", "dt": 180000]]]]
        } else {
            let body = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody!)
            let ids = (body["ids"]?.string ?? "").split(separator: ",").compactMap { Int($0) }
            value = ["code": 200, "songs": ids.map { ["id": $0, "name": "歌曲\($0)", "dt": 180000] as [String: Any] }]
        }
        return (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
private actor PlaylistProgress {
    var snapshots: [[Track]] = []
    func append(_ tracks: [Track]) { snapshots.append(tracks) }
}
@Test func largePlaylistPublishesCompleteIdentitiesBeforeAllMetadata() async throws {
    let music = MusicService(transport: ProgressivePlaylistTransport()), progress = PlaylistProgress()
    let result = try await music.playlistTracks(1) { await progress.append($0) }
    let snapshots = await progress.snapshots
    #expect(snapshots.first?.count == 405)
    #expect(snapshots.first?.first?.metadataPending != true)
    #expect(snapshots.first?.last?.metadataPending == true)
    #expect(result.map(\.id) == Array(1...405).map(Int64.init))
    #expect(result.allSatisfy { $0.metadataPending != true && $0.duration == 180 })
}
@Test func incompleteProgressNeverBecomesFreshCache() async throws {
    let cache = MusicRepository(storage: MemoryResources())
    var snapshots: [[Int]] = []
    do {
        for try await value in cache.progressiveUpdates([Int].self, key: "account.1.playlist.1", lifetime: 100, fetch: { emit in
            await emit([1]); throw MusicError.invalidResponse
        }) { snapshots.append(value) }
    } catch { }
    #expect(snapshots == [[1]])
    #expect(try await cache.cached([Int].self, key: "account.1.playlist.1") == nil)
}
@Test func oldIndexTaskCannotRestorePreviousAccount() async {
    let index = LocalMusicIndex()
    let track = Track(id: 1, title: "旧账号", artists: [], album: .init(id: 1, name: ""), duration: 1)
    await index.replace([], revision: 2); await index.replace([track], revision: 1)
    #expect(await index.search("旧账号").isEmpty)
}
