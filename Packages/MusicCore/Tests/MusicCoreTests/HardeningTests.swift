import Foundation
import Testing
@testable import MusicCore

private func song(_ id: Int64, _ duration: Double = 300) -> Track {
    .init(id: id, title: "曲目\(id)", artists: [.init(id: id, name: "音乐人\(id)")], album: .init(id: id, name: "专辑\(id)"), duration: duration, availability: .full)
}
private func completion<T: Encodable>(_ value: T) throws -> String {
    let content = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    return String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]]), as: UTF8.self)
}
@Test func durationAndCollectionFractionAreSolvedTogether() throws {
    let tracks = (1...12).map { song(Int64($0)) }
    let result = try ArrangementValidator.build(.init(title: "四十分钟", explanation: "", trackIDs: tracks.map(\.id)), candidates: tracks, likedIDs: Set(5...12), intent: .init())
    #expect(result.duration == 2400)
    #expect(Double(result.tracks.count - result.familiarCount) / Double(result.tracks.count) <= 0.2)
    #expect(result.tracks.count == 8)
}
@Test func retainedSlotsAreIncludedInFinalDurationAndRatio() throws {
    var queue = QueueState(); queue.replace([song(1), song(2), song(3), song(4)], origin: .playlist)
    queue.position = 60; queue.entries[3].pinned = true
    let result = try ArrangementValidator.build(.init(title: "接下来", explanation: "", trackIDs: [8, 9]), candidates: [song(8), song(9)], likedIDs: [1, 2, 3, 4, 8, 9], intent: .init(durationMinutes: 20, allowDiscovery: false), context: .init(queue: queue))
    #expect(result.previewEntries?.map(\.track.id) == [1, 8, 9, 4])
    #expect(result.remainingDuration == 1140)
    #expect(result.queueSignature == queue.arrangementSignature)
    let pinnedID = queue.entries[3].id; queue.applyArrangement(result.tracks)
    #expect(queue.entries[3].id == pinnedID)
}
@Test func pinnedGapCannotIntroduceUnapprovedDiscovery() {
    var queue = QueueState(); queue.replace([song(1), song(2), song(3), song(4)], origin: .playlist); queue.entries[3].pinned = true
    #expect(throws: MusicError.self) {
        try ArrangementValidator.build(.init(title: "", explanation: "", trackIDs: [8]), candidates: [song(8)], likedIDs: [1, 4, 8], intent: .init(allowDiscovery: false), context: .init(queue: queue))
    }
}
@Test func collectionRetrievalFindsSpecificArtistBeyondFirstPage() {
    let library = (1...200).map { song(Int64($0)) }
    let chosen = CollectionRetrieval.candidates(library: library, request: "想听音乐人197", queries: [], limit: 80)
    #expect(chosen.contains { $0.id == 197 })
    #expect(chosen.count == 80)
    let previous = CollectionRetrieval.candidates(library: library, request: "换几首", queries: [], previous: [song(188)], excluded: [188], limit: 10)
    #expect(!previous.contains { $0.id == 188 })
}
@Test func collectionOnlyEmptyRequestMakesNoMusicCalls() async throws {
    let aiTransport = ReplayTransport([try completion(ListenIntent(allowDiscovery: false))])
    let musicTransport = ReplayTransport([])
    let engine = MusicIntelligence(music: .init(transport: musicTransport), provider: .init(config: .init(), secrets: .init(apiKey: "test"), transport: aiTransport))
    await #expect(throws: MusicError.self) {
        _ = try await engine.arrange(request: "只听收藏", library: [], discoveries: [song(1)], preferences: "") { _ in }
    }
    #expect(await musicTransport.requests.isEmpty)
}
@Test func refinementSendsPreviousAndExcludesReplacedSongs() async throws {
    let old = try ArrangementValidator.build(.init(title: "之前", explanation: "", trackIDs: [1, 2]), candidates: [song(1), song(2)], likedIDs: [1, 2], intent: .init(allowDiscovery: false))
    let ai = ReplayTransport([try completion(ListenIntent(durationMinutes: 5, allowDiscovery: false)), try completion(ArrangementDraft(title: "调整", explanation: "", trackIDs: [3]))])
    let music = ReplayTransport([#"{"code":200,"data":[{"id":1,"url":"https://example.com/1"},{"id":3,"url":"https://example.com/3"}]}"#])
    let engine = MusicIntelligence(music: .init(transport: music), provider: .init(config: .init(), secrets: .init(apiKey: "test"), transport: ai))
    let result = try await engine.arrange(request: "换几首", library: [song(1), song(2), song(3)], discoveries: [], preferences: "", context: .init(previous: old, excludedIDs: [2])) { _ in }
    #expect(result.tracks.map(\.id) == [3])
    let requests = await ai.requests
    let body = try JSONDecoder().decode(JSONValue.self, from: requests[1].httpBody!)
    #expect(body["messages"].array.last!["content"].string.contains("上一轮歌曲：1:曲目1、2:曲目2"))
    let candidates = await music.requests
    let request = try JSONDecoder().decode(JSONValue.self, from: candidates[0].httpBody!)
    #expect(!request["id"].string.split(separator: ",").contains("2"))
}
@Test func missingQualityNeverBecomesRequestedQuality() async throws {
    let transport = ReplayTransport([#"{"code":200,"data":[{"id":1,"code":200,"url":"https://example.com/1.mp3","expi":60}]}"#])
    let resource = try await MusicService(transport: transport).resource(1, quality: .lossless)
    #expect(resource.quality.isEmpty)
}
@Test func snapshotsReadLegacyAndRejectUnknownFutureVersions() throws {
    let legacy = LibrarySnapshot(accountID: 7, likedTracks: [song(1)])
    #expect(try SnapshotCodec.decode(LibrarySnapshot.self, from: JSONEncoder().encode(legacy)).likedTracks.count == 1)
    #expect(try SnapshotCodec.decode(LibrarySnapshot.self, from: SnapshotCodec.encode(legacy)).accountID == 7)
    let future = Data(#"{"schemaVersion":999,"payload":{"accountID":7}}"#.utf8)
    #expect(throws: (any Error).self) { try SnapshotCodec.decode(LibrarySnapshot.self, from: future) }
}
@Test func citationLinksAreLimitedToRetrievedSources() throws {
    let sources = [MusicSource(id: "track", title: "歌曲资料", text: "测试", url: URL(string: "https://music.163.com/song?id=1")!)]
    try CitationValidator.validate("资料[track]", sources: sources)
    #expect(throws: MusicError.self) { try CitationValidator.validate("编造资料[unknown]", sources: sources) }
    let text = CitationValidator.attributedText("[track] [链接](https://example.com)", sources: sources)
    #expect(text.runs.compactMap(\.link) == [sources[0].url])
}
@Test func wikiFactsExcludePersonalListeningAndComments() throws {
    let fixture = #"{"data":{"blocks":[{"bizCode":"privateListeningHistory","rnData":{"blocks":[{"blockCode":"wikiSubBlockSongInfoVo","blockInfo":{"desc":"个人首次播放秘密"}}]}},{"bizCode":"songDetailNewSongWiki","rnData":{"blocks":[{"blockCode":"wikiSubBlockSongInfoVo","blockInfo":{"desc":"词曲：公开作者"}},{"blockCode":"wikiSubBlockSongCommentVo","blockInfo":{"desc":"用户评论"}},{"blockCode":"wikiSubBlockBaseInfoVo","blockInfo":{"wikiSubElementVos":[{"title":"语种","content":"国语"},{"title":"BPM","content":"120"}]}}]}}]}}"#
    let facts = MusicFactsParser.wikiInfo(try JSONDecoder().decode(JSONValue.self, from: Data(fixture.utf8)))
    #expect(facts == ["词曲：公开作者", "语种：国语"])
}
@Test func partialSourceFailurePreservesOtherFacts() async throws {
    let transport = ReplayTransport([#"{"code":500}"#, #"{"code":200,"briefDesc":"音乐人公开介绍"}"#, #"{"code":200,"data":{"blocks":[]}}"#])
    let sources = try await MusicService(transport: transport).sources(for: song(1))
    #expect(sources.map(\.id) == ["track", "artist"])
}
@Test func partialLibraryFailureKeepsOnlyFailedCategoriesOld() async throws {
    let transport = ReplayTransport([#"{"code":200,"ids":[2]}"#, #"{"code":200,"songs":[{"id":2,"name":"新收藏"}]}"#, #"{"code":500}"#, #"{"code":200,"data":[],"more":false}"#, #"{"code":200,"data":[],"more":false}"#])
    let music = MusicService(transport: transport); await music.setCookie("fixture")
    var cached = LibrarySnapshot(accountID: 7, likedTracks: [song(1)], playlists: [.init(id: 9, name: "保留的歌单")])
    cached.syncedAt = Date(timeIntervalSince1970: 0)
    let result = try await music.library(userID: 7, cached: cached)
    #expect(result.likedTracks.map(\.id) == [2]); #expect(result.playlists.map(\.id) == [9])
    #expect(result.partialFailures?.count == 1); #expect(result.syncedAt == cached.syncedAt)
}
@Test func qwenEndpointsRestoreWorkspaceAndRegionWithoutChangingURL() {
    for region in ["cn-beijing", "ap-southeast-1"] {
        for workspace in ["", "llm-example"] {
            let endpoint = QwenEndpoint(region: region, workspace: workspace)
            #expect(QwenEndpoint(url: endpoint.baseURL) == endpoint)
        }
    }
    #expect(QwenEndpoint(url: "https://example.com/v1") == nil)
    #expect(!QwenEndpoint(workspace: "x/secret").validWorkspace)
}
@Test func reorderedPlaylistRetryDoesNotWriteAgain() async throws {
    let detail = #"{"code":200,"playlist":{"id":7,"creator":{"userId":1},"trackIds":[{"id":2},{"id":1}]}}"#
    let transport = ReplayTransport([detail, detail, #"{"code":200,"songs":[{"id":1},{"id":2}]}"#])
    let music = MusicService(transport: transport); await music.setCookie("fixture")
    try await music.reorderPlaylist(7, ids: [2, 1], expected: [1, 2], userID: 1)
    #expect(await transport.requests.count == 3)
}

@Test func missingMetadataDoesNotSilentlyRemoveTrackIdentity() async throws {
    let transport = ReplayTransport([#"{"code":200,"songs":[{"id":2,"name":"仍可读取"}]}"#])
    let tracks = try await MusicService(transport: transport).tracks(ids: [1, 2])
    #expect(tracks.map(\.id) == [1, 2]); #expect(tracks[0].availability == .unavailable)
}
@Test func truncatedPlaylistPageIsAnErrorRatherThanCompleteCollection() async throws {
    let transport = ReplayTransport([#"{"code":200,"playlist":{"trackCount":3,"trackIds":[{"id":1}]}}"#, #"{"code":200,"songs":[{"id":1}]}"#])
    await #expect(throws: MusicError.self) { _ = try await MusicService(transport: transport).playlistTracks(7) }
}

@Test func deniedPlaybackRowsNeverBecomeFullCandidates() async throws {
    let transport = ReplayTransport([#"{"code":200,"data":[{"id":1,"code":403,"url":"https://example.com/1"},{"id":2,"code":200,"url":"https://example.com/2"},{"id":3,"code":200,"url":"https://example.com/3","freeTrialInfo":{"start":0,"end":30}}]}"#])
    let tracks = try await MusicService(transport: transport).playableCandidates([song(1), song(2), song(3)])
    #expect(tracks.map(\.id) == [2])
}
