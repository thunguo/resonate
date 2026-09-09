import XCTest
import MusicCore
@testable import Yuyin

private actor LikeFixture: HTTPTransport {
    var liked = false
    var writes: [Bool] = []
    var fail = false
    func setFailure(_ value: Bool) { fail = value }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
        let json: String
        if request.url!.path.hasSuffix("/likelist") { json = liked ? #"{"code":200,"ids":[1]}"# : #"{"code":200,"ids":[]}"# }
        else if request.url!.path.hasSuffix("/like") {
            let intent = body["like"].bool; writes.append(intent)
            try await Task.sleep(for: .milliseconds(120))
            if fail { throw URLError(.timedOut) }
            liked = intent; json = #"{"code":200}"#
        } else { json = #"{"code":200,"result":[],"data":[]}"# }
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor final class MutationTests: XCTestCase {
    private func track() -> Track { .init(id: 1, title: "收藏测试", artists: [], album: .init(id: 0, name: ""), duration: 180) }
    private func store(_ fixture: LikeFixture) async throws -> AppStore {
        let music = MusicService(transport: fixture); await music.setCookie("fixture")
        let store = AppStore(persistence: try LocalPersistence(inMemory: true), music: music)
        store.profile = .init(id: 7, name: "测试"); return store
    }
    func testLikeCanBeReversedWhileFirstWriteIsInFlight() async throws {
        let fixture = LikeFixture()
        let target = try await self.store(fixture)
        let task = Task { await target.toggleLike(track()) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(target.likedIDs.contains(1))
        await target.toggleLike(track())
        XCTAssertFalse(target.likedIDs.contains(1))
        await task.value
        let writes = await fixture.writes; XCTAssertEqual(writes, [true, false])
        XCTAssertTrue(target.pendingMutations.isEmpty); XCTAssertFalse(target.likedIDs.contains(1)); XCTAssertTrue(target.library.likedTracks.isEmpty)
    }
    func testRapidLikeCoalescesFinalIntentAndFailureRemainsPending() async throws {
        let fixture = LikeFixture()
        let store = try await self.store(fixture)
        let task = Task { await store.toggleLike(track()) }
        try await Task.sleep(for: .milliseconds(30)); await store.toggleLike(track()); await store.toggleLike(track())
        await task.value
        let writes = await fixture.writes; XCTAssertEqual(writes, [true]); XCTAssertTrue(store.likedIDs.contains(1)); XCTAssertTrue(store.pendingMutations.isEmpty)
        await fixture.setFailure(true); await store.toggleLike(track())
        XCTAssertFalse(store.likedIDs.contains(1)); XCTAssertEqual(store.pendingMutations.count, 1)
        XCTAssertEqual(store.library.likedTracks.map(\.id), [1]); XCTAssertNotEqual(store.pendingMutations.first?.status, "正在同步")
    }
    func testOldMutationFieldsDecodeWithoutOverwritingRecord() throws {
        let data = Data(#"{"id":"36AC7AB6-2D46-435E-97B0-A35A881CB5E2","accountID":7,"kind":"like","trackIDs":[1],"targetID":1,"liked":true,"status":"等待同步"}"#.utf8)
        let mutation = try JSONDecoder().decode(PendingMutation.self, from: data)
        XCTAssertNil(mutation.operationVersion); XCTAssertEqual(mutation.liked, true); XCTAssertNil(mutation.track)
    }
}
