import Foundation
import Network
import UIKit
import MusicCore

final class LimitedDataLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var cancelled = false
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    static func load(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let loader = LimitedDataLoader(limit: limit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { loader.start(request, continuation: $0) }
        } onCancel: { loader.cancel() }
    }
    private func start(_ request: URLRequest, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.allowsConstrainedNetworkAccess = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session; let task = session.dataTask(with: request); self.task = task; task.resume()
    }
    private func cancel() { lock.lock(); cancelled = true; task?.cancel(); lock.unlock() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        completionHandler(request.url?.scheme == "https" && request.url?.host == original?.host && request.url?.port == original?.port ? request : nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), response.expectedContentLength <= limit else { completionHandler(.cancel); return }
        self.response = response; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard buffer.count + data.count <= limit else { dataTask.cancel(); return }
        buffer.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let completion = continuation; continuation = nil; lock.unlock()
        if let error { completion?.resume(throwing: error) }
        else if let response { completion?.resume(returning: (buffer, response)) }
        else { completion?.resume(throwing: URLError(.badServerResponse)) }
        session.finishTasksAndInvalidate(); self.session = nil
    }
}

actor PreheatBudget {
    static let shared = PreheatBudget()
    private let defaults = UserDefaults.standard
    func reserve(_ bytes: Int) -> Bool {
        let day = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        if defaults.double(forKey: "preheat.day") != day { defaults.set(day, forKey: "preheat.day"); defaults.set(0, forKey: "preheat.bytes") }
        let used = defaults.integer(forKey: "preheat.bytes")
        guard used + bytes <= 100 * 1024 * 1024 else { return false }
        defaults.set(used + bytes, forKey: "preheat.bytes"); return true
    }
}

private struct PreheatTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let limit = 512 * 1024
        guard await PreheatBudget.shared.reserve(limit) else { throw URLError(.dataLengthExceedsMaximum) }
        return try await LimitedDataLoader.load(request, limit: limit)
    }
}

@MainActor final class SmartPreheater {
    private let monitor = NWPathMonitor()
    private var path: NWPath?
    private var task: Task<Void, Never>?
    private var activityAt = Date()
    private var notifications: [NSObjectProtocol] = []
    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification, UIDevice.batteryStateDidChangeNotification, UIApplication.didEnterBackgroundNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.canExpand != true { self?.stop() } }
            })
        }
        monitor.pathUpdateHandler = { [weak self] path in Task { @MainActor in self?.path = path; if self?.canExpand != true { self?.stop() } } }
        monitor.start(queue: DispatchQueue(label: "music.preheat.network"))
    }
    deinit { monitor.cancel(); task?.cancel(); notifications.forEach { NotificationCenter.default.removeObserver($0) } }
    func stop() { task?.cancel(); task = nil }
    func userActivity() { activityAt = .now; stop() }
    private var canExpand: Bool {
        let capacity = try? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        return PreheatConditions(wifi: path?.status == .satisfied && path?.usesInterfaceType(.wifi) == true && path?.isExpensive == false,
            constrained: path?.isConstrained ?? true, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            nominalTemperature: ProcessInfo.processInfo.thermalState == .nominal,
            charging: UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full,
            battery: UIDevice.current.batteryLevel, freeBytes: capacity ?? 0, foreground: UIApplication.shared.applicationState == .active).allowsExpandedPreheat
    }
    func schedule(playlists: [Playlist], tracks: [Track], music: MusicService, repository: MusicRepository, prefix: String) {
        stop(); activityAt = .now
        task = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
                guard let self, self.canExpand, Date().timeIntervalSince(self.activityAt) >= 10 else { return }
                let service = MusicService(baseURL: await music.baseURL, transport: PreheatTransport())
                if let data = Keychain.read("netease.cookie"), let cookie = String(data: data, encoding: .utf8) { await service.setCookie(cookie) }
                for playlist in playlists.prefix(20) {
                    try Task.checkCancellation(); guard self.canExpand else { return }
                    if let cached = try await repository.cached([Track].self, key: prefix + "playlist.\(playlist.id)"), Date().timeIntervalSince(cached.updatedAt) < Freshness.collection { continue }
                    _ = try await repository.value([Track].self, key: prefix + "playlist.\(playlist.id)", lifetime: Freshness.collection) { try await service.playlistTracks(playlist.id) }
                    try Task.checkCancellation()
                }
                var seen = Set<URL>()
                for track in tracks.prefix(200) {
                    try Task.checkCancellation(); guard self.canExpand else { return }
                    if let url = track.album.artwork, seen.insert(url).inserted { try await ArtworkStore.shared.preheat(url, budget: .shared) }
                }
            } catch { }
        }
    }
}
