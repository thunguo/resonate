import Foundation

public protocol ResourceStorage: Sendable {
    func read(_ key: String) async throws -> Data?
    func write(_ data: Data, key: String) async throws
    func remove(prefix: String) async throws
}

public struct CachedValue<Value: Codable & Sendable>: Codable, Sendable {
    public var value: Value
    public var updatedAt: Date
    public init(_ value: Value, updatedAt: Date = .now) { self.value = value; self.updatedAt = updatedAt }
}

public enum Freshness {
    public static let profile: TimeInterval = 1800
    public static let collection: TimeInterval = 300
    public static let discoveries: TimeInterval = 21600
    public static let metadata: TimeInterval = 86400
    public static let lyrics: TimeInterval = 604800
    public static let search: TimeInterval = 600
}

/// Account-qualified keys are required. A refresh belongs to the repository, not an individual screen.
public actor MusicRepository {
    private struct Flight { let id: UUID; let task: Task<Data, Error> }
    private let storage: any ResourceStorage
    private var memory: [String: Data] = [:]
    private var decoded: [String: any Sendable] = [:]
    private var access: [String: Date] = [:]
    private var flights: [String: Flight] = [:]
    private var revision = UUID()
    private var listeners: [String: [UUID: @Sendable (any Sendable) -> Void]] = [:]
    private let memoryLimit = 16 * 1024 * 1024

    public init(storage: any ResourceStorage) { self.storage = storage }

    public func cached<Value: Codable & Sendable>(_ type: Value.Type, key: String) async throws -> CachedValue<Value>? {
        if let cached = decoded[key] as? CachedValue<Value> { access[key] = .now; return cached }
        let epoch = revision
        let data: Data?
        if let saved = memory[key] { data = saved }
        else { data = try await storage.read(key) }
        guard epoch == revision else { throw CancellationError() }
        guard let data else { return nil }
        let result = try SnapshotCodec.decode(CachedValue<Value>.self, from: data)
        remember(data, key: key); if memory[key] != nil { decoded[key] = result }
        return result
    }

    public func memorySnapshot<Value: Codable & Sendable>(_ type: Value.Type, key: String) -> CachedValue<Value>? {
        decoded[key] as? CachedValue<Value>
    }

    public nonisolated func updates<Value: Codable & Sendable>(
        _ type: Value.Type, key: String, lifetime: TimeInterval, refresh: Bool = false,
        fetch: @escaping @Sendable () async throws -> Value
    ) -> AsyncThrowingStream<Value, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let cached = try await self.cached(type, key: key)
                    try Task.checkCancellation()
                    if let cached {
                        continuation.yield(cached.value)
                        if !refresh, Date().timeIntervalSince(cached.updatedAt) < lifetime { continuation.finish(); return }
                    }
                    let fresh = try await self.refresh(type, key: key, fetch: fetch)
                    try Task.checkCancellation()
                    continuation.yield(fresh); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public nonisolated func progressiveUpdates<Value: Codable & Sendable>(
        _ type: Value.Type, key: String, lifetime: TimeInterval, refresh: Bool = false,
        fetch: @escaping @Sendable (@escaping @Sendable (Value) async -> Void) async throws -> Value
    ) -> AsyncThrowingStream<Value, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            let task = Task {
                defer { Task { await self.unsubscribe(key, id: id) } }
                do {
                    let cached = try await self.cached(type, key: key)
                    try Task.checkCancellation()
                    if let cached {
                        continuation.yield(cached.value)
                        if !refresh, Date().timeIntervalSince(cached.updatedAt) < lifetime { continuation.finish(); return }
                    }
                    let epoch = await self.subscribe(key, id: id) { value in
                        if let value = value as? Value { continuation.yield(value) }
                    }
                    let fresh = try await self.refresh(type, key: key) {
                        try await fetch { value in await self.publish(value, key: key, epoch: epoch) }
                    }
                    try Task.checkCancellation(); continuation.yield(fresh); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private func subscribe(_ key: String, id: UUID, send: @escaping @Sendable (any Sendable) -> Void) -> UUID {
        listeners[key, default: [:]][id] = send; return revision
    }
    private func unsubscribe(_ key: String, id: UUID) { listeners[key]?[id] = nil; if listeners[key]?.isEmpty == true { listeners[key] = nil } }
    private func publish<Value: Sendable>(_ value: Value, key: String, epoch: UUID) {
        guard epoch == revision else { return }; for send in listeners[key]?.values ?? [:].values { send(value) }
    }

    public func value<Value: Codable & Sendable>(
        _ type: Value.Type, key: String, lifetime: TimeInterval, refresh: Bool = false,
        fetch: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let cached = try await cached(type, key: key)
        if let cached, !refresh, Date().timeIntervalSince(cached.updatedAt) < lifetime { return cached.value }
        return try await self.refresh(type, key: key, fetch: fetch)
    }

    public func store<Value: Codable & Sendable>(_ value: Value, key: String, updatedAt: Date = .now) async throws {
        try Task.checkCancellation(); let epoch = revision
        let data = try SnapshotCodec.encode(CachedValue(value, updatedAt: updatedAt))
        try await storage.write(data, key: key)
        guard epoch == revision else { throw CancellationError() }
        remember(data, key: key); if memory[key] != nil { decoded[key] = CachedValue(value, updatedAt: updatedAt) }
    }

    public func invalidate(_ key: String) async throws {
        flights.removeValue(forKey: key)?.task.cancel()
        memory.removeValue(forKey: key); decoded.removeValue(forKey: key); access.removeValue(forKey: key)
        // Keep stale content available; only its freshness changes.
        if let data = try await storage.read(key) {
            var envelope = try SnapshotCodec.decode(JSONValue.self, from: data)
            if case .object(var fields) = envelope {
                fields["updatedAt"] = .number(Date.distantPast.timeIntervalSinceReferenceDate)
                envelope = .object(fields)
                try await storage.write(SnapshotCodec.encode(envelope), key: key)
            }
        }
    }

    public func reset(removing prefix: String? = nil) async throws {
        revision = UUID(); flights.values.forEach { $0.task.cancel() }; flights = [:]
        memory = [:]; decoded = [:]; access = [:]; listeners = [:]
        if let prefix { try await storage.remove(prefix: prefix) }
    }

    private func refresh<Value: Codable & Sendable>(
        _ type: Value.Type, key: String, fetch: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let epoch = revision
        if let flight = flights[key] {
            let data = try await flight.task.value
            try Task.checkCancellation(); guard epoch == revision else { throw CancellationError() }
            return try (decoded[key] as? CachedValue<Value>)?.value ?? SnapshotCodec.decode(CachedValue<Value>.self, from: data).value
        }
        let id = UUID()
        let task = Task<Data, Error> {
            let cached = CachedValue(try await fetch())
            try Task.checkCancellation()
            guard epoch == revision, flights[key]?.id == id else { throw CancellationError() }
            let data = try SnapshotCodec.encode(cached)
            try await storage.write(data, key: key)
            try Task.checkCancellation(); guard epoch == revision else { throw CancellationError() }
            remember(data, key: key); if memory[key] != nil { decoded[key] = cached }
            return data
        }
        flights[key] = Flight(id: id, task: task)
        defer { if flights[key]?.id == id { flights[key] = nil } }
        let data = try await task.value
        try Task.checkCancellation(); guard epoch == revision else { throw CancellationError() }
        return try (decoded[key] as? CachedValue<Value>)?.value ?? SnapshotCodec.decode(CachedValue<Value>.self, from: data).value
    }

    private func remember(_ data: Data, key: String) {
        memory[key] = data; access[key] = .now
        var size = memory.values.reduce(0) { $0 + $1.count }
        for (old, _) in access.sorted(by: { $0.value < $1.value }) where size > memoryLimit {
            size -= memory.removeValue(forKey: old)?.count ?? 0; access.removeValue(forKey: old); decoded.removeValue(forKey: old)
        }
    }
}

public actor LocalMusicIndex {
    private struct Entry { let track: Track; let text: String }
    private var entries: [Entry] = []
    private var revision = 0
    public init() {}
    public func replace(_ tracks: [Track], revision: Int? = nil) {
        if let revision { guard revision >= self.revision else { return }; self.revision = revision }
        var seen = Set<Int64>()
        entries = tracks.filter { seen.insert($0.id).inserted }.map { Entry(track: $0, text: Self.fold($0.title + " " + $0.artistName + " " + $0.album.name)) }
    }
    public func search(_ query: String, limit: Int = 50) -> [Track] {
        let words = Self.fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        return Array(entries.lazy.filter { entry in words.allSatisfy { entry.text.contains($0) } }.prefix(limit).map(\.track))
    }
    private static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN")) }
}

public struct PreheatConditions: Sendable {
    public var wifi: Bool; public var constrained: Bool; public var lowPower: Bool
    public var nominalTemperature: Bool; public var charging: Bool; public var battery: Float
    public var freeBytes: Int64; public var foreground: Bool
    public init(wifi: Bool, constrained: Bool, lowPower: Bool, nominalTemperature: Bool, charging: Bool, battery: Float, freeBytes: Int64, foreground: Bool) {
        self.wifi = wifi; self.constrained = constrained; self.lowPower = lowPower; self.nominalTemperature = nominalTemperature
        self.charging = charging; self.battery = battery; self.freeBytes = freeBytes; self.foreground = foreground
    }
    public var allowsExpandedPreheat: Bool {
        foreground && wifi && !constrained && !lowPower && nominalTemperature && (charging || battery > 0.4) && freeBytes > 1_000_000_000
    }
}
