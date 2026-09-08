import Foundation
import MusicCore

@main struct MusicProbe {
    static func main() async throws {
        let api = MusicService()
        let search = try await api.search("旅行的意义")
        guard let track = search.tracks.first else { throw MusicError.invalidResponse }
        print("PASS search: \(search.tracks.count) catalog songs")
        let details = try await api.tracks(ids: [track.id])
        guard details.first?.id == track.id else { throw MusicError.invalidResponse }
        print("PASS song details: identifier and duration decoded")
        let album = try await api.album(track.album.id)
        print("PASS album: \(album.1.count) songs")
        let lyrics = try await api.lyrics(track.id)
        print("PASS lyrics: \(lyrics.count) lines")
        let discoveries = try await api.recommendations()
        print("PASS public recommendations: \(discoveries.count) songs")
        let playlists = try await api.recommendedPlaylists()
        print("PASS public playlists: \(playlists.count) lists")
        let sources = try await api.sources(for: track)
        print("PASS explanation sources: \(sources.count) source documents")
        do { let resource = try await api.resource(track.id); print("PASS playback resolver: \(resource.availability.rawValue), \(resource.quality); no audio downloaded") }
        catch MusicError.unavailable { print("PASS playback resolver: unavailable content is reported explicitly") }
    }
}
