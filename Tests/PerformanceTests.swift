import XCTest
import SwiftData
import MusicCore
@testable import Yuyin

@MainActor final class PerformanceTests: XCTestCase {
    func testWarmCacheAndDiskPreviewLatency() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MusicPerformance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(for: StoredRecord.self, StoredTrack.self, configurations: ModelConfiguration(url: directory.appendingPathComponent("Music.sqlite")))
        let worker = BackgroundPersistence(modelContainer: container)
        let repository = MusicRepository(storage: worker)
        let songs = (1...10000).map { Track(id: Int64($0), title: "歌曲 \($0)", artists: [.init(id: 1, name: "音乐人")], album: .init(id: 1, name: "专辑"), duration: 180) }
        let key = "account.99.cache.playlist.1"
        try await repository.store(songs, key: key)
        var memoryTimes: [Double] = [], previewTimes: [Double] = []
        for _ in 0..<30 {
            var start = CFAbsoluteTimeGetCurrent()
            let cached = try await repository.cached([Track].self, key: key)
            memoryTimes.append(CFAbsoluteTimeGetCurrent() - start)
            XCTAssertEqual(cached?.value.count, 10000)
            start = CFAbsoluteTimeGetCurrent()
            let preview = try await worker.trackPreview(key: key)
            previewTimes.append(CFAbsoluteTimeGetCurrent() - start)
            XCTAssertEqual(preview?.count, 10000)
            XCTAssertEqual(preview?.filter { $0.metadataPending != true }.count, 60)
        }
        let memoryP95 = memoryTimes.sorted()[28], previewP95 = previewTimes.sorted()[28]
        print(String(format: "PERFORMANCE memory-cache-p95=%.2fms persistent-store-first-batch-p95=%.2fms samples=30 tracks=10000", memoryP95 * 1000, previewP95 * 1000))
        XCTAssertLessThan(memoryP95, 0.100)
        XCTAssertLessThan(previewP95, 0.200)
    }
}
