import XCTest
import AVFoundation
import MusicCore
@testable import Yuyin

@MainActor final class PlaybackTests: XCTestCase {
    private var audioURL: URL!
    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
        buffer.frameLength = 8000
        memset(buffer.floatChannelData![0], 0, 8000 * MemoryLayout<Float>.size)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer); audioURL = url
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: audioURL) }
    private func player() -> PlaybackController {
        let p = PlaybackController(music: MusicService())
        let url = audioURL!; p.offlineURL = { _ in url }; return p
    }
    private func track(_ id: Int64) -> Track { .init(id: id, title: "本地测试音频", artists: [], album: .init(id: 0, name: ""), duration: 1, availability: .full) }
    private func waitUntil(_ predicate: () -> Bool, timeout: Double = 8) async -> Bool {
        let limit = Date().addingTimeInterval(timeout)
        while Date() < limit { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }
    func testFinishedLastTrackCanStartAgain() async {
        let p = player(); defer { p.clear() }
        p.play([track(1)])
        let began = await waitUntil { p.isPlaying }; XCTAssertTrue(began)
        let ended = await waitUntil { !p.isPlaying && p.position > 0.8 }; XCTAssertTrue(ended)
        p.resume()
        let restarted = await waitUntil { p.isPlaying && p.position < 0.5 }; XCTAssertTrue(restarted)
    }
    func testPauseDuringPreparationPreventsAutomaticPlayback() async {
        let p = player(); defer { p.clear() }
        var plays = 0; p.onTrackPlayed = { _ in plays += 1 }
        p.play([track(1)]); p.pause()
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(p.isPlaying); XCTAssertFalse(p.isBuffering); XCTAssertEqual(plays, 0)
        p.resume(); let resumed = await waitUntil { p.isPlaying }; XCTAssertTrue(resumed)
    }
    func testActualPlaybackReportsOnceAndAdvancesAlbumOrder() async {
        let p = player(); defer { p.clear() }
        var played: [Int64] = [], starts = 0, attempts = 0
        p.onTrackPlayed = { played.append($0.id) }; p.onPlaybackStart = { _ in starts += 1 }; p.onPlaybackAttempt = { attempts += 1 }
        p.play([track(1), track(2)], origin: .album)
        let advanced = await waitUntil { played == [1, 2] }; XCTAssertTrue(advanced)
        XCTAssertEqual(starts, 2); XCTAssertEqual(attempts, 2)
    }
    func testQueueChangeRejectsStaleArrangementWithoutMutation() throws {
        let p = player(); defer { p.clear() }
        var queue = QueueState(); queue.replace([track(1), track(2)], origin: .playlist); p.restore(queue)
        let proposal = try ArrangementValidator.build(.init(title: "测试", explanation: "", trackIDs: [3]), candidates: [track(3)], likedIDs: [1, 2, 3], intent: .init(allowDiscovery: false), context: .init(queue: queue))
        p.enqueue([track(4)]); let before = p.queue
        XCTAssertFalse(p.apply(proposal)); XCTAssertEqual(p.queue, before)
    }
    func testPreparedNextRespectsInsertedTrack() async {
        let p = player(); defer { p.clear() }
        var played: [Int64] = []; p.onTrackPlayed = { played.append($0.id) }
        p.play([track(1), track(2)])
        let began = await waitUntil { p.isPlaying }; XCTAssertTrue(began)
        p.enqueue([track(3)], next: true)
        let advanced = await waitUntil { played.count >= 3 }; XCTAssertTrue(advanced)
        XCTAssertEqual(Array(played.prefix(3)), [1, 3, 2])
    }
    func testPreparedShuffleDoesNotRepeatBeforeExhaustion() async {
        let p = player(); defer { p.clear() }
        var played: [Int64] = []; p.onTrackPlayed = { played.append($0.id) }
        p.queue.shuffle = true; p.play([track(1), track(2), track(3)])
        let finished = await waitUntil { played.count == 3 }; XCTAssertTrue(finished)
        XCTAssertEqual(Set(played), [1, 2, 3])
    }
    func testPreparedRepeatAllReturnsToFirstTrack() async {
        let p = player(); defer { p.clear() }
        var played: [Int64] = []; p.onTrackPlayed = { played.append($0.id) }
        p.queue.repeatMode = .all; p.play([track(1), track(2)])
        let repeated = await waitUntil { played.count >= 3 }; XCTAssertTrue(repeated)
        XCTAssertEqual(Array(played.prefix(3)), [1, 2, 1])
    }
    func testResumeDuringRestorationKeepsCompleteQueueAndPendingAppend() async {
        let p = player(); defer { p.clear() }
        var full = QueueState(); full.replace([track(1), track(2)], origin: .playlist)
        var summary = full; summary.entries = Array(full.entries.prefix(1))
        p.restore(summary); p.restorationPending = true
        p.resume(); p.enqueue([track(3)], next: true)
        XCTAssertFalse(p.isPlaying)
        p.finishRestoration(full)
        let began = await waitUntil { p.isPlaying }; XCTAssertTrue(began)
        XCTAssertEqual(p.queue.entries.map(\.track.id), [1, 3, 2])
    }
    func testLegacyPreferencesAddSortDefaults() throws {
        let data = Data(#"{"musicTaste":"纯音乐","pinnedPlaylists":[],"quality":"exhigh","wifiOnly":true,"appearance":"system"}"#.utf8)
        let preferences = try JSONDecoder().decode(UserPreferences.self, from: data)
        XCTAssertTrue(preferences.librarySort.isEmpty); XCTAssertEqual(preferences.musicTaste, "纯音乐")
    }
}

private actor CreationFixtureTransport: HTTPTransport {
    var calls = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        let content = request.url!.path.hasSuffix("playlist/create") ? #"{"code":200,"playlist":{"id":9,"name":"新歌单","creator":{"userId":7}}}"# : #"{"code":200,"playlist":[],"more":false}"#
        return (Data(content.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
extension PlaybackTests {
    func testConfirmedCreationSurvivesLocalPersistenceFailure() async throws {
        let persistence = try LocalPersistence(inMemory: true)
        let originalData = Data(#"{"schemaVersion":999,"payload":{}}"#.utf8)
        persistence.context.insert(StoredRecord(key: "account.7.library", data: originalData)); try persistence.context.save()
        XCTAssertNil(persistence.load(LibrarySnapshot.self, key: "account.7.library"))
        let transport = CreationFixtureTransport()
        let service = MusicService(transport: transport); await service.setCookie("fixture")
        let store = AppStore(persistence: persistence, music: service); store.profile = .init(id: 7, name: "测试账户")
        let created = try await store.createPlaylistNamed("新歌单")
        XCTAssertEqual(created.id, 9); XCTAssertNil(store.pendingCreation)
        let calls = await transport.calls; XCTAssertEqual(calls, 2)
        XCTAssertTrue(persistence.blockedKeys.contains("account.7.library"))
    }
}
