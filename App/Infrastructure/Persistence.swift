import Foundation
import SwiftData
import Security
import MusicCore

@Model final class StoredRecord {
    @Attribute(.unique) var key: String
    var data: Data
    init(key: String, data: Data) { self.key = key; self.data = data }
}
@MainActor final class LocalPersistence {
    let container: ModelContainer
    let context: ModelContext
    private(set) var blockedKeys = Set<String>()
    init(inMemory: Bool = false) throws {
        if !inMemory { try FileManager.default.createDirectory(at: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], withIntermediateDirectories: true) }
        container = try ModelContainer(for: StoredRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
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
        if let record = try context.fetch(query).first { record.data = data }
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
    var librarySort: [String: LibrarySort] = [:]
    init() {}
    private enum CodingKeys: String, CodingKey { case musicTaste, pinnedPlaylists, quality, wifiOnly, appearance, librarySort }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        musicTaste = try c.decodeIfPresent(String.self, forKey: .musicTaste) ?? ""
        pinnedPlaylists = try c.decodeIfPresent(Set<Int64>.self, forKey: .pinnedPlaylists) ?? []
        quality = try c.decodeIfPresent(AudioQuality.self, forKey: .quality) ?? .exhigh
        wifiOnly = try c.decodeIfPresent(Bool.self, forKey: .wifiOnly) ?? true
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        librarySort = try c.decodeIfPresent([String: LibrarySort].self, forKey: .librarySort) ?? [:]
    }
}
struct ListeningHistory: Codable { var lastPlayed: [Int64: Date] = [:]; var recent: [Track] = [] }
struct PendingMutation: Identifiable, Codable {
    enum Kind: String, Codable { case like, addTracks, removeTracks }
    var id = UUID()
    var accountID: Int64
    var kind: Kind
    var trackIDs: [Int64]
    var targetID: Int64
    var liked: Bool?
    var status: String = "等待同步"
}
