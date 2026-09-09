import Foundation

public struct SearchSessionKey: Hashable, Sendable {
    public var account: Int64
    public var query: String
    public var kind: SearchKind
    public init(account: Int64, query: String, kind: SearchKind) {
        self.account = account; self.query = query.trimmingCharacters(in: .whitespacesAndNewlines); self.kind = kind
    }
}
public struct SearchSession: Sendable {
    public private(set) var pages: [Int: SearchResult] = [:]
    public var local: [Track] = []
    public var anchor: String?
    public private(set) var failedOffset: Int?
    public private(set) var error: String?
    public init() {}
    public var nextOffset: Int { (pages.keys.max() ?? -30) + 30 }
    public var didSearch: Bool { !pages.isEmpty || error != nil }
    public private(set) var result = SearchResult()
    private mutating func rebuild() {
        var result = SearchResult()
        for offset in pages.keys.sorted() {
            guard let page = pages[offset] else { continue }
            result.tracks = Self.unique(result.tracks + page.tracks)
            result.albums = Self.unique(result.albums + page.albums)
            result.artists = Self.unique(result.artists + page.artists)
            result.playlists = Self.unique(result.playlists + page.playlists)
            result.hasMore = page.hasMore
        }
        self.result = result
    }
    public mutating func accept(_ page: SearchResult, offset: Int) {
        if offset == 0, let old = pages[0], Self.identity(old) != Self.identity(page) {
            pages = [:]
        }
        pages[offset] = page; failedOffset = nil; error = nil; rebuild()
    }
    public mutating func fail(_ message: String, offset: Int) { failedOffset = offset; error = message }
    public mutating func begin() { error = nil }
    private static func unique<T: Identifiable>(_ values: [T]) -> [T] {
        var seen = Set<T.ID>(); return values.filter { seen.insert($0.id).inserted }
    }
    private static func identity(_ page: SearchResult) -> [Int64] { page.tracks.map(\.id) + page.albums.map(\.id) + page.artists.map(\.id) + page.playlists.map(\.id) }
}
