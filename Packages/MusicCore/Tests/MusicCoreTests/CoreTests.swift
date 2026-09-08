import Foundation
import Testing
@testable import MusicCore

private func track(_ id: Int64, seconds: Double = 180, availability: Availability = .full) -> Track {
    Track(id: id, title: "歌曲\(id)", artists: [.init(id: 1, name: "音乐人")], album: .init(id: 1, name: "专辑"), duration: seconds, availability: availability)
}
@Test func queuePreservesPlayingAndManualPositions() {
    var q = QueueState(); q.replace([track(1), track(2), track(3), track(4)], origin: .playlist)
    q.entries[2].pinned = true; q.position = 42
    let playingID = q.currentID
    q.applyArrangement([track(8), track(9), track(3), track(1)])
    #expect(q.entries.map(\.track.id) == [1, 8, 3, 9])
    #expect(q.currentID == playingID); #expect(q.position == 42)
}
@Test func queueDuplicatesHaveIndependentIdentity() {
    var q = QueueState(); q.replace([track(1), track(1)], origin: .album)
    #expect(q.entries[0].id != q.entries[1].id)
    q.remove(q.currentID!); #expect(q.entries.count == 2)
    let advanced = q.advance(); let reachedEnd = !q.advance()
    #expect(advanced); #expect(reachedEnd)
    q.repeatMode = .all; let wrapped = q.advance(); #expect(wrapped)
}
@Test func shortArrangementDoesNotPullPinnedTracksForward() {
    var q = QueueState(); q.replace([track(1), track(2), track(3), track(4)], origin: .playlist)
    q.entries[3].pinned = true; let pinned = q.entries[3].id
    q.applyArrangement([track(8)])
    #expect(q.entries.map(\.track.id) == [1, 8, 3, 4]); #expect(q.entries[3].id == pinned)
}
@Test func shuffleStopsAfterEveryEntryOnceWhenRepeatIsOff() {
    var q = QueueState(); q.replace([track(1), track(2), track(3)], origin: .playlist); q.shuffle = true
    var visited: [Int64] = [q.current!.track.id]
    while q.advance() { visited.append(q.current!.track.id) }
    #expect(visited.count == 3); #expect(Set(visited).count == 3)
}
@Test func discoveryFractionIsEnforcedAfterSelection() throws {
    let tracks = (1...10).map { track(Int64($0), seconds: 300) }
    let result = try ArrangementValidator.build(.init(title: "test", explanation: "", trackIDs: tracks.map(\.id)), candidates: tracks, likedIDs: [1, 2, 3, 4], intent: .init(durationMinutes: 60, discoveryFraction: 0.2))
    #expect(result.tracks.count == 5); #expect(result.familiarCount == 4)
}
@Test func emptyCollectionOnlyResultFailsCleanly() {
    #expect(throws: MusicError.self) { try ArrangementValidator.build(.init(title: "test", explanation: "", trackIDs: [2]), candidates: [track(2)], likedIDs: [1], intent: .init(allowDiscovery: false)) }
}
@Test func manualNextOverridesSingleRepeat() {
    var q = QueueState(); q.replace([track(1), track(2)], origin: .album); q.repeatMode = .one
    let repeated = q.advance(); #expect(repeated); #expect(q.current?.track.id == 1)
    let skipped = q.advance(manual: true); #expect(skipped); #expect(q.current?.track.id == 2)
}
@Test func movePinsOnlyMovedEntries() {
    var q = QueueState(); q.replace([track(1), track(2), track(3), track(4)], origin: .playlist)
    q.moveUpcoming(from: IndexSet(integer: 2), to: 0)
    #expect(q.entries.map(\.track.id) == [1, 4, 2, 3]); #expect(q.entries[1].pinned)
}
@Test func lyricsHandleMultipleTimestampsOffsetAndMetadata() {
    let lyrics = LyricsParser.parse(yrc: nil, lrc: "[ar:作者]\n[offset:500]\n[00:01.00][00:04.25]同一句\n[00:03]另一句")
    #expect(lyrics.map(\.start) == [1.5, 3.5, 4.75])
    #expect(LyricsParser.activeIndex(lyrics, time: 4) == 1)
    #expect(LyricsParser.activeIndex(lyrics, time: 0) == nil)
}
@Test func lyricsYRCAndFallback() {
    let yrc = LyricsParser.parse(yrc: "{\"t\":0}\n[1000,1500](1000,500,0)你(1500,1000,0)好", lrc: "[00:01]备用")
    #expect(yrc.first?.text == "你好"); #expect(yrc.first?.words[1].start == 1.5)
    #expect(LyricsParser.parse(yrc: "invalid", lrc: "[00:02]备用").first?.text == "备用")
    #expect(LyricsParser.parse(yrc: nil, lrc: "纯文本").first?.start == nil)
}
@Test func arrangementRejectsHallucinatedIDs() {
    #expect(throws: MusicError.self) { try ArrangementValidator.build(.init(title: "夜晚", explanation: "", trackIDs: [99]), candidates: [track(1)], likedIDs: [1], intent: .init()) }
}
@Test func arrangementExcludesTrialsAndDuplicates() throws {
    let a = try ArrangementValidator.build(.init(title: "夜晚", explanation: "", trackIDs: [1, 1, 2, 3]), candidates: [track(1), track(2, availability: .preview), track(3)], likedIDs: [1, 3], intent: .init(allowDiscovery: false))
    #expect(a.tracks.map(\.id) == [1, 3])
}
@Test func arrangementEnforcesCollectionOnly() throws {
    let a = try ArrangementValidator.build(.init(title: "夜晚", explanation: "", trackIDs: [1, 2]), candidates: [track(1), track(2)], likedIDs: [1], intent: .init(allowDiscovery: false))
    #expect(a.tracks.map(\.id) == [1])
}
@Test func modelConfigurationDoesNotLeakSecretsIntoURL() throws {
    let config = AIProviderConfig(kind: .custom, baseURL: "https://example.com/v1", model: "model")
    let p = AIProvider(config: config, secrets: .init(apiKey: "private-key"))
    let r = try p.makeRequest(messages: [.init("user", "你好")])
    #expect(r.url?.absoluteString == "https://example.com/v1/chat/completions")
    #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer private-key")
    #expect(r.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(!String(decoding: r.httpBody!, as: UTF8.self).contains("private-key"))
    #expect(throws: MusicError.self) { try AIProviderConfig(kind: .custom, baseURL: "http://example.com", model: "m").endpoint("models") }
    #expect(throws: MusicError.self) { try AIProviderConfig(kind: .custom, baseURL: "https://example.com?key=secret", model: "m").endpoint("models") }
}
@Test func customHeadersCannotReplaceCredentials() {
    let p = AIProvider(config: .init(), secrets: .init(apiKey: "key", headers: ["Cookie": "music-secret"]))
    #expect(throws: MusicError.self) { try p.makeRequest(messages: []) }
}
@Test func resourceMappingsSupportSearchAndDetailShapes() throws {
    let data = Data(#"{"id":12,"name":"名字","duration":240000,"artists":[{"id":1,"name":"作者"}],"album":{"id":3,"name":"专辑","picUrl":"http://p1.music.126.net/a.jpg"}}"#.utf8)
    let t = Track(json: try JSONDecoder().decode(JSONValue.self, from: data))
    #expect(t.duration == 240); #expect(t.artistName == "作者"); #expect(t.album.artwork?.scheme == "https")
}
actor ReplayTransport: HTTPTransport {
    var responses: [Data]; var requests: [URLRequest] = []
    init(_ responses: [String]) { self.responses = responses.map { Data($0.utf8) } }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw MusicError.invalidResponse }
        return (responses.removeFirst(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@Test func authenticatedRequestsAreIsolatedAndSecretsStayInBody() async throws {
    let transport = ReplayTransport(["{\"code\":200}", "{\"code\":200}"])
    let api = MusicService(transport: transport)
    await api.setCookie("MUSIC_U=private")
    _ = try await api.request("user/playlist", authenticated: true)
    _ = try await api.request("user/playlist", authenticated: true)
    let requests = await transport.requests
    #expect(requests[0].httpMethod == "POST"); #expect(requests[0].url != requests[1].url)
    #expect(!requests[0].url!.absoluteString.contains("private"))
    #expect(String(decoding: requests[0].httpBody!, as: UTF8.self).contains("MUSIC_U=private"))
}
@Test func playlistUsesAllTrackIDsInsteadOfTruncatedTracks() async throws {
    let transport = ReplayTransport([
        #"{"code":200,"playlist":{"trackIds":[{"id":1},{"id":2}],"tracks":[{"id":1}]}}"#,
        #"{"code":200,"songs":[{"id":2,"name":"二"},{"id":1,"name":"一"}]}"#
    ])
    let api = MusicService(transport: transport)
    let tracks = try await api.playlistTracks(12)
    #expect(tracks.map(\.id) == [1, 2])
}
@Test func previewResourceIsNotFullSong() async throws {
    let transport = ReplayTransport([#"{"code":200,"data":[{"id":1,"code":200,"url":"https://example.com/song.mp3","freeTrialInfo":{"start":30,"end":60},"expi":300,"level":"standard"}]}"#])
    let api = MusicService(transport: transport)
    let r = try await api.resource(1)
    #expect(r.availability == .preview); #expect(r.previewEnd == 60)
}
