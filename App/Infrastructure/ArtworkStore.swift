import MusicCore
import UIKit
import CryptoKit
import ImageIO
import CoreImage

final class ArtworkMemory: @unchecked Sendable {
    static let shared = ArtworkMemory()
    private let images = NSCache<NSString, UIImage>()
    private init() { images.totalCostLimit = 64 * 1024 * 1024 }
    func image(_ url: URL, pixels: Int) -> UIImage? { images.object(forKey: "\(url.absoluteString)|\(pixels)" as NSString) }
    func insert(_ image: UIImage, url: URL, pixels: Int) {
        images.setObject(image, forKey: "\(url.absoluteString)|\(pixels)" as NSString, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
    }
    func clear() { images.removeAllObjects() }
    static func size(_ pixels: Int) -> Int { [160, 384, 768, 1200].first { $0 >= pixels } ?? 1200 }
}

actor ArtworkStore {
    static let shared = ArtworkStore()
    private struct Entry: Codable { var bytes: Int; var lastAccess: Date }
    private var index: [String: Entry] = [:]
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var tints: [URL: UIColor] = [:]
    private let context = CIContext(options: [.workingColorSpace: NSNull()])
    private var generation = UUID()
    private var indexWrite: Task<Void, Never>?
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Artwork", isDirectory: true)
    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) { index = saved }
    }
    var byteCount: Int { index.values.reduce(0) { $0 + $1.bytes } }
    func contains(_ url: URL) -> Bool { index[key(url)] != nil }
    func image(_ url: URL, pixels: Int = 768) async throws -> UIImage {
        let pixels = ArtworkMemory.size(pixels)
        if let image = ArtworkMemory.shared.image(url, pixels: pixels) { return image }
        guard url.scheme == "https" else { throw URLError(.badURL) }
        let epoch = generation, key = key(url), file = directory.appendingPathComponent(key)
        var data = try? Data(contentsOf: file)
        if data == nil {
            let task: Task<Data, Error>
            if let pending = inFlight[key] { task = pending }
            else {
                task = Task {
                    let request = URLRequest(url: url, timeoutInterval: 20)
                    let data = try await LimitedDataLoader.load(request, limit: 12 * 1024 * 1024).0
                    guard generation == epoch else { throw CancellationError() }
                    try store(data, url: url); return data
                }
                inFlight[key] = task
            }
            defer { if generation == epoch { inFlight[key] = nil } }
            data = try await task.value
            guard epoch == generation else { throw CancellationError() }
        }
        guard let data, let image = Self.decode(data, pixels: pixels) else { throw URLError(.cannotDecodeContentData) }
        guard epoch == generation else { throw CancellationError() }
        index[key]?.lastAccess = .now; scheduleIndexWrite()
        ArtworkMemory.shared.insert(image, url: url, pixels: pixels)
        return image
    }
    func preheat(_ url: URL, budget: PreheatBudget) async throws {
        guard !contains(url) else { return }
        let epoch = generation, limit = 2 * 1024 * 1024
        guard await budget.reserve(limit) else { throw URLError(.dataLengthExceedsMaximum) }
        let data = try await LimitedDataLoader.load(URLRequest(url: url, timeoutInterval: 12), limit: limit).0
        try Task.checkCancellation(); guard epoch == generation else { throw CancellationError() }
        try store(data, url: url)
    }
    func tint(_ url: URL) async -> UIColor? {
        if let tint = tints[url] { return tint }
        guard let image = try? await image(url, pixels: 160), let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]), let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let tint = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        tints[url] = tint; return tint
    }
    func clear() {
        generation = UUID(); indexWrite?.cancel(); inFlight.values.forEach { $0.cancel() }; inFlight = [:]
        ArtworkMemory.shared.clear(); tints = [:]; index = [:]
        try? FileManager.default.removeItem(at: directory); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func key(_ url: URL) -> String { SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func store(_ data: Data, url: URL) throws {
        guard let image = Self.decode(data, pixels: 1200), let compressed = image.jpegData(compressionQuality: 0.88) else { throw URLError(.cannotDecodeContentData) }
        let key = key(url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try compressed.write(to: directory.appendingPathComponent(key), options: .atomic)
        index[key] = .init(bytes: compressed.count, lastAccess: .now)
        trim(); scheduleIndexWrite()
    }
    private func trim() {
        var total = byteCount
        for (key, entry) in index.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }) where total > 260 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(key)); index.removeValue(forKey: key); total -= entry.bytes
        }
    }
    private func scheduleIndexWrite() {
        guard indexWrite == nil else { return }
        indexWrite = Task {
            do {
                try await Task.sleep(for: .seconds(2)); try Task.checkCancellation()
                let data = try JSONEncoder().encode(index)
                try data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            } catch { }
            indexWrite = nil
        }
    }
    private static func decode(_ data: Data, pixels: Int) -> UIImage? {
        let measurement = PerformanceInterval(.imageDecode); defer { measurement.end() }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
