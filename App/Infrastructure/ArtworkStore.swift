import UIKit
import CryptoKit
import ImageIO
import CoreImage

actor ArtworkStore {
    static let shared = ArtworkStore()
    private struct Entry: Codable { var bytes: Int; var lastAccess: Date }
    private var index: [String: Entry] = [:]
    private var inFlight: [String: Task<UIImage, Error>] = [:]
    private let images = NSCache<NSString, UIImage>()
    private var generation = UUID()
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Artwork", isDirectory: true)
    init() {
        images.totalCostLimit = 32 * 1024 * 1024
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) { index = saved }
    }
    var byteCount: Int { index.values.reduce(0) { $0 + $1.bytes } }
    func image(_ url: URL) async throws -> UIImage {
        guard url.scheme == "https" else { throw URLError(.badURL) }
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        if let image = images.object(forKey: key as NSString) { return image }
        if let pending = inFlight[key] { return try await pending.value }
        let epoch = generation, file = directory.appendingPathComponent(key)
        if let data = try? Data(contentsOf: file), let image = Self.decode(data) {
            index[key]?.lastAccess = .now; cache(image, key); return image
        }
        let task = Task<UIImage, Error> {
            let (data, response) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 12 * 1024 * 1024, let image = Self.decode(data) else { throw URLError(.cannotDecodeContentData) }
            if generation == epoch {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                do { try data.write(to: file, options: .atomic); index[key] = .init(bytes: data.count, lastAccess: .now); trim() } catch { }
                cache(image, key)
            }
            return image
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
    func tint(_ url: URL) async -> UIColor? {
        guard let image = try? await image(url), let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]), let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
    func clear() {
        generation = UUID(); inFlight.values.forEach { $0.cancel() }; inFlight = [:]; images.removeAllObjects(); index = [:]
        try? FileManager.default.removeItem(at: directory); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func cache(_ image: UIImage, _ key: String) { images.setObject(image, forKey: key as NSString, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)) }
    private func trim() {
        var total = byteCount
        for (key, entry) in index.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }) where total > 80 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(key)); index.removeValue(forKey: key); total -= entry.bytes
        }
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic) }
    }
    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
