import XCTest
import MusicCore
@testable import Yuyin

private actor EmptyMusicFixture: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(#"{"code":200,"result":[],"data":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor final class DeepLinkTests: XCTestCase {
    func testColdGuestResumeWaitsForLocalRestoreThenOffersLogin() async throws {
        let store = AppStore(persistence: try LocalPersistence(inMemory: true), music: MusicService(transport: EmptyMusicFixture()))
        store.handleURL(URL(string: "yuyin://resume")!)
        XCTAssertFalse(store.showLogin)
        await store.start()
        XCTAssertTrue(store.showLogin); XCTAssertFalse(store.showPlayer); XCTAssertEqual(store.selectedTab, 1)
        XCTAssertEqual(store.player.snapshot.phase, .idle)
    }
    func testLogoutFinishesGuestRestorationAndDiscardsPendingLink() async throws {
        let store = AppStore(persistence: try LocalPersistence(inMemory: true), music: MusicService(transport: EmptyMusicFixture()))
        let formerGeneration = store.accountGeneration
        let track = Track(id: 1, title: "测试", artists: [], album: .init(id: 0, name: ""), duration: 180, availability: .full)
        let result = try ArrangementValidator.build(.init(title: "测试", explanation: "", trackIDs: [1]), candidates: [track], likedIDs: [1], intent: .init(allowDiscovery: false))
        store.handleURL(URL(string: "yuyin://playlist?id=123")!)
        await store.logout()
        XCTAssertFalse(store.saveArrangement(result, for: formerGeneration)); XCTAssertTrue(store.recentArrangements.isEmpty)
        XCTAssertFalse(store.player.restorationPending); XCTAssertNil(store.player.current)
        XCTAssertFalse(store.showLogin); XCTAssertFalse(store.showPlayer)
        store.handleURL(URL(string: "yuyin://resume")!)
        XCTAssertTrue(store.showLogin)
    }
    func testColdEmptyLibraryOpensLibraryWithoutFalsePlayback() async throws {
        let persistence = try LocalPersistence(inMemory: true)
        try persistence.save(UserProfile(id: 7, name: "测试"), key: "activeProfile")
        let store = AppStore(persistence: persistence, music: MusicService(transport: EmptyMusicFixture()))
        store.handleURL(URL(string: "yuyin://resume")!)
        await store.start()
        XCTAssertEqual(store.selectedTab, 1); XCTAssertFalse(store.showPlayer); XCTAssertFalse(store.showLogin)
        XCTAssertEqual(store.player.snapshot.phase, .idle); XCTAssertNotNil(store.notice)
    }
}
