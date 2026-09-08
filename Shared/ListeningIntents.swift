import AppIntents
import Foundation

struct ContinueListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "继续听余音"
    static var description = IntentDescription("打开余音，从上次的曲目与进度继续播放。")
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult & OpensIntent { .result(opensIntent: OpenURLIntent(URL(string: "yuyin://resume")!)) }
}
struct FavoritePlaylistEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "余音歌单"
    static var defaultQuery = FavoritePlaylistQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct FavoritePlaylistQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FavoritePlaylistEntity] { try await suggestedEntities().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [FavoritePlaylistEntity] { SharedListening.read().playlists.map { FavoritePlaylistEntity(id: String($0.id), name: $0.name) } }
}
struct PlayFavoritePlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "播放余音歌单"
    static var description = IntentDescription("播放在余音中固定的歌单。")
    static var openAppWhenRun = true
    @Parameter(title: "歌单") var playlist: FavoritePlaylistEntity
    func perform() async throws -> some IntentResult & OpensIntent {
        var components = URLComponents(); components.scheme = "yuyin"; components.host = "playlist"; components.queryItems = [URLQueryItem(name: "id", value: playlist.id)]
        return .result(opensIntent: OpenURLIntent(components.url!))
    }
}
