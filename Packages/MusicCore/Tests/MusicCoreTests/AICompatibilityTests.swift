import Foundation
import Testing
@testable import MusicCore

private struct FixtureStreamTransport: StreamingTransport {
    var status = 200
    var payload: [String]
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(payload.joined().utf8), response(request))
    }
    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        (AsyncThrowingStream { continuation in
            payload.forEach { continuation.yield($0) }; continuation.finish()
        }, response(request))
    }
    private func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
private actor TextCollector {
    var updates: [String] = []
    func append(_ value: String) { updates.append(value) }
}
private func provider(_ transport: any HTTPTransport, kind: ProviderKind = .custom) -> AIProvider {
    AIProvider(config: .init(kind: kind, baseURL: "https://example.com/v1", model: "fixture"), secrets: .init(apiKey: "fixture-key"), transport: transport)
}

@Test(arguments: ProviderKind.allCases)
func providerPresetsParseChatCompletion(kind: ProviderKind) async throws {
    let transport = FixtureStreamTransport(payload: [#"{"choices":[{"message":{"content":"连接成功"},"finish_reason":"stop"}]}"#])
    let client = provider(transport, kind: kind)
    #expect(try await client.complete([.init("user", "测试")]) == "连接成功")
    let request = try client.makeRequest(messages: [], stream: true)
    let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
    #expect(body["stream"].bool == true)
    if kind == .custom { #expect(body["thinking"].isNull); #expect(body["enable_thinking"].isNull) }
}
@Test func streamingCollectsOnlyContentAndPreservesPartialFailure() async throws {
    let updates = TextCollector()
    let transport = FixtureStreamTransport(payload: [
        #"data: {"choices":[{"delta":{"reasoning_content":"内部推理"}}]}"#,
        #"data: {"choices":[{"delta":{"content":"音乐"}}]}"#,
        #"data: {"choices":[{"delta":{"content":"导读"},"finish_reason":"stop"}]}"#,
        "data: [DONE]"
    ])
    let text = try await provider(transport).stream([]) { await updates.append($0) }
    #expect(text == "音乐导读")
    #expect(await updates.updates.last == "音乐导读")
    let incomplete = FixtureStreamTransport(payload: [#"data: {"choices":[{"delta":{"content":"已收到的一部分"}}]}"#])
    await #expect(throws: MusicError.self) { _ = try await provider(incomplete).stream([]) { await updates.append($0) } }
    #expect(await updates.updates.last == "已收到的一部分")
}
@Test func streamingAcceptsNonStreamingServersAndReportsLengthLimit() async throws {
    let response = #"{"choices":[{"message":{"content":"短导读"},"finish_reason":"stop"}]}"#
    #expect(try await provider(FixtureStreamTransport(payload: [response])).stream([]) { _ in } == "短导读")
    let truncated = response.replacingOccurrences(of: "stop", with: "length")
    await #expect(throws: MusicError.self) { _ = try await provider(FixtureStreamTransport(payload: [truncated])).stream([]) { _ in } }
}
@Test(arguments: [401, 402, 403, 404, 429, 500])
func connectionFailuresRemainExplicit(status: Int) async {
    await #expect(throws: MusicError.self) { try await provider(FixtureStreamTransport(status: status, payload: ["{}"])).testConnection() }
}
@Test func malformedStructuredResultDoesNotBecomeAPlaylist() {
    #expect(throws: (any Error).self) { try ArrangementValidator.decode(ArrangementDraft.self, from: "我觉得应该听一些温柔的歌") }
}

@Test(arguments: ProviderKind.allCases)
func everyProviderHandlesStreamingNonStreamingAndMalformedResponses(kind: ProviderKind) async throws {
    let valid = FixtureStreamTransport(payload: [#"data: {"choices":[{"delta":{"content":"导读"},"finish_reason":"stop"}]}"#, "data: [DONE]"])
    #expect(try await provider(valid, kind: kind).stream([]) { _ in } == "导读")
    let ordinary = FixtureStreamTransport(payload: [#"{"choices":[{"message":{"content":"导读"},"finish_reason":"stop"}]}"#])
    #expect(try await provider(ordinary, kind: kind).stream([]) { _ in } == "导读")
    await #expect(throws: (any Error).self) { _ = try await provider(FixtureStreamTransport(payload: ["data: {broken}"]), kind: kind).stream([]) { _ in } }
    for status in [401, 402, 429, 500] {
        await #expect(throws: MusicError.self) { _ = try await provider(FixtureStreamTransport(status: status, payload: ["{}"]), kind: kind).stream([]) { _ in } }
    }
}
@Test func streamingBatchesBurstUpdatesAndFlushesLastContentImmediately() async throws {
    let collector = TextCollector()
    var payload = (0..<100).map { _ in #"data: {"choices":[{"delta":{"content":"字"}}]}"# }
    payload.append("data: [DONE]")
    let value = try await provider(FixtureStreamTransport(payload: payload)).stream([]) { await collector.append($0) }
    let updates = await collector.updates
    #expect(value.count == 100); #expect(updates.last == value); #expect(updates.count < 10)
}
private actor CancellableFixture: StreamingTransport {
    var started = false
    var cancelled = false
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        started = true
        do { try await Task.sleep(for: .seconds(60)); throw MusicError.invalidResponse }
        catch { cancelled = true; throw error }
    }
    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        _ = try await data(for: request); throw MusicError.invalidResponse
    }
}
@Test(arguments: ProviderKind.allCases)
func explicitCancellationDoesNotRetryModelRequest(kind: ProviderKind) async throws {
    let fixture = CancellableFixture()
    let task = Task { try await provider(fixture, kind: kind).stream([]) { _ in } }
    while !(await fixture.started) { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(await fixture.cancelled)
}
@Test func changingAccountCancelsOutstandingMusicRequests() async throws {
    let fixture = CancellableFixture()
    let service = MusicService(transport: fixture); await service.setCookie("first")
    let task = Task { try await service.request("likelist", authenticated: true) }
    while !(await fixture.started) { await Task.yield() }
    await service.setCookie("second")
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(await fixture.cancelled)
}
@Test func incompleteExplanationAndSavedArrangementSurviveRoundTrip() throws {
    let guide = ExplanationRecord(trackID: 1, text: "已有导读", sources: [], history: [], draftText: "未完成", draftQuestion: "为什么？")
    let restored = try SnapshotCodec.decode(ExplanationRecord.self, from: SnapshotCodec.encode(guide))
    #expect(restored.text == "已有导读"); #expect(restored.draftText == "未完成"); #expect(restored.draftQuestion == "为什么？")
    var result = Arrangement(title: "收藏", explanation: "", tracks: [], likedIDs: [], intent: .init())
    result.savedPlaylist = .init(id: 9, name: "收藏"); result.saveConfirmed = true
    let copy = try SnapshotCodec.decode(Arrangement.self, from: SnapshotCodec.encode(result))
    #expect(copy.saveConfirmed == true); #expect(copy.savedPlaylist?.id == 9)
}
