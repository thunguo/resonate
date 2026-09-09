import Foundation
import SwiftData
import Security
import MusicCore

@Model final class StoredRecord {
    @Attribute(.unique) var key: String
    var data: Data
    var updatedAt: Date = Date()
    init(key: String, data: Data) { self.key = key; self.data = data }
}
@MainActor final class LocalPersistence {
    let container: ModelContainer
    let context: ModelContext
    private(set) var blockedKeys = Set<String>()
    init(inMemory: Bool = false) throws {
        if !inMemory { try FileManager.default.createDirectory(at: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], withIntermediateDirectories: true) }
        container = try ModelContainer(for: StoredRecord.self, StoredTrack.self, configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
        context = ModelContext(container)
    }
    func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let query = FetchDescriptor<StoredRecord>(predicate: #Predicate { $0.key == key })
        guard let record = try? context.fetch(query).first else { return nil }
        do { return try SnapshotCodec.decode(type, from: record.data) }
        catch { blockedKeys.insert(key); return nil }
    }
    func save<T: Encodable>(_ value: T, key: String) throws {
        guard !blockedKeys.contains(key) else { throw MusicError.message("本机资料格式暂不兼容，已保留原数据，请更新应用后重试。") }
        let data = try SnapshotCodec.encode(value)
        let query = FetchDescriptor<StoredRecord>(predicate: #Predicate { $0.key == key })
        if let record = try context.fetch(query).first { record.data = data; record.updatedAt = .now }
        else { context.insert(StoredRecord(key: key, data: data)) }
        try context.save()
    }
    func remove(prefix: String) throws {
        let all = try context.fetch(FetchDescriptor<StoredRecord>())
        for record in all where record.key.hasPrefix(prefix) { context.delete(record) }
        try context.save()
        blockedKeys = blockedKeys.filter { !$0.hasPrefix(prefix) }
    }
    func remove(key: String) throws {
        let query = FetchDescriptor<StoredRecord>(predicate: #Predicate { $0.key == key })
        for record in try context.fetch(query) { context.delete(record) }
        try context.save(); blockedKeys.remove(key)
    }
    func storedBytes(prefix: String) -> Int {
        (try? context.fetch(FetchDescriptor<StoredRecord>()).filter { $0.key.hasPrefix(prefix) }.reduce(0) { $0 + $1.data.count }) ?? 0
    }
}
enum Keychain {
    static let service = "space.thunguo.yuyin"
    static func read(_ key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
    }
    static func write(_ data: Data, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound { var insert = query; update.forEach { insert[$0] = $1 }; status = SecItemAdd(insert as CFDictionary, nil) }
        guard status == errSecSuccess else { throw MusicError.message("无法安全保存凭据，请解锁设备后重试。") }
    }
    static func remove(_ key: String) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key] as CFDictionary) }
}
struct UserPreferences: Codable {
    var musicTaste = ""
    var pinnedPlaylists: Set<Int64> = []
    var quality: AudioQuality = .exhigh
    var wifiOnly = true
    var appearance = "system"
    var smartPreheat = true
    var librarySort: [String: LibrarySort] = [:]
    init() {}
    private enum CodingKeys: String, CodingKey { case musicTaste, pinnedPlaylists, quality, wifiOnly, appearance, librarySort, smartPreheat }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        musicTaste = try c.decodeIfPresent(String.self, forKey: .musicTaste) ?? ""
        pinnedPlaylists = try c.decodeIfPresent(Set<Int64>.self, forKey: .pinnedPlaylists) ?? []
        quality = try c.decodeIfPresent(AudioQuality.self, forKey: .quality) ?? .exhigh
        wifiOnly = try c.decodeIfPresent(Bool.self, forKey: .wifiOnly) ?? true
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        librarySort = try c.decodeIfPresent([String: LibrarySort].self, forKey: .librarySort) ?? [:]
        smartPreheat = try c.decodeIfPresent(Bool.self, forKey: .smartPreheat) ?? true
    }
}
struct ListeningHistory: Codable, Sendable { var lastPlayed: [Int64: Date] = [:]; var recent: [Track] = [] }

@Model final class StoredTrack {
    @Attribute(.unique) var key: String
    var data: Data
    var libraryOwned: Bool = false
    var updatedAt: Date = Date()
    init(key: String, data: Data, libraryOwned: Bool = false) { self.key = key; self.data = data; self.libraryOwned = libraryOwned }
}
private struct TrackReferences: Codable {
    var trackIDs: [Int64]
    var updatedAt: Date
}
private struct LibraryReferences: Codable {
    var accountID: Int64
    var likedIDs: [Int64]
    var playlists: [Playlist]
    var albums: [Album]
    var artists: [Artist]
    var partialFailures: [String]?
    var syncedAt: Date
}
actor BackgroundPersistence: ResourceStorage {
    private let container: ModelContainer
    private var context: ModelContext?
    private var modelContext: ModelContext {
        if let context { return context }
        let value = ModelContext(container); context = value; return value
    }
    private var blockedKeys = Set<String>()
    private var trimAt = Date.distantPast
    init(modelContainer: ModelContainer) { container = modelContainer }
    private func raw(_ key: String) throws -> StoredRecord? {
        let query = FetchDescriptor<StoredRecord>(predicate: #Predicate { $0.key == key })
        return try modelContext.fetch(query).first
    }
    private func accountPrefix(_ key: String) -> String { key.split(separator: ".").prefix(2).joined(separator: ".") + "." }
    private func catalog(_ prefix: String) throws -> [Int64: StoredTrack] {
        let records = try modelContext.fetch(FetchDescriptor<StoredTrack>(predicate: #Predicate { $0.key.starts(with: prefix) }))
        return Dictionary(records.compactMap { record in Int64(record.key.split(separator: ".").last ?? "").map { ($0, record) } }, uniquingKeysWith: { a, _ in a })
    }
    func read(_ key: String) throws -> Data? {
        guard let record = try raw(key) else { return nil }
        if key.contains(".cache."), let refs = try? SnapshotCodec.decode(TrackReferences.self, from: record.data) {
            let tracks = try catalog(accountPrefix(key))
            let values = refs.trackIDs.compactMap { tracks[$0].flatMap { try? JSONDecoder().decode(Track.self, from: $0.data) } }
            guard values.count == refs.trackIDs.count else { return nil }
            return try SnapshotCodec.encode(CachedValue(values, updatedAt: refs.updatedAt))
        }
        return record.data
    }
    func trackPreview(key: String, limit: Int = 60) throws -> [Track]? {
        guard let data = try raw(key)?.data, let refs = try? SnapshotCodec.decode(TrackReferences.self, from: data) else { return nil }
        let prefix = accountPrefix(key), keys = refs.trackIDs.prefix(limit).map { prefix + "track.\($0)" }
        let records = try modelContext.fetch(FetchDescriptor<StoredTrack>(predicate: #Predicate { keys.contains($0.key) }))
        let known = Dictionary(try records.map { try JSONDecoder().decode(Track.self, from: $0.data) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard !known.isEmpty || refs.trackIDs.isEmpty else { return nil }
        return refs.trackIDs.map { id in
            if let song = known[id] { return song }
            var song = Track(id: id, title: "正在读取歌曲资料", artists: [], album: .init(id: 0, name: ""), duration: 0); song.metadataPending = true; return song
        }
    }
    func track(_ id: Int64, accountID: Int64) throws -> Track? {
        let key = "account.\(accountID).track.\(id)"
        let record = try modelContext.fetch(FetchDescriptor<StoredTrack>(predicate: #Predicate { $0.key == key })).first
        return try record.map { try JSONDecoder().decode(Track.self, from: $0.data) }
    }
    private func ensureWritable(_ key: String) throws {
        guard !blockedKeys.contains(key) else { throw MusicError.message("本机资料格式暂不兼容，原数据已保留。") }
        if let existing = try raw(key) {
            struct Version: Decodable { var schemaVersion: Int? }
            if let version = try? JSONDecoder().decode(Version.self, from: existing.data).schemaVersion, version > 1 {
                blockedKeys.insert(key); throw MusicError.message("本机资料来自更新版本，原数据已保留。")
            }
        }
    }
    private func put(_ data: Data, key: String) throws {
        try ensureWritable(key)
        if let record = try raw(key) { record.data = data; record.updatedAt = .now }
        else { modelContext.insert(StoredRecord(key: key, data: data)) }
    }
    private func saveTracks(_ tracks: [Track], prefix: String, owned: Bool) throws {
        var existing = try catalog(prefix)
        let ids = Set(tracks.map(\.id))
        if owned { for (id, record) in existing where record.libraryOwned && !ids.contains(id) { record.libraryOwned = false } }
        for track in tracks {
            let data = try JSONEncoder().encode(track)
            if let record = existing[track.id] {
                if record.data != data { record.data = data; record.updatedAt = .now }
                if owned { record.libraryOwned = true }
            } else { let record = StoredTrack(key: prefix + "track.\(track.id)", data: data, libraryOwned: owned); modelContext.insert(record); existing[track.id] = record }
        }
    }
    func write(_ data: Data, key: String) throws {
        if key.contains(".cache."), let tracks = try? SnapshotCodec.decode(CachedValue<[Track]>.self, from: data) {
            try saveTracks(tracks.value, prefix: accountPrefix(key), owned: false)
            try put(SnapshotCodec.encode(TrackReferences(trackIDs: tracks.value.map(\.id), updatedAt: tracks.updatedAt)), key: key)
        } else { try put(data, key: key) }
        try modelContext.save(); try trimCache(force: key.contains(".cache."))
    }
    func load<Value: Codable & Sendable>(_ type: Value.Type, key: String) throws -> Value? {
        if type == LibrarySnapshot.self {
            let normalized = try raw(key + ".v2"), legacy = try raw(key)
            if let normalized, legacy == nil || normalized.updatedAt >= legacy!.updatedAt {
                let refs = try SnapshotCodec.decode(LibraryReferences.self, from: normalized.data), tracks = try catalog(accountPrefix(key))
                let values = try refs.likedIDs.map { id -> Track in
                    guard let stored = tracks[id] else { throw MusicError.invalidResponse }
                    return try JSONDecoder().decode(Track.self, from: stored.data)
                }
                var library = LibrarySnapshot(accountID: refs.accountID, likedTracks: values, playlists: refs.playlists, albums: refs.albums, artists: refs.artists, syncedAt: refs.syncedAt)
                library.partialFailures = refs.partialFailures
                return library as? Value
            }
        }
        guard let data = try read(key) else { return nil }
        do {
            let value = try SnapshotCodec.decode(type, from: data)
            if let library = value as? LibrarySnapshot { try save(library, key: key) }
            return value
        } catch { blockedKeys.insert(key); throw error }
    }
    func save<Value: Codable & Sendable>(_ value: Value, key: String) throws {
        if let library = value as? LibrarySnapshot {
            try ensureWritable(key)
            try saveTracks(library.likedTracks, prefix: accountPrefix(key), owned: true)
            let refs = LibraryReferences(accountID: library.accountID, likedIDs: library.likedTracks.map(\.id), playlists: library.playlists, albums: library.albums, artists: library.artists, partialFailures: library.partialFailures, syncedAt: library.syncedAt)
            try put(SnapshotCodec.encode(refs), key: key + ".v2"); try modelContext.save(); try trimCache()
        } else { try write(SnapshotCodec.encode(value), key: key) }
    }
    func remove(prefix: String) throws {
        let query = FetchDescriptor<StoredRecord>(predicate: #Predicate { $0.key.starts(with: prefix) })
        for record in try modelContext.fetch(query) { modelContext.delete(record) }
        let trackPrefix = prefix.contains(".cache.") ? accountPrefix(prefix) : prefix
        let tracks = try modelContext.fetch(FetchDescriptor<StoredTrack>(predicate: #Predicate { $0.key.starts(with: trackPrefix) }))
        for record in tracks where !prefix.contains(".cache.") || !record.libraryOwned { modelContext.delete(record) }
        try modelContext.save(); blockedKeys = blockedKeys.filter { !$0.hasPrefix(prefix) }
    }
    func byteCount(prefix: String) throws -> Int {
        let query = FetchDescriptor<StoredRecord>(predicate: #Predicate { $0.key.starts(with: prefix) })
        let rows = try modelContext.fetch(query).reduce(0) { $0 + $1.data.count }
        let prefix = accountPrefix(prefix)
        let tracks = try modelContext.fetch(FetchDescriptor<StoredTrack>(predicate: #Predicate { $0.key.starts(with: prefix) && !$0.libraryOwned }))
        return rows + tracks.reduce(0) { $0 + $1.data.count }
    }
    private func trimCache(force: Bool = false) throws {
        guard force || Date().timeIntervalSince(trimAt) > 10 else { return }; trimAt = .now
        let rows = try modelContext.fetch(FetchDescriptor<StoredRecord>()).filter { $0.key.contains(".cache.") }
        let tracks = try modelContext.fetch(FetchDescriptor<StoredTrack>(predicate: #Predicate { !$0.libraryOwned }))
        var total = rows.reduce(0) { $0 + $1.data.count } + tracks.reduce(0) { $0 + $1.data.count }
        guard total > 40 * 1024 * 1024 else { return }
        for record in rows.sorted(by: { $0.updatedAt < $1.updatedAt }) where total > 40 * 1024 * 1024 {
            total -= record.data.count; modelContext.delete(record)
        }
        for record in tracks.sorted(by: { $0.updatedAt < $1.updatedAt }) where total > 40 * 1024 * 1024 {
            total -= record.data.count; modelContext.delete(record)
        }
        try modelContext.save()
    }
}

struct HomeSnapshot: Codable, Sendable {
    var tracks: [Track]
    var discoveries: [Track]
    var currentQueue: QueueState
}
struct PlaybackCheckpoint: Codable, Sendable {
    var currentID: UUID?
    var position: Double
}
struct PendingMutation: Identifiable, Codable {
    enum Kind: String, Codable { case like, addTracks, removeTracks }
    var id = UUID()
    var accountID: Int64
    var kind: Kind
    var trackIDs: [Int64]
    var targetID: Int64
    var liked: Bool?
    var status: String = "等待同步"
    var operationVersion: Int?
    var confirmedLiked: Bool?
    var track: Track?
}
