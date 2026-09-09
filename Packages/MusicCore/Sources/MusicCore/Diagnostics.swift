import Foundation
import os

public enum DiagnosticEvent: String, Codable, Sendable {
    case startup, firstContent, localSearch, repositoryMemory, repositoryDisk, repositoryNetwork
    case playbackPreparation, playbackBuffering, imageDecode, systemCPU, systemHang, systemCrash
}
public enum DiagnosticOutcome: String, Codable, Sendable { case success, failed, cancelled }
public struct DiagnosticRecord: Codable, Sendable, Equatable {
    public var date: Date
    public var event: DiagnosticEvent
    public var outcome: DiagnosticOutcome
    public var milliseconds: Double
    public init(date: Date = .now, event: DiagnosticEvent, outcome: DiagnosticOutcome = .success, milliseconds: Double) {
        self.date = date; self.event = event; self.outcome = outcome; self.milliseconds = milliseconds.isFinite ? max(0, milliseconds) : 0
    }
}
public actor DiagnosticRecorder {
    public static let shared = DiagnosticRecorder()
    private var records: [DiagnosticRecord] = []
    private var file: URL?
    private var scheduledWrite: Task<Void, Never>?
    private let retention: TimeInterval
    private let maxBytes: Int
    public init(retention: TimeInterval = 7 * 86400, maxBytes: Int = 5 * 1024 * 1024) {
        self.retention = retention; self.maxBytes = maxBytes
    }
    public func configure(file: URL) {
        guard self.file == nil else { return }
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([DiagnosticRecord].self, from: data) {
            records = saved + records
        }
        trim(now: .now)
    }
    public func append(_ record: DiagnosticRecord) {
        records.append(record); trim(now: .now)
        guard scheduledWrite == nil else { return }
        scheduledWrite = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)); await self?.flush() } catch { }
        }
    }
    public func snapshot(now: Date = .now) -> [DiagnosticRecord] { trim(now: now); return records }
    public func clear() throws {
        records = []; scheduledWrite?.cancel(); scheduledWrite = nil
        if let file, FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    public func flush() {
        scheduledWrite = nil; trim(now: .now)
        guard let file, let data = try? JSONEncoder().encode(records) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch { /* Diagnostics must never interrupt listening or overwrite music data. */ }
    }
    private func trim(now: Date) {
        records.removeAll { $0.date < now.addingTimeInterval(-retention) || $0.date > now.addingTimeInterval(60) }
        // A record contains only bounded enums and numbers; this upper bound also avoids repeated encoding on every event.
        let countLimit = max(0, maxBytes / 256)
        if records.count > countLimit { records.removeFirst(records.count - countLimit) }
    }
}
public final class PerformanceInterval: @unchecked Sendable {
    private static let signposter = OSSignposter(subsystem: "space.thunguo.yuyin", category: "Performance")
    private let state: OSSignpostIntervalState
    private let start = ContinuousClock.now
    private let event: DiagnosticEvent
    private let lock = NSLock()
    private var ended = false
    public init(_ event: DiagnosticEvent) {
        self.event = event
        state = Self.signposter.beginInterval("Operation", id: Self.signposter.makeSignpostID(), "\(event.rawValue, privacy: .public)")
    }
    public func end(_ outcome: DiagnosticOutcome = .success) {
        lock.lock(); guard !ended else { lock.unlock(); return }; ended = true; lock.unlock()
        Self.signposter.endInterval("Operation", state, "\(outcome.rawValue, privacy: .public)")
        let elapsed = start.duration(to: .now).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        let record = DiagnosticRecord(event: event, outcome: outcome, milliseconds: ms)
        Task { await DiagnosticRecorder.shared.append(record) }
    }
    deinit { end(.cancelled) }
}
