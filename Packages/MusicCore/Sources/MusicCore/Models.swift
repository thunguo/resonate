import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    public var string: String { switch self { case .string(let v): return v; case .number(let v): return String(format: "%.0f", v); default: return "" } }
    public var double: Double { if case .number(let v) = self { return v }; return Double(string) ?? 0 }
    public var int: Int { Int(double) }
    public var bool: Bool { if case .bool(let v) = self { return v }; return int != 0 }
    public var isNull: Bool { self == .null }
}

public struct Artist: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var artwork: URL?
    public init(id: Int64, name: String, artwork: URL? = nil) { self.id = id; self.name = name; self.artwork = artwork }
    public init(json: JSONValue) { self.init(id: Int64(json["id"].double), name: json["name"].string, artwork: secureURL(json["picUrl"].string.isEmpty ? json["img1v1Url"].string : json["picUrl"].string)) }
}
public struct Album: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var artwork: URL?
    public var artistName: String
    public init(id: Int64, name: String, artwork: URL? = nil, artistName: String = "") { self.id = id; self.name = name; self.artwork = artwork; self.artistName = artistName }
    public init(json: JSONValue) { self.init(id: Int64(json["id"].double), name: json["name"].string, artwork: secureURL(json["picUrl"].string), artistName: json["artist"]["name"].string.isEmpty ? json["artists"].array.map { $0["name"].string }.joined(separator: " / ") : json["artist"]["name"].string) }
}
public enum Availability: String, Codable, Sendable { case unknown, full, preview, unavailable }
public struct Track: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var title: String
    public var artists: [Artist]
    public var album: Album
    public var duration: Double
    public var availability: Availability
    public var reason: String?
    public var metadataPending: Bool? = nil
    public init(id: Int64, title: String, artists: [Artist], album: Album, duration: Double, availability: Availability = .unknown, reason: String? = nil) {
        self.id = id; self.title = title; self.artists = artists; self.album = album; self.duration = duration; self.availability = availability; self.reason = reason
    }
    public var artistName: String { artists.map(\.name).joined(separator: " / ") }
    public var webURL: URL { URL(string: "https://music.163.com/song?id=\(id)")! }
    public init(json: JSONValue) {
        let a = json["ar"].isNull ? json["artists"] : json["ar"]
        let al = json["al"].isNull ? json["album"] : json["al"]
        self.init(id: Int64(json["id"].double), title: json["name"].string,
                  artists: a.array.map(Artist.init(json:)), album: Album(json: al),
                  duration: (json["dt"].isNull ? json["duration"].double : json["dt"].double) / 1000,
                  availability: json["noCopyrightRcmd"].isNull ? .unknown : .unavailable,
                  reason: json["reason"].string.isEmpty ? nil : json["reason"].string)
    }
}
public struct Playlist: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var artwork: URL?
    public var count: Int
    public var creatorID: Int64
    public var summary: String
    public init(id: Int64, name: String, artwork: URL? = nil, count: Int = 0, creatorID: Int64 = 0, summary: String = "") {
        self.id = id; self.name = name; self.artwork = artwork; self.count = count; self.creatorID = creatorID; self.summary = summary
    }
    public init(json: JSONValue) { self.init(id: Int64(json["id"].double), name: json["name"].string, artwork: secureURL(json["coverImgUrl"].string.isEmpty ? json["picUrl"].string : json["coverImgUrl"].string), count: json["trackCount"].int, creatorID: Int64(json["creator"]["userId"].double), summary: json["description"].string) }
}
public struct UserProfile: Codable, Sendable, Equatable {
    public var id: Int64
    public var name: String
    public var avatar: URL?
    public init(id: Int64, name: String, avatar: URL? = nil) { self.id = id; self.name = name; self.avatar = avatar }
    public init(json: JSONValue) { self.init(id: Int64(json["userId"].double), name: json["nickname"].string, avatar: secureURL(json["avatarUrl"].string)) }
}
public struct LoginResult: Sendable {
    public let cookie: String; public let profile: UserProfile
    public init(cookie: String, profile: UserProfile) { self.cookie = cookie; self.profile = profile }
}
public struct QRLogin: Sendable { public let key: String; public let url: URL }
public enum QRStatus: Sendable { case waiting, confirmation, expired, success(String) }
public enum SearchKind: Int, CaseIterable, Identifiable, Sendable {
    case tracks = 1, albums = 10, artists = 100, playlists = 1000
    public var id: Int { rawValue }
    public var label: String { switch self { case .tracks: return "歌曲"; case .albums: return "专辑"; case .artists: return "音乐人"; case .playlists: return "歌单" } }
}
public struct SearchResult: Codable, Sendable { public var tracks: [Track] = []; public var albums: [Album] = []; public var artists: [Artist] = []; public var playlists: [Playlist] = []; public var hasMore = false; public init() {} }
public enum AudioQuality: String, CaseIterable, Codable, Sendable {
    case standard, higher, exhigh, lossless, hires
    public var label: String { switch self { case .standard: return "标准"; case .higher: return "较高"; case .exhigh: return "极高"; case .lossless: return "无损"; case .hires: return "Hi-Res" } }
}
public struct PlaybackResource: Sendable {
    public let trackID: Int64
    public let url: URL
    public let expiresAt: Date
    public let availability: Availability
    public let quality: String
    public let previewStart: Double?
    public let previewEnd: Double?
    public let expectedBytes: Int64?
    public let fileExtension: String
    public init(trackID: Int64, url: URL, expiresAt: Date, availability: Availability, quality: String, previewStart: Double? = nil, previewEnd: Double? = nil, fileExtension: String = "mp3", expectedBytes: Int64? = nil) {
        self.trackID = trackID; self.url = url; self.expiresAt = expiresAt; self.availability = availability; self.quality = quality; self.previewStart = previewStart; self.previewEnd = previewEnd; self.fileExtension = fileExtension; self.expectedBytes = expectedBytes
    }
}
public struct LibrarySnapshot: Codable, Sendable {
    public var accountID: Int64
    public var likedTracks: [Track]
    public var playlists: [Playlist]
    public var albums: [Album]
    public var artists: [Artist]
    public var partialFailures: [String]? = nil
    public var syncedAt: Date
    public init(accountID: Int64, likedTracks: [Track] = [], playlists: [Playlist] = [], albums: [Album] = [], artists: [Artist] = [], syncedAt: Date = .now) { self.accountID = accountID; self.likedTracks = likedTracks; self.playlists = playlists; self.albums = albums; self.artists = artists; self.syncedAt = syncedAt }
}
public struct MusicSource: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var text: String
    public var url: URL
    public init(id: String, title: String, text: String, url: URL) { self.id = id; self.title = title; self.text = text; self.url = url }
}
public enum MusicError: LocalizedError, Equatable {
    case invalidResponse, loginRequired, unavailable, message(String), invalidConfiguration(String), staleSession
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务返回了无法读取的数据，请稍后重试。"
        case .loginRequired: return "登录已失效，请重新连接网易云音乐。"
        case .unavailable: return "这首歌暂时无法播放，可稍后重试或选择其他歌曲。"
        case .message(let v), .invalidConfiguration(let v): return v
        case .staleSession: return "账号已切换，本次请求已取消。"
        }
    }
}
public func secureURL(_ value: String) -> URL? {
    guard var c = URLComponents(string: value), !value.isEmpty else { return nil }
    if c.scheme == "http" { c.scheme = "https" }
    guard c.scheme == "https", c.host != nil else { return nil }
    return c.url
}
public func timeLabel(_ seconds: Double) -> String {
    let n = seconds.isFinite ? max(0, Int(seconds)) : 0
    return String(format: "%d:%02d", n / 60, n % 60)
}
