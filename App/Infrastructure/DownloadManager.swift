import Foundation
import Observation
import MusicCore

struct DownloadRecord: Codable, Identifiable {
    enum Status: String, Codable { case waiting, downloading, paused, complete, failed }
    var id: UUID = UUID()
    var accountID: Int64
    var track: Track
    var status: Status = .waiting
    var progress: Double = 0
    var bytes: Int64 = 0
    var filename: String?
    var resumeData: Data?
    var licenseExpiresAt: Date
    var error: String?
}
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: ((UUID, Double) -> Void)?
    var onComplete: ((UUID, URL, Int64) -> Void)?
    var onFailure: ((UUID, Error) -> Void)?
    var onEventsFinished: (() -> Void)?
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let raw = downloadTask.taskDescription, let id = UUID(uuidString: raw) else { return }
        onProgress?(id, totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let raw = downloadTask.taskDescription, let id = UUID(uuidString: raw) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw MusicError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw NSError(domain: "YuyinDownloadHTTP", code: response.statusCode) }
            guard response.mimeType?.contains("json") != true, response.mimeType?.contains("html") != true else { throw MusicError.invalidResponse }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: staging)
            let bytes = (try staging.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard bytes > 0 else { throw MusicError.invalidResponse }
            onComplete?(id, staging, Int64(bytes))
        } catch { onFailure?(id, error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled, let raw = task.taskDescription, let id = UUID(uuidString: raw) else { return }
        onFailure?(id, error)
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { onEventsFinished?() }
}
@MainActor @Observable final class DownloadManager {
    private(set) var records: [DownloadRecord] = []
    var wifiOnly = true {
        didSet {
            guard wifiOnly != oldValue else { return }
            schedulingSuspended = true
            networkPolicy = UUID()
            for record in records where record.status == .downloading || record.status == .waiting { pause(record.id) }
            for index in records.indices { records[index].resumeData = nil }
            schedulingSuspended = false
            persist()
        }
    }
    var onChange: (([DownloadRecord]) -> Void)?
    var backgroundCompletion: (() -> Void)?
    private(set) var accountID: Int64 = 0
    @ObservationIgnored private let music: MusicService
    @ObservationIgnored private let delegate = DownloadDelegate()
    @ObservationIgnored private var preparations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var active = Set<UUID>()
    @ObservationIgnored private var automaticRetries: [UUID: Int] = [:]
    @ObservationIgnored private var resumedAttempts = Set<UUID>()
    @ObservationIgnored private var schedulingSuspended = false
    @ObservationIgnored private var networkPolicy = UUID()
    @ObservationIgnored private var session: URLSession!
    static let sessionID = "space.thunguo.yuyin.downloads"
    var authorizationExpiry: Date? {
        guard Bundle.main.object(forInfoDictionaryKey: "YYOfflineDownloadEnabled") as? Bool == true, let raw = Bundle.main.object(forInfoDictionaryKey: "YYOfflineAuthorizationValidUntil") as? String, let date = ISO8601DateFormatter().date(from: raw), date > Date() else { return nil }
        return date
    }
    var isAuthorized: Bool { authorizationExpiry != nil }
    var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Offline", isDirectory: true) }
    init(music: MusicService) {
        self.music = music
        delegate.onProgress = { [weak self] id, progress in Task { @MainActor in self?.progress(id, progress) } }
        delegate.onComplete = { [weak self] id, url, bytes in Task { @MainActor in self?.complete(id, url, bytes) } }
        delegate.onFailure = { [weak self] id, error in Task { @MainActor in self?.failed(id, error) } }
        delegate.onEventsFinished = { [weak self] in Task { @MainActor in self?.backgroundCompletion?(); self?.backgroundCompletion = nil } }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.waitsForConnectivity = true; config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    func configure(accountID: Int64, records: [DownloadRecord]) {
        preparations.values.forEach { $0.cancel() }; preparations = [:]; active = []; automaticRetries = [:]
        self.accountID = accountID; self.records = records.filter { $0.accountID == accountID }
        session.getAllTasks { [weak self] tasks in Task { @MainActor in
            guard let self, self.accountID == accountID else { return }
            let valid = Set(self.records.map(\.id))
            for task in tasks where !valid.contains(UUID(uuidString: task.taskDescription ?? "") ?? UUID()) { task.cancel() }
            let active = Set(tasks.compactMap { $0.taskDescription }.compactMap(UUID.init(uuidString:))).intersection(valid)
            self.active = active
            for index in self.records.indices where [.waiting, .downloading].contains(self.records[index].status) && !active.contains(self.records[index].id) { self.records[index].status = .paused }
            self.persist()
        } }
    }
    func enqueue(_ track: Track) throws {
        guard accountID > 0 else { throw MusicError.loginRequired }
        guard let expiry = authorizationExpiry else { throw MusicError.message("离线下载尚未开放。获得相应下载授权后，此功能会在更新中启用。") }
        guard !records.contains(where: { $0.track.id == track.id }) else { return }
        let record = DownloadRecord(accountID: accountID, track: track, licenseExpiresAt: expiry)
        records.append(record); persist(); start(record.id)
    }
    func start(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }), !active.contains(id), record.status != .complete else { return }
        guard record.licenseExpiresAt > Date(), isAuthorized else { update(id) { $0.status = .failed; $0.error = "下载授权已到期" }; persist(); return }
        update(id) { $0.status = .waiting; $0.error = nil }; persist()
        guard active.count < 2 else { return }
        active.insert(id)
        preparations[id]?.cancel()
        preparations[id] = Task { [weak self] in
            guard let self else { return }
            do {
                // Recheck this track's download endpoint even when resuming a saved transfer.
                let resource = try await music.resource(record.track.id, quality: .exhigh, download: true)
                try Task.checkCancellation()
                guard accountID == record.accountID, active.contains(id), records.contains(where: { $0.id == id }) else { return }
                guard isAuthorized, record.licenseExpiresAt > Date() else { throw MusicError.message("下载授权已到期") }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                let required = max(32 * 1024 * 1024, resource.expectedBytes ?? 0)
                if let free, free < required { throw CocoaError(.fileWriteOutOfSpace) }
                let task: URLSessionDownloadTask
                if let resumeData = record.resumeData { resumedAttempts.insert(id); task = session.downloadTask(withResumeData: resumeData) }
                else {
                    var request = URLRequest(url: resource.url); request.allowsCellularAccess = !wifiOnly; request.allowsExpensiveNetworkAccess = !wifiOnly
                    task = session.downloadTask(with: request)
                }
                update(id) { $0.filename = "\(record.accountID)-\(record.track.id).\(resource.fileExtension)" }
                task.taskDescription = id.uuidString; update(id) { $0.status = .downloading; $0.error = nil; $0.resumeData = nil }; task.resume(); persist()
            } catch is CancellationError { }
            catch { if !Task.isCancelled { failed(id, error) } }
        }
    }
    func pause(_ id: UUID) {
        preparations[id]?.cancel(); preparations[id] = nil; active.remove(id)
        let policy = networkPolicy
        update(id) { $0.status = .paused }; persist()
        session.getAllTasks { [weak self] tasks in
            for case let task as URLSessionDownloadTask in tasks where task.taskDescription == id.uuidString {
                task.cancel { [weak self] data in Task { @MainActor [weak self] in guard let self, self.networkPolicy == policy else { return }; self.update(id) { if $0.status == .paused { $0.resumeData = data } }; self.persist() } }
            }
        }
        pump()
    }
    private func pump() {
        guard !schedulingSuspended else { return }
        for record in records where record.status == .waiting && !active.contains(record.id) {
            guard active.count < 2 else { break }; start(record.id)
        }
    }
    func remove(_ id: UUID) {
        pause(id)
        if let record = records.first(where: { $0.id == id }), let filename = record.filename { try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename)) }
        records.removeAll { $0.id == id }; persist()
    }
    func clearAccount() { schedulingSuspended = true; for record in records { remove(record.id) }; records = []; active = []; resumedAttempts = []; accountID = 0; schedulingSuspended = false; persist() }
    func localURL(for track: Track) -> URL? {
        guard isAuthorized, let record = records.first(where: { $0.accountID == accountID && $0.track.id == track.id && $0.status == .complete && $0.licenseExpiresAt > Date() }), let filename = record.filename else { return nil }
        let url = directory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    private func update(_ id: UUID, _ body: (inout DownloadRecord) -> Void) { if let i = records.firstIndex(where: { $0.id == id }) { body(&records[i]) } }
    private func persist() { onChange?(records) }
    private func progress(_ id: UUID, _ value: Double) { update(id) { $0.progress = value } }
    private func complete(_ id: UUID, _ staging: URL, _ bytes: Int64) {
        defer { try? FileManager.default.removeItem(at: staging) }
        active.remove(id); preparations[id] = nil
        defer { pump() }
        guard let record = records.first(where: { $0.id == id }), record.accountID == accountID, record.status == .downloading, let filename = record.filename else { return }
        guard record.licenseExpiresAt > Date(), isAuthorized else { update(id) { $0.status = .failed; $0.error = "下载授权已到期" }; persist(); return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: staging, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            var file = destination; var values = URLResourceValues(); values.isExcludedFromBackup = true; try file.setResourceValues(values)
            update(id) { $0.status = .complete; $0.progress = 1; $0.bytes = bytes; $0.resumeData = nil }; persist()
        } catch { failed(id, error) }
    }
    private func failed(_ id: UUID, _ error: Error) {
        active.remove(id); preparations[id] = nil
        guard let record = records.first(where: { $0.id == id }), record.status != .paused else { pump(); return }
        let failure = error as NSError
        let wasResumed = resumedAttempts.remove(id) != nil
        let retryable = (wasResumed && failure.domain == NSURLErrorDomain) || (failure.domain == "YuyinDownloadHTTP" && [401, 403].contains(failure.code))
        if retryable, automaticRetries[id, default: 0] < 1 {
            automaticRetries[id, default: 0] += 1
            update(id) { $0.status = .waiting; $0.resumeData = nil }; persist(); pump(); return
        }
        let outOfSpace = (failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteOutOfSpaceError) || (failure.domain == NSPOSIXErrorDomain && failure.code == 28)
        update(id) {
            $0.status = .failed; $0.resumeData = failure.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            $0.error = outOfSpace ? "可用空间不足，请清理下载或设备存储后重试。" : error as? MusicError == .unavailable ? "这首歌暂时没有完整下载资格。" : "下载未完成，可点按重试。"
        }
        persist(); pump()
    }
}
