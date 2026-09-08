import Foundation
import MusicCore

struct CachedValue<Value: Codable>: Codable { var value: Value; var updatedAt = Date() }
struct ArtistAlbumPage: Codable { var albums: [Album]; var more: Bool }

extension AppStore {
    private func cached<Value: Codable>(_ type: Value.Type, _ key: String) -> CachedValue<Value>? {
        persistence.load(CachedValue<Value>.self, key: accountKey("cache." + key))
    }
    private func readThrough<Value: Codable>(_ type: Value.Type, key: String, refresh: Bool, lifetime: TimeInterval = 1800, fetch: () async throws -> Value) async throws -> Value {
        let saved = cached(type, key), generation = accountGeneration
        if !refresh, let saved, Date().timeIntervalSince(saved.updatedAt) < lifetime { return saved.value }
        do {
            let value = try await fetch()
            guard generation == accountGeneration else { throw MusicError.staleSession }
            do { try persistence.save(CachedValue(value: value), key: accountKey("cache." + key)) } catch { report(error) }
            return value
        } catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            guard generation == accountGeneration else { throw MusicError.staleSession }
            if let saved { notify("暂时无法更新，正在显示已缓存的音乐资料。"); return saved.value }
            throw error
        }
    }
    func cachedPlaylistTracks(_ id: Int64) -> [Track] { cached([Track].self, "playlist.\(id)")?.value ?? [] }
    func playlistTracks(_ id: Int64, refresh: Bool = false) async throws -> [Track] {
        try await readThrough([Track].self, key: "playlist.\(id)", refresh: refresh) { try await music.playlistTracks(id) }
    }
    func albumTracks(_ id: Int64, refresh: Bool = false) async throws -> [Track] {
        try await readThrough([Track].self, key: "album.\(id)", refresh: refresh, lifetime: 86400) { try await music.album(id).1 }
    }
    func artistTracks(_ id: Int64, refresh: Bool = false) async throws -> [Track] {
        try await readThrough([Track].self, key: "artist.\(id)", refresh: refresh, lifetime: 21600) { try await music.artist(id).1 }
    }
    func artistAlbumPage(_ id: Int64, offset: Int, refresh: Bool = false) async throws -> ArtistAlbumPage {
        try await readThrough(ArtistAlbumPage.self, key: "artistAlbums.\(id).\(offset)", refresh: refresh, lifetime: 21600) {
            let result = try await music.artistAlbums(id, offset: offset); return .init(albums: result.0, more: result.1)
        }
    }
    func lyricLines(_ id: Int64, refresh: Bool = false) async throws -> [LyricLine] {
        try await readThrough([LyricLine].self, key: "lyrics.\(id)", refresh: refresh, lifetime: 86400) { try await music.lyrics(id) }
    }
    func musicSources(_ track: Track, refresh: Bool = false) async throws -> [MusicSource] {
        try await readThrough([MusicSource].self, key: "sources.\(track.id)", refresh: refresh, lifetime: 86400) { try await music.sources(for: track) }
    }
    func invalidatePlaylist(_ id: Int64) { do { try persistence.remove(key: accountKey("cache.playlist.\(id)")) } catch { report(error) } }
    func clearMusicCache() {
        do { try persistence.remove(prefix: accountKey("cache.")); Task { await ArtworkStore.shared.clear() }; notify("已清除封面与音乐资料缓存") } catch { report(error) }
    }
    var metadataCacheBytes: Int { persistence.storedBytes(prefix: accountKey("cache.")) }
}
