import Foundation
import Testing
@testable import MusicCore

private func song(_ id: Int64, seconds: Double = 180) -> Track { .init(id: id, title: "歌曲 \(id)", artists: [.init(id: id, name: "音乐人 \(id)")], album: .init(id: id, name: "专辑 \(id)"), duration: seconds, availability: .full) }
private func arrangement() -> Arrangement { Arrangement(title: "原编排", explanation: "原说明", tracks: (1...5).map { song(Int64($0)) }, likedIDs: [1, 2, 3, 4, 5], intent: .init(durationMinutes: 15, allowDiscovery: true, discoveryFraction: 0.2)) }

@Test func localReplacementPreservesUnselectedOrderAndOriginalSave() throws {
    var original = arrangement(); original.saveConfirmed = true; original.savedPlaylist = .init(id: 80, name: "远端"); original.isKept = true
    let result = try ArrangementPatchValidator.build(.init(replacements: [.init(originalID: 2, replacementID: 8), .init(originalID: 4, replacementID: 9)]), replacing: [2, 4], in: original, candidates: [song(8), song(9, seconds: 200)], likedIDs: [1, 3, 5, 8, 9])
    #expect(result.displayedTracks.map(\.id) == [1, 8, 3, 9, 5])
    #expect(result.displayedTracks[0] == original.displayedTracks[0]); #expect(result.displayedTracks[2] == original.displayedTracks[2])
    #expect(result.id != original.id); #expect(result.savedPlaylist == nil); #expect(result.saveConfirmed == nil); #expect(result.isKept == false)
    #expect(original.saveConfirmed == true); #expect(original.tracks.map(\.id) == [1, 2, 3, 4, 5]); #expect(result.notes?.contains { $0.contains("15:20") } == true)
}
@Test func patchRejectsOutOfScopeDuplicateMissingAndExistingIDs() {
    let original = arrangement()
    let patches: [ArrangementPatch] = [
        .init(replacements: []), .init(replacements: [.init(originalID: 3, replacementID: 8)]),
        .init(replacements: [.init(originalID: 2, replacementID: 8), .init(originalID: 2, replacementID: 9)]),
        .init(replacements: [.init(originalID: 2, replacementID: 99)]), .init(replacements: [.init(originalID: 2, replacementID: 3)])
    ]
    for patch in patches { #expect(throws: MusicError.self) { try ArrangementPatchValidator.build(patch, replacing: [2], in: original, candidates: [song(8), song(9)], likedIDs: original.likedIDs) } }
    #expect(throws: MusicError.self) { try ArrangementPatchValidator.build(.init(replacements: [.init(originalID: 2, replacementID: 8), .init(originalID: 3, replacementID: 8)]), replacing: [2, 3], in: original, candidates: [song(8)], likedIDs: original.likedIDs) }
}
@Test func patchRejectsUnavailableUnknownMetadataAndInvalidDurations() {
    var preview = song(8); preview.availability = .preview
    var incomplete = song(8); incomplete.metadataPending = true
    for track in [preview, incomplete, song(8, seconds: 0), song(8, seconds: .infinity), song(8, seconds: .nan)] {
        #expect(throws: MusicError.self) { try ArrangementPatchValidator.build(.init(replacements: [.init(originalID: 2, replacementID: 8)]), replacing: [2], in: arrangement(), candidates: [track], likedIDs: [1, 3, 4, 5, 8]) }
    }
}
@Test func patchPreservesCurrentFixedEntriesSignatureAndRemainingTime() throws {
    var original = arrangement(); var queue = QueueState(); queue.replace(original.tracks, origin: .ai); queue.position = 60; queue.entries[2].pinned = true
    original.previewEntries = queue.entries; original.tracks = [song(2), song(4), song(5)]; original.queueSignature = queue.arrangementSignature; original.expectedDuration = 840
    let patch = ArrangementPatch(replacements: [.init(originalID: 2, replacementID: 8)])
    let result = try ArrangementPatchValidator.build(patch, replacing: [2], in: original, candidates: [song(8, seconds: 200)], likedIDs: [1, 3, 4, 5, 8])
    #expect(result.previewEntries?[0] == queue.entries[0]); #expect(result.previewEntries?[2] == queue.entries[2]); #expect(result.queueSignature == original.queueSignature); #expect(result.remainingDuration == 860)
    for id: Int64 in [1, 3] { #expect(throws: MusicError.self) { try ArrangementPatchValidator.build(.init(replacements: [.init(originalID: id, replacementID: 8)]), replacing: [id], in: original, candidates: [song(8)], likedIDs: [8]) } }
}
@Test func feedbackSurvivesRevisionAndNeverAllowsRejectedSongBack() throws {
    var original = arrangement(); original.seedTrack = song(1); original.feedback = [.init(track: song(9), reason: .version), .init(track: song(2), reason: .vocals)]
    #expect(throws: MusicError.self) { try ArrangementPatchValidator.build(.init(replacements: [.init(originalID: 2, replacementID: 9)]), replacing: [2], in: original, candidates: [song(9)], likedIDs: [1, 3, 4, 5, 9]) }
    #expect(throws: MusicError.self) { try ArrangementPatchValidator.build(.init(replacements: [.init(originalID: 1, replacementID: 8)]), replacing: [1], in: original, candidates: [song(8)], likedIDs: [1, 3, 4, 5, 8]) }
    let next = try ArrangementPatchValidator.build(.init(replacements: [.init(originalID: 2, replacementID: 8)]), replacing: [2], in: original, candidates: [song(8)], likedIDs: [1, 3, 4, 5, 8])
    #expect(next.feedback == original.feedback); #expect(next.seedTrack == original.seedTrack); #expect(next.notes?.contains { $0.contains("人声信息不完整") } == true)
}
@Test func replacementsRespectWholeResultDiscoveryFraction() throws {
    let original = arrangement()
    #expect(throws: MusicError.self) { try ArrangementPatchValidator.build(.init(replacements: [.init(originalID: 2, replacementID: 8), .init(originalID: 3, replacementID: 9)]), replacing: [2, 3], in: original, candidates: [song(8), song(9)], likedIDs: original.likedIDs) }
    let valid = try ArrangementPatchValidator.build(.init(replacements: [.init(originalID: 2, replacementID: 8)]), replacing: [2], in: original, candidates: [song(8)], likedIDs: original.likedIDs)
    #expect(valid.familiarCount == 4)
}
@Test func anchoredGenerationKeepsSeedFirstAndCountsItInDuration() throws {
    let tracks = (1...8).map { song(Int64($0)) }
    let result = try ArrangementValidator.build(.init(title: "起点", explanation: "", trackIDs: [8, 7, 6, 5, 4, 3, 2]), candidates: tracks, likedIDs: Set(tracks.map(\.id)), intent: .init(durationMinutes: 15, allowDiscovery: false), context: .init(seedTrack: tracks[0]))
    #expect(result.tracks.first?.id == 1); #expect(result.duration == 900); #expect(result.seedTrack?.id == 1)
}
@Test func candidateEvidenceUsesIdentityAndDoesNotTreatUnknownIDsAsRelated() throws {
    let seed = song(1); var related = song(2); related.album = seed.album
    #expect(CandidateContext.related(related, to: seed, similarIDs: [2]) == ["与起点来自同一专辑", "网易云相似歌曲结果"])
    var unknown = song(0); unknown.album.id = 0; unknown.artists = [.init(id: 0, name: "未知")]
    var other = unknown; other.id = 3
    #expect(CandidateContext.related(other, to: unknown, similarIDs: []).isEmpty)
    let candidates = CollectionRetrieval.candidates(library: [song(3), related], request: "", queries: [], seed: seed)
    #expect(candidates.first?.id == 2)
}
@Test func oldArrangementDecodesWithoutSeedOrFeedbackAndNewFieldsRoundTrip() throws {
    var original = arrangement(); let encoder = JSONEncoder()
    let old = try JSONDecoder().decode(Arrangement.self, from: encoder.encode(original))
    #expect(old.feedback == nil); #expect(old.seedTrack == nil)
    original.seedTrack = song(1); original.feedback = [.init(track: song(2), reason: .repeated)]
    let decoded = try JSONDecoder().decode(Arrangement.self, from: encoder.encode(original))
    #expect(decoded.feedback == original.feedback); #expect(decoded.seedTrack == original.seedTrack)
    #expect(ArrangementContext(feedback: decoded.feedback ?? []).excludedIDs == [2])
}

private actor EditingTransport: HTTPTransport {
    var modelCalls = 0
    var submitted = ""
    let status: Int
    let delay: Bool
    init(status: Int = 200, delay: Bool = false) { self.status = status; self.delay = delay }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
        let payload: JSONValue
        var code = 200
        if request.url!.path.contains("chat/completions") {
            modelCalls += 1; submitted = body["messages"].array.last?["content"].string ?? ""; code = status
            if delay { try await Task.sleep(for: .seconds(10)) }
            payload = .object(["choices": .array([.object(["message": .object(["content": .string(#"{"replacements":[{"originalID":2,"replacementID":8}]}"#)])])])])
        } else {
            payload = .object(["code": .number(200), "data": .array(body["id"].string.split(separator: ",").map { .object(["id": .number(Double($0)!), "url": .string("https://example.com/music.mp3"), "code": .number(200)]) })])
        }
        return (try JSONEncoder().encode(payload), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}
private func editor(_ transport: EditingTransport) -> MusicIntelligence {
    .init(music: MusicService(transport: transport), provider: AIProvider(config: .init(kind: .custom, baseURL: "https://example.com", model: "fixture"), secrets: .init(apiKey: "fixture"), transport: transport))
}
@Test func replacementPipelineUsesOneModelCallAndExcludesFeedbackCandidates() async throws {
    let transport = EditingTransport(); var original = arrangement(); original.feedback = [.init(track: song(9), reason: .version)]
    let result = try await editor(transport).replaceTracks(in: original, selected: [2], request: "时长接近", library: original.tracks + [song(8), song(9)], discoveries: [], onProgress: { _ in })
    #expect(result.tracks.map(\.id) == [1, 8, 3, 4, 5]); #expect(await transport.modelCalls == 1)
    let candidateBody = await transport.submitted.components(separatedBy: "候选：").last!
    #expect(candidateBody.contains("歌曲 8")); #expect(!candidateBody.contains("歌曲 9")); #expect(!candidateBody.contains("歌曲 1"))
}
@Test func replacementCancellationAndQuotaFailureNeverRetryOrAlterOriginal() async throws {
    let original = arrangement(), failure = EditingTransport(status: 429)
    await #expect(throws: MusicError.self) { try await editor(failure).replaceTracks(in: original, selected: [2], request: "", library: original.tracks + [song(8)], discoveries: [], onProgress: { _ in }) }
    #expect(await failure.modelCalls == 1)
    let slow = EditingTransport(delay: true)
    let task = Task { try await editor(slow).replaceTracks(in: original, selected: [2], request: "", library: original.tracks + [song(8)], discoveries: [], onProgress: { _ in }) }
    for _ in 0..<100 { if await slow.modelCalls > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await slow.modelCalls == 1); #expect(original.tracks.map(\.id) == [1, 2, 3, 4, 5])
}
@Test func repeatedQueueSongsAreProtectedFromAmbiguousReplacement() {
    var original = arrangement(); original.tracks.append(song(2))
    #expect(original.protectedTrackIDs.contains(2))
    #expect(throws: MusicError.self) { try ArrangementPatchValidator.build(.init(replacements: [.init(originalID: 2, replacementID: 8)]), replacing: [2], in: original, candidates: [song(8)], likedIDs: [1, 2, 3, 4, 5, 8]) }
}
