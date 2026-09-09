import Foundation
import MusicCore

struct ArtistAlbumPage: Codable, Sendable { var albums: [Album]; var more: Bool }

extension AppStore {
    func playlistTracks(_ id: Int64, refresh: Bool = false) async throws -> [Track] {
        try await repository.value([Track].self, key: accountKey("cache.playlist.\(id)"), lifetime: Freshness.collection, refresh: refresh) { [music] in try await music.playlistTracks(id) }
    }
    func trackUpdates(playlist: Playlist?, album: Album?, artist: Artist?, refresh: Bool = false) -> AsyncThrowingStream<[Track], Error> {
        let key = playlist.map { "playlist.\($0.id)" } ?? album.map { "album.\($0.id)" } ?? "artist.\(artist?.id ?? 0)"
        let cacheKey = accountKey("cache." + key), epoch = accountGeneration
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if await repository.memorySnapshot([Track].self, key: cacheKey) == nil,
                       let preview = try await background.trackPreview(key: cacheKey) {
                        try Task.checkCancellation(); guard epoch == accountGeneration else { throw CancellationError() }
                        continuation.yield(preview)
                    }
                    let updates = repository.progressiveUpdates([Track].self, key: cacheKey, lifetime: playlist == nil ? Freshness.metadata : Freshness.collection, refresh: refresh) { [music] emit in
                        if let playlist { return try await music.playlistTracks(playlist.id, onProgress: emit) }
                        if let album { return try await music.album(album.id).1 }
                        if let artist { return try await music.artist(artist.id).1 }
                        return []
                    }
                    for try await tracks in updates {
                        try Task.checkCancellation(); guard epoch == accountGeneration else { throw CancellationError() }
                        continuation.yield(tracks)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func albumTracks(_ id: Int64, refresh: Bool = false) async throws -> [Track] {
        try await repository.value([Track].self, key: accountKey("cache.album.\(id)"), lifetime: Freshness.metadata, refresh: refresh) { [music] in try await music.album(id).1 }
    }
    func artistTracks(_ id: Int64, refresh: Bool = false) async throws -> [Track] {
        try await repository.value([Track].self, key: accountKey("cache.artist.\(id)"), lifetime: Freshness.metadata, refresh: refresh) { [music] in try await music.artist(id).1 }
    }
    func artistAlbumPage(_ id: Int64, offset: Int, refresh: Bool = false) async throws -> ArtistAlbumPage {
        try await repository.value(ArtistAlbumPage.self, key: accountKey("cache.artistAlbums.\(id).\(offset)"), lifetime: Freshness.metadata, refresh: refresh) { [music] in
            let result = try await music.artistAlbums(id, offset: offset); return .init(albums: result.0, more: result.1)
        }
    }
    func lyricUpdates(_ id: Int64, refresh: Bool = false) -> AsyncThrowingStream<[LyricLine], Error> {
        repository.updates([LyricLine].self, key: accountKey("cache.lyrics.\(id)"), lifetime: Freshness.lyrics, refresh: refresh) { [music] in try await music.lyrics(id) }
    }
    func lyricLines(_ id: Int64, refresh: Bool = false) async throws -> [LyricLine] {
        try await repository.value([LyricLine].self, key: accountKey("cache.lyrics.\(id)"), lifetime: Freshness.lyrics, refresh: refresh) { [music] in try await music.lyrics(id) }
    }
    func sourceUpdates(_ track: Track) -> AsyncThrowingStream<[MusicSource], Error> {
        repository.updates([MusicSource].self, key: accountKey("cache.sources.\(track.id)"), lifetime: Freshness.metadata) { [music] in try await music.sources(for: track) }
    }
    func musicSources(_ track: Track, refresh: Bool = false) async throws -> [MusicSource] {
        try await repository.value([MusicSource].self, key: accountKey("cache.sources.\(track.id)"), lifetime: Freshness.metadata, refresh: refresh) { [music] in try await music.sources(for: track) }
    }
    func searchUpdates(_ text: String, kind: SearchKind, offset: Int = 0, refresh: Bool = false) -> AsyncThrowingStream<SearchResult, Error> {
        repository.updates(SearchResult.self, key: accountKey("cache.search.\(kind.rawValue).\(offset).\(text.lowercased())"), lifetime: Freshness.search, refresh: refresh) { [music] in try await music.search(text, kind: kind, offset: offset) }
    }
    func invalidatePlaylist(_ id: Int64) async { do { try await repository.invalidate(accountKey("cache.playlist.\(id)")) } catch { report(error) } }
    func cachePlaylist(_ tracks: [Track], id: Int64) async {
        do { try await repository.store(tracks, key: accountKey("cache.playlist.\(id)")) } catch { report(error) }
    }
    func clearMusicCache() {
        preheater.stop()
        Task {
            do {
                try await repository.reset(removing: accountKey("cache.")); await ArtworkStore.shared.clear()
                await updateCacheUsage(); notify("已清除封面与音乐资料缓存")
            } catch { report(error) }
        }
    }
    var metadataCacheBytes: Int { cacheBytes }
}

extension AppStore {
    func similarTracks(_ track: Track) async throws -> [Track] {
        try await repository.value([Track].self, key: accountKey("cache.similar.\(track.id)"), lifetime: Freshness.metadata) { [music] in try await music.similarTracks(track.id) }
    }
}
