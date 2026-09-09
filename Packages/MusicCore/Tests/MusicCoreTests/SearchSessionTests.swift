import Testing
@testable import MusicCore

private func searchPage(_ ids: [Int64], more: Bool = true) -> SearchResult {
    var result = SearchResult(); result.tracks = ids.map { Track(id: $0, title: "歌曲", artists: [], album: .init(id: 1, name: ""), duration: 180) }; result.hasMore = more; return result
}
@Test func searchCategoriesAndAccountsHaveIndependentPages() {
    let tracks = SearchSessionKey(account: 1, query: " 雨 ", kind: .tracks)
    let albums = SearchSessionKey(account: 1, query: "雨", kind: .albums)
    var sessions: [SearchSessionKey: SearchSession] = [:]
    sessions[tracks, default: .init()].accept(searchPage([1]), offset: 0)
    sessions[tracks, default: .init()].accept(searchPage([2]), offset: 30)
    #expect(sessions[tracks]?.nextOffset == 60)
    #expect(sessions[albums] == nil)
    #expect(sessions[.init(account: 2, query: "雨", kind: .tracks)] == nil)
    #expect(tracks.query == "雨")
}
@Test func failedSearchPageRetriesSameOffsetAndKeepsContent() {
    var session = SearchSession(); session.accept(searchPage([1, 2]), offset: 0)
    session.fail("超时", offset: 30)
    #expect(session.failedOffset == 30); #expect(session.result.tracks.map(\.id) == [1, 2])
    session.begin(); #expect(session.failedOffset == 30)
    session.accept(searchPage([2, 3], more: false), offset: 30)
    #expect(session.result.tracks.map(\.id) == [1, 2, 3]); #expect(session.failedOffset == nil)
    #expect(!session.result.hasMore)
}
@Test func changedFirstPageInvalidatesOldPaginationButStableRefreshKeepsIt() {
    var session = SearchSession(); session.accept(searchPage([1]), offset: 0); session.accept(searchPage([2]), offset: 30)
    session.accept(searchPage([1]), offset: 0); #expect(session.nextOffset == 60)
    session.accept(searchPage([4]), offset: 0); #expect(session.nextOffset == 30); #expect(session.result.tracks.map(\.id) == [4])
}
