import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
public protocol StreamingTransport: HTTPTransport {
    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)
}
public final class PrivateTransport: StreamingTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCache = nil
        c.timeoutIntervalForRequest = 25; c.timeoutIntervalForResource = 90
        session = URLSession(configuration: c, delegate: SameOriginRedirectDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MusicError.invalidResponse }
        return (data, response)
    }
    public func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw MusicError.invalidResponse }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do { for try await line in bytes.lines { try Task.checkCancellation(); continuation.yield(line) }; continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, response)
    }
}
private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a credential-bearing request to another origin.
        let original = task.originalRequest?.url
        completionHandler(request.url?.host == original?.host && request.url?.scheme == "https" && request.url?.port == original?.port ? request : nil)
    }
}

public actor MusicService {
    public let baseURL: URL
    private let transport: any HTTPTransport
    private var cookie = ""
    private var sessionRevision = UUID()
    private var pendingRequests: [UUID: Task<(Data, HTTPURLResponse), Error>] = [:]
    public init(baseURL: URL = URL(string: "https://music.thunguo.space")!, transport: any HTTPTransport = PrivateTransport(), cookie: String = "") { self.baseURL = baseURL; self.transport = transport; self.cookie = cookie }
    public func setCookie(_ value: String) { guard value != cookie else { return }; pendingRequests.values.forEach { $0.cancel() }; pendingRequests = [:]; cookie = value; sessionRevision = UUID() }
    public func request(_ path: String, parameters: [String: JSONValue] = [:], authenticated: Bool = false) async throws -> JSONValue {
        guard baseURL.scheme == "https", baseURL.host != nil else { throw MusicError.invalidConfiguration("音乐服务地址需要使用 HTTPS。") }
        if authenticated && cookie.isEmpty { throw MusicError.loginRequired }
        let revision = sessionRevision
        var body = parameters
        if authenticated { body["cookie"] = .string(cookie) }
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        // Distinct IDs avoid URL cache collisions, including requests in the same millisecond.
        components.queryItems = [URLQueryItem(name: "timestamp", value: String(Int64(Date().timeIntervalSince1970 * 1000))), URLQueryItem(name: "requestId", value: UUID().uuidString)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(body)
        let requestID = UUID(), preparedRequest = request
        let task = Task { try await transport.data(for: preparedRequest) }
        pendingRequests[requestID] = task
        defer { pendingRequests[requestID] = nil }
        let (data, response) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard revision == sessionRevision else { throw MusicError.staleSession }
        guard !(300..<400).contains(response.statusCode) else { throw MusicError.message("音乐服务发生了重定向，请检查服务地址。") }
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        let code = json?["code"].int ?? response.statusCode
        if code == 301 || code == 401 { throw MusicError.loginRequired }
        guard (200..<300).contains(response.statusCode), code == 0 || code == 200 || (path == "login/qr/check" && (800...803).contains(code)) else {
            if code == 460 || code == 503 { throw MusicError.message("网易云暂时限制了本次请求，请稍后重试。") }
            if code == 429 { throw MusicError.message("请求较多，请稍等片刻。") }
            throw MusicError.message("音乐服务暂时无法完成请求（\(code)）。请稍后重试。")
        }
        guard let json else { throw MusicError.invalidResponse }
        return json
    }
    public func sendCode(phone: String, countryCode: String) async throws {
        _ = try await request("captcha/sent/v1", parameters: ["phone": .string(phone), "ctcode": .string(countryCode)])
    }
    public func login(phone: String, code: String, countryCode: String) async throws -> LoginResult {
        let j = try await request("login/cellphone", parameters: ["phone": .string(phone), "captcha": .string(code), "countrycode": .string(countryCode)])
        guard !j["cookie"].string.isEmpty, j["profile"]["userId"].double > 0 else { throw MusicError.invalidResponse }
        return LoginResult(cookie: j["cookie"].string, profile: UserProfile(json: j["profile"]))
    }
    public func profile() async throws -> UserProfile {
        let j = try await request("login/status", authenticated: true)
        let profile = j["data"]["profile"]
        guard profile["userId"].double > 0 else { throw MusicError.loginRequired }
        return UserProfile(json: profile)
    }
    public func createQR() async throws -> QRLogin {
        let keyJSON = try await request("login/qr/key")
        let key = keyJSON["data"]["unikey"].string
        guard !key.isEmpty else { throw MusicError.invalidResponse }
        let j = try await request("login/qr/create", parameters: ["key": .string(key)])
        guard let url = secureURL(j["data"]["qrurl"].string) else { throw MusicError.invalidResponse }
        return QRLogin(key: key, url: url)
    }
    public func checkQR(_ key: String) async throws -> QRStatus {
        let j = try await request("login/qr/check", parameters: ["key": .string(key), "noCookie": .bool(true)])
        switch j["code"].int {
        case 800: return .expired
        case 801: return .waiting
        case 802: return .confirmation
        case 803: guard !j["cookie"].string.isEmpty else { throw MusicError.invalidResponse }; return .success(j["cookie"].string)
        default: throw MusicError.invalidResponse
        }
    }
    public func search(_ query: String, kind: SearchKind = .tracks, offset: Int = 0) async throws -> SearchResult {
        let j = try await request("cloudsearch", parameters: ["keywords": .string(query), "type": .number(Double(kind.rawValue)), "limit": .number(30), "offset": .number(Double(offset))])
        let result = j["result"]
        var r = SearchResult()
        r.tracks = result["songs"].array.map(Track.init(json:))
        r.albums = result["albums"].array.map(Album.init(json:))
        r.artists = result["artists"].array.map(Artist.init(json:))
        r.playlists = result["playlists"].array.map(Playlist.init(json:))
        let key: String
        switch kind { case .tracks: key = "songCount"; case .albums: key = "albumCount"; case .artists: key = "artistCount"; case .playlists: key = "playlistCount" }
        r.hasMore = offset + 30 < result[key].int
        return r
    }
    public func tracks(ids: [Int64]) async throws -> [Track] {
        var result: [Track] = []
        for start in stride(from: 0, to: ids.count, by: 200) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 200, ids.count)])
            let j = try await request("song/detail", parameters: ["ids": .string(batch.map(String.init).joined(separator: ","))], authenticated: !cookie.isEmpty)
            result += j["songs"].array.map(Track.init(json:))
        }
        let byID = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.map { byID[$0] ?? Track(id: $0, title: "暂时无法读取的歌曲", artists: [], album: .init(id: 0, name: ""), duration: 0, availability: .unavailable) }
    }
    public func playlistTracks(_ id: Int64, onProgress: @escaping @Sendable ([Track]) async -> Void = { _ in }) async throws -> [Track] {
        let j = try await request("playlist/detail", parameters: ["id": .string(String(id))], authenticated: !cookie.isEmpty)
        let ids = j["playlist"]["trackIds"].array.map { Int64($0["id"].double) }
        let expectedCount = j["playlist"]["trackCount"].int
        if !ids.isEmpty, ids.count >= expectedCount {
            var known = Dictionary(j["playlist"]["tracks"].array.map(Track.init(json:)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            func snapshot() -> [Track] {
                ids.map { id in
                    if let track = known[id] { return track }
                    var track = Track(id: id, title: "正在读取歌曲资料", artists: [], album: .init(id: 0, name: ""), duration: 0)
                    track.metadataPending = true; return track
                }
            }
            if !known.isEmpty { await onProgress(snapshot()) }
            let missing = ids.filter { known[$0] == nil }
            for start in stride(from: 0, to: missing.count, by: 200) {
                try Task.checkCancellation()
                let batch = Array(missing[start..<min(start + 200, missing.count)])
                for track in try await tracks(ids: batch) { known[track.id] = track }
                await onProgress(snapshot())
            }
            return snapshot()
        }
        // Some deployments omit trackIds. Paginate and reject a repeating page.
        var result: [Track] = [], seen = Set<Int64>()
        var offset = 0
        while true {
            let page = try await request("playlist/track/all", parameters: ["id": .string(String(id)), "limit": .number(200), "offset": .number(Double(offset))], authenticated: !cookie.isEmpty)
            let songs = page["songs"].array.map(Track.init(json:))
            guard !songs.isEmpty else { break }
            let fresh = songs.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { throw MusicError.message("歌单分页返回重复数据，已停止同步，请稍后重试。") }
            result += fresh; offset += songs.count
            if songs.count < 200 { break }
        }
        guard expectedCount == 0 || result.count >= expectedCount else { throw MusicError.message("歌单曲目尚未完整读取，请稍后重试。") }
        return result
    }
    private func allPages(_ path: String, key: String, parameters: [String: JSONValue] = [:]) async throws -> [JSONValue] {
        var result: [JSONValue] = [], offset = 0
        var previous: [JSONValue] = []
        while true {
            var p = parameters; p["limit"] = .number(100); p["offset"] = .number(Double(offset))
            let j = try await request(path, parameters: p, authenticated: true)
            let page = j[key].array
            if page.isEmpty { break }
            guard page != previous else { throw MusicError.message("同步分页异常，请稍后重试。") }
            result += page; previous = page; offset += page.count
            if (!j["more"].isNull && !j["more"].bool) || (j["more"].isNull && page.count < 100) { break }
        }
        return result
    }
    public func library(userID: Int64, cached: LibrarySnapshot? = nil, onProgress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> LibrarySnapshot {
        let revision = sessionRevision
        var result = cached?.accountID == userID ? cached! : LibrarySnapshot(accountID: userID, syncedAt: .distantPast)
        var failures: [String] = []
        func failed(_ category: String, _ error: Error) throws {
            if error is CancellationError { throw CancellationError() }
            if error as? MusicError == .loginRequired || error as? MusicError == .staleSession { throw error }
            failures.append(category + "未更新：" + error.localizedDescription)
        }
        async let fetchedPlaylists = userPlaylists(userID)
        async let fetchedAlbums = allPages("album/sublist", key: "data").map(Album.init(json:))
        async let fetchedArtists = allPages("artist/sublist", key: "data").map(Artist.init(json:))
        await onProgress("正在核对喜欢的歌曲…")
        do {
            let likes = try await request("likelist", parameters: ["uid": .string(String(userID))], authenticated: true)
            let ids = likes["ids"].array.map { Int64($0.double) }
            let reuse = Date().timeIntervalSince(result.syncedAt) < 86400
            var known = Dictionary(result.likedTracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let needed = reuse ? ids.filter { known[$0] == nil || known[$0]!.duration <= 0 } : ids
            for start in stride(from: 0, to: needed.count, by: 200) {
                await onProgress("正在读取歌曲资料 \(min(start + 200, needed.count))/\(needed.count)…")
                let batch = Array(needed[start..<min(start + 200, needed.count)])
                for song in try await tracks(ids: batch) { known[song.id] = song }
            }
            // Missing/deleted song details remain visible as unavailable identities.
            result.likedTracks = ids.map { known[$0] ?? Track(id: $0, title: "暂时无法读取的歌曲", artists: [], album: .init(id: 0, name: ""), duration: 0, availability: .unavailable) }
        } catch { try failed("喜欢的歌", error) }
        await onProgress("正在同步歌单…")
        do { result.playlists = try await fetchedPlaylists } catch { try failed("歌单", error) }
        await onProgress("正在同步专辑…")
        do { result.albums = try await fetchedAlbums } catch { try failed("专辑", error) }
        await onProgress("正在同步音乐人…")
        do { result.artists = try await fetchedArtists } catch { try failed("音乐人", error) }
        guard revision == sessionRevision else { throw MusicError.staleSession }
        if failures.isEmpty { result.syncedAt = .now }
        result.partialFailures = failures.isEmpty ? nil : failures
        return result
    }
    public func recommendations() async throws -> [Track] {
        if !cookie.isEmpty {
            let j = try await request("recommend/songs", authenticated: true)
            return j["data"]["dailySongs"].array.map(Track.init(json:))
        }
        let j = try await request("personalized/newsong", parameters: ["limit": .number(12)])
        return j["result"].array.map { Track(json: $0["song"].isNull ? $0 : $0["song"]) }
    }
    public func recommendedPlaylists() async throws -> [Playlist] {
        let j = try await request("personalized", parameters: ["limit": .number(6)])
        return j["result"].array.map(Playlist.init(json:))
    }
    public func resource(_ trackID: Int64, quality: AudioQuality = .exhigh, download: Bool = false) async throws -> PlaybackResource {
        let j = try await request(download ? "song/download/url/v1" : "song/url/v1", parameters: ["id": .string(String(trackID)), "level": .string(quality.rawValue), "unblock": .bool(false)], authenticated: !cookie.isEmpty)
        let data = j["data"].array.first ?? j["data"]
        guard let url = secureURL(data["url"].string), data["code"].int == 0 || data["code"].int == 200 else { throw MusicError.unavailable }
        let preview = !data["freeTrialInfo"].isNull
        if download && preview { throw MusicError.unavailable }
        let ext = data["type"].string.lowercased()
        return .init(trackID: trackID, url: url, expiresAt: Date().addingTimeInterval(max(1, data["expi"].double)), availability: preview ? .preview : .full, quality: data["level"].string, previewStart: preview ? data["freeTrialInfo"]["start"].double : nil, previewEnd: preview ? data["freeTrialInfo"]["end"].double : nil, fileExtension: ["mp3", "flac", "m4a", "aac", "wav"].contains(ext) ? ext : "mp3", expectedBytes: data["size"].double > 0 ? Int64(data["size"].double) : nil)
    }
    public func playableCandidates(_ tracks: [Track]) async throws -> [Track] {
        var result: [Track] = []
        for start in stride(from: 0, to: tracks.count, by: 50) {
            let batch = Array(tracks[start..<min(start + 50, tracks.count)])
            let j = try await request("song/url/v1", parameters: ["id": .string(batch.map { String($0.id) }.joined(separator: ",")), "level": .string("standard"), "unblock": .bool(false)], authenticated: !cookie.isEmpty)
            let fullIDs = Set(j["data"].array.filter { secureURL($0["url"].string) != nil && ($0["code"].int == 0 || $0["code"].int == 200) && $0["freeTrialInfo"].isNull }.map { Int64($0["id"].double) })
            result += batch.filter { fullIDs.contains($0.id) }.map { var t = $0; t.availability = .full; return t }
        }
        return result
    }
    public func lyrics(_ id: Int64) async throws -> [LyricLine] {
        let j = try await request("lyric/new", parameters: ["id": .string(String(id))])
        return LyricsParser.parse(yrc: j["yrc"]["lyric"].string, lrc: j["lrc"]["lyric"].string)
    }
    public func album(_ id: Int64) async throws -> (Album, [Track]) {
        let j = try await request("album", parameters: ["id": .string(String(id))])
        return (Album(json: j["album"]), j["songs"].array.map(Track.init(json:)))
    }
    public func artist(_ id: Int64) async throws -> (Artist, [Track]) {
        let j = try await request("artists", parameters: ["id": .string(String(id))])
        return (Artist(json: j["artist"]), j["hotSongs"].array.map(Track.init(json:)))
    }
    public func sources(for track: Track) async throws -> [MusicSource] {
        var result = [MusicSource(id: "track", title: "歌曲资料", text: "歌名：\(track.title)；音乐人：\(track.artistName)；专辑：\(track.album.name)；时长：\(timeLabel(track.duration))。", url: track.webURL)]
        if track.album.id > 0 {
            do {
                let j = try await request("album", parameters: ["id": .string(String(track.album.id))])
                let a = j["album"]
                var facts: [String] = []
                if a["publishTime"].double > 0 {
                    let date = Date(timeIntervalSince1970: a["publishTime"].double / 1000)
                    let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    facts.append("发行日期：" + formatter.string(from: date))
                }
                if !a["company"].string.isEmpty { facts.append("发行公司：" + a["company"].string) }
                if !a["description"].string.isEmpty { facts.append(String(a["description"].string.prefix(6000))) }
                if !facts.isEmpty { result.append(.init(id: "album", title: "专辑与发行资料", text: facts.joined(separator: "\n"), url: URL(string: "https://music.163.com/album?id=\(track.album.id)")!)) }
            } catch is CancellationError { throw CancellationError() } catch { }
        }
        if let artist = track.artists.first, artist.id > 0 {
            do {
                let j = try await request("artist/desc", parameters: ["id": .string(String(artist.id))])
                if !j["briefDesc"].string.isEmpty { result.append(.init(id: "artist", title: "音乐人介绍", text: String(j["briefDesc"].string.prefix(4000)), url: URL(string: "https://music.163.com/artist?id=\(artist.id)")!)) }
            } catch is CancellationError { throw CancellationError() } catch { }
        }
        do {
            let j = try await request("song/wiki/info", parameters: ["id": .string(String(track.id))])
            let facts = MusicFactsParser.wikiInfo(j)
            if !facts.isEmpty { result.append(.init(id: "credits", title: "音乐百科资料", text: facts.joined(separator: "\n"), url: track.webURL)) }
        } catch is CancellationError { throw CancellationError() } catch { }
        try Task.checkCancellation()
        return result
    }
    public func artistAlbums(_ id: Int64, offset: Int = 0) async throws -> ([Album], Bool) {
        let j = try await request("artist/album", parameters: ["id": .string(String(id)), "limit": .number(30), "offset": .number(Double(offset))])
        return (j["hotAlbums"].array.map(Album.init(json:)), j["more"].bool)
    }
    public func similarTracks(_ id: Int64) async throws -> [Track] {
        let j = try await request("simi/song", parameters: ["id": .string(String(id))])
        return j["songs"].array.map(Track.init(json:)).filter { $0.id != id }
    }
    public func userPlaylists(_ userID: Int64) async throws -> [Playlist] {
        try await allPages("user/playlist", key: "playlist", parameters: ["uid": .string(String(userID))]).map(Playlist.init(json:))
    }
    private func requireOwnedPlaylist(_ id: Int64, userID: Int64) async throws -> Playlist {
        let j = try await request("playlist/detail", parameters: ["id": .string(String(id))], authenticated: true)
        let playlist = Playlist(json: j["playlist"])
        guard playlist.creatorID == userID else { throw MusicError.message("只能修改你创建的歌单。") }
        return playlist
    }
    public func renamePlaylist(_ id: Int64, name: String, userID: Int64) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw MusicError.message("歌单名需要 1 至 40 个字。") }
        if try await requireOwnedPlaylist(id, userID: userID).name == name { return }
        _ = try await request("playlist/name/update", parameters: ["id": .string(String(id)), "name": .string(name)], authenticated: true)
    }
    public func deletePlaylist(_ id: Int64, userID: Int64) async throws {
        guard try await userPlaylists(userID).contains(where: { $0.id == id }) else { return }
        _ = try await requireOwnedPlaylist(id, userID: userID)
        _ = try await request("playlist/delete", parameters: ["id": .string(String(id))], authenticated: true)
    }
    public func reorderPlaylist(_ id: Int64, ids: [Int64], expected: [Int64], userID: Int64) async throws {
        _ = try await requireOwnedPlaylist(id, userID: userID)
        let current = try await playlistTracks(id).map(\.id)
        if current == ids { return }
        guard current == expected, ids.count == current.count, Set(ids) == Set(current) else { throw MusicError.message("歌单已在其他地方发生变化，请刷新后重新排序。") }
        let value = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        _ = try await request("song/order/update", parameters: ["pid": .string(String(id)), "ids": .string(value)], authenticated: true)
    }
    public func setLiked(_ id: Int64, liked: Bool, userID: Int64) async throws {
        // Read-before-write makes a retry safe after a lost response.
        let current = try await request("likelist", parameters: ["uid": .string(String(userID))], authenticated: true)
        let exists = current["ids"].array.contains { Int64($0.double) == id }
        if exists == liked { return }
        _ = try await request("like", parameters: ["id": .string(String(id)), "like": .bool(liked)], authenticated: true)
    }
    public func createPlaylist(name: String) async throws -> Playlist {
        let j = try await request("playlist/create", parameters: ["name": .string(name), "privacy": .number(10)], authenticated: true)
        guard j["playlist"]["id"].double > 0 else { throw MusicError.invalidResponse }
        return Playlist(json: j["playlist"])
    }
    public func editPlaylist(_ id: Int64, tracks ids: [Int64], adding: Bool) async throws {
        let revision = sessionRevision
        let current = Set(try await playlistTracks(id).map(\.id))
        var seen = Set<Int64>()
        let pending = ids.filter { seen.insert($0).inserted && (adding ? !current.contains($0) : current.contains($0)) }
        for start in stride(from: 0, to: pending.count, by: 100) {
            try Task.checkCancellation()
            guard revision == sessionRevision else { throw MusicError.staleSession }
            let batch = pending[start..<min(start + 100, pending.count)]
            _ = try await request("playlist/tracks", parameters: ["pid": .string(String(id)), "tracks": .string(batch.map(String.init).joined(separator: ",")), "op": .string(adding ? "add" : "del")], authenticated: true)
        }
    }
    public func subscribe(id: Int64, kind: SearchKind, subscribed: Bool) async throws {
        let path: String, key: String
        switch kind { case .albums: path = "album/sub"; key = "id"; case .artists: path = "artist/sub"; key = "id"; case .playlists: path = "playlist/subscribe"; key = "id"; default: throw MusicError.invalidResponse }
        _ = try await request(path, parameters: [key: .string(String(id)), "t": .number(subscribed ? 1 : 2)], authenticated: true)
    }
}
