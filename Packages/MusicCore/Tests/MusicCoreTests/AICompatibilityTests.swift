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
