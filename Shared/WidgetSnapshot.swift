import Foundation
struct WidgetPlaylist: Codable, Identifiable { var id: Int64; var name: String }
struct WidgetSnapshot: Codable {
    var title: String = "留一点时间给音乐"
    var artist: String = "打开余音，继续听"
    var isPlaying = false
    var playlists: [WidgetPlaylist] = []
    var updatedAt = Date()
}
enum SharedListening {
    static let groupID = "group.space.thunguo.yuyin"
    static var defaults: UserDefaults? {
        #if PERSONAL_DEVICE
        return .standard
        #else
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil else { return nil }
        return UserDefaults(suiteName: groupID)
        #endif
    }
    static func read() -> WidgetSnapshot { guard let data = defaults?.data(forKey: "listening"), let value = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .init() }; return value }
    static func write(_ value: WidgetSnapshot) { if let data = try? JSONEncoder().encode(value) { defaults?.set(data, forKey: "listening") } }
    static func clear() { defaults?.removeObject(forKey: "listening") }
}
