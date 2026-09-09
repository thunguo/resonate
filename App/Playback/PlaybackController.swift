import Foundation
import AVFoundation
import MediaPlayer
import Observation
import MusicCore

enum PlaybackPhase: String, Equatable {
    case idle, restoring, preparing, playing, paused, interrupted, ended, failed
    var label: String {
        switch self {
        case .idle: "还没有正在听的歌"
        case .restoring: "恢复中"
        case .preparing: "准备播放"
        case .playing: "正在播放"
        case .paused: "已暂停"
        case .interrupted: "播放已中断"
        case .ended: "播放结束"
        case .failed: "暂时无法播放"
        }
    }
}
struct PlaybackSnapshot: Equatable {
    var phase: PlaybackPhase
    var trackID: Int64?
    var offersPause: Bool
}

@MainActor @Observable final class PlaybackController {
    var queue = QueueState()
    var restorationPending = false
    @ObservationIgnored private var resumeAfterRestoration = false
    @ObservationIgnored private var pendingAppends: [([Track], Bool)] = []
    @ObservationIgnored private var pendingSeek: Double?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var resource: PlaybackResource?
    private(set) var error: String?
    private(set) var operationError: String?
    private(set) var sleepDate: Date?
    private(set) var isInterrupted = false
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var seekID = UUID()
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var preparationMeasurement: PerformanceInterval?
    @ObservationIgnored private var bufferingMeasurement: PerformanceInterval?
    var quality: AudioQuality = .exhigh { didSet { if oldValue != quality { discardPrepared(); prepareNext() } } }
    var onCheckpoint: ((PlaybackCheckpoint) -> Void)?
    var onSave: ((QueueState) -> Void)?
    var onTrackPlayed: ((Track) -> Void)?
    var onPlaybackAttempt: (() -> Void)?
    var onPlaybackStart: ((Double) -> Void)?
    var onStateChanged: (() -> Void)?
    var cachedTrack: ((Int64) async -> Track?)?
    var offlineURL: ((Track) -> URL?)?
    var continuationTracks: (() async throws -> [Track])?
    var previousQueue: QueueState?
    private struct AuditionReturnPoint {
        var queue: QueueState
        var playing: Bool
        var previousQueue: QueueState?
    }
    private(set) var isAuditioning = false
    @ObservationIgnored private var auditionReturn: AuditionReturnPoint?
    var restorableQueue: QueueState {
        if let auditionReturn { return auditionReturn.queue }
        var saved = queue; saved.position = position; return saved
    }
    @ObservationIgnored private let music: MusicService
    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    private var wantsPlayback = false
    @ObservationIgnored private var resolving = false
    private var reachedEnd = false
    @ObservationIgnored private var attemptStartedAt: Date?
    @ObservationIgnored private var reportedStart = false
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchKey: String?
    @ObservationIgnored private var prefetched: (entryID: UUID, quality: AudioQuality, resource: PlaybackResource?, item: AVPlayerItem)?
    @ObservationIgnored private var preparedQueue: QueueState?
    @ObservationIgnored private var resourceCache: [String: PlaybackResource] = [:]
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var restoredPosition: Double = 0
    @ObservationIgnored private var lastSavedAt: Double = -1
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    init(music: MusicService) {
        self.music = music
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause
        observation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.updateStatus() } }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in Task { @MainActor in self?.tick(time.seconds) } }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }; self.ended() }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in Task { @MainActor in self?.interrupted(n) } })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor in self?.pause() } }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }; self.handleFailure() }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; let resume = self.wantsPlayback; self.loadingTask?.cancel(); self.loadID = UUID(); self.player.removeAllItems(); self.itemObservation = nil; self.prefetchTask?.cancel(); self.discardPrepared(); self.queue.position = self.position; if resume { self.loadCurrent(retrying: true) } else { self.pause() } }
        })
        installRemoteCommands()
    }
    private(set) var currentTrackID: Int64?
    var current: Track? { queue.current?.track }
    var isPreview: Bool { resource?.availability == .preview }
    var snapshot: PlaybackSnapshot {
        let phase: PlaybackPhase
        if restorationPending { phase = .restoring }
        else if current == nil { phase = .idle }
        else if error != nil { phase = .failed }
        else if isInterrupted { phase = .interrupted }
        else if isPlaying { phase = .playing }
        else if isBuffering { phase = .preparing }
        else if reachedEnd { phase = .ended }
        else { phase = .paused }
        return .init(phase: phase, trackID: currentTrackID, offersPause: isPlaying || isBuffering || (isInterrupted && wantsPlayback))
    }
    func restore(_ state: QueueState) { queue = state; currentTrackID = state.current?.track.id; position = state.position; duration = state.current?.track.duration ?? 0; updateNowPlaying() }
    func play(_ tracks: [Track], at index: Int = 0, origin: QueueOrigin = .playlist) {
        guard !tracks.isEmpty else { return }
        restorationPending = false; resumeAfterRestoration = false; pendingAppends = []; pendingSeek = nil
        previousQueue = auditionReturn?.queue ?? queue; auditionReturn = nil; isAuditioning = false; queue.replace(tracks, startingAt: index, origin: origin); retryCount = 0; loadCurrent()
    }
    @discardableResult func playNow(_ track: Track) -> Bool {
        guard !restorationPending else { operationError = "队列正在恢复，请稍后播放。"; return false }
        if isAuditioning { endAudition() }
        if current?.id == track.id { resume(); return true }
        previousQueue = restorableQueue
        let hadCurrent = queue.current != nil
        queue.append([track], next: true)
        if hadCurrent { queue.advance(manual: true) }
        else { queue.currentID = queue.entries.last?.id; queue.position = 0 }
        retryCount = 0; loadCurrent(); return true
    }
    @discardableResult func beginAudition(_ track: Track) -> Bool {
        guard !restorationPending else { operationError = "队列正在恢复，请稍后试听。"; return false }
        if auditionReturn == nil { save(); auditionReturn = .init(queue: restorableQueue, playing: wantsPlayback, previousQueue: previousQueue) }
        isAuditioning = true; queue.replace([track], origin: .ai); retryCount = 0; loadCurrent(); return true
    }
    func endAudition() {
        guard let saved = auditionReturn else { return }
        auditionReturn = nil; isAuditioning = false
        if saved.queue.entries.isEmpty { clear(); return }
        restore(saved.queue); previousQueue = saved.previousQueue
        retryCount = 0
        if saved.playing { loadCurrent() }
        else {
            loadingTask?.cancel(); seekTask?.cancel(); isSeeking = false; loadID = UUID()
            discardPrepared(); player.pause(); player.removeAllItems(); itemObservation = nil
            wantsPlayback = false; resolving = false; isPlaying = false; isBuffering = false; error = nil; resource = nil; nowPlayingArtwork = nil
            preparationMeasurement?.end(.cancelled); preparationMeasurement = nil
            save(); updateNowPlaying()
        }
    }
    func toggle() { snapshot.offersPause ? pause() : resume() }
    func finishRestoration(_ state: QueueState?) {
        if restorationPending, let state { restore(state) }
        restorationPending = false
        let additions = pendingAppends; pendingAppends = []
        for (tracks, next) in additions { enqueue(tracks, next: next) }
        if let target = pendingSeek { pendingSeek = nil; position = target; queue.position = target }
        if resumeAfterRestoration { resumeAfterRestoration = false; resume() }
    }
    func resume() {
        if restorationPending { resumeAfterRestoration = true; isBuffering = true; return }
        guard current != nil else { return }
        wantsPlayback = true
        guard !isInterrupted else { return }
        if player.currentItem == nil || player.currentItem?.status == .failed {
            retryCount = 0; queue.position = position; loadCurrent()
        } else if reachedEnd {
            reachedEnd = false; seek(0)
            if activateAudio() { player.play() }
        } else if player.currentItem?.status == .readyToPlay, activateAudio() { player.play() }
    }
    func pause() { if restorationPending { resumeAfterRestoration = false; isBuffering = false; return }; wantsPlayback = false; player.pause(); isPlaying = false; isBuffering = false; save(); updateNowPlaying() }
    func next() {
        if isAuditioning { endAudition(); return }
        if let preparedQueue = validPreparedQueue { queue = preparedQueue; retryCount = 0; loadCurrent() }
        else if queue.advance(manual: true) { retryCount = 0; loadCurrent() } else { pause() }
    }
    func previous() { if isAuditioning { endAudition(); return }; queue.position = position; queue.previous(); retryCount = 0; loadCurrent() }
    func jump(_ id: UUID) { guard queue.entries.contains(where: { $0.id == id }) else { return }; queue.currentID = id; queue.position = 0; retryCount = 0; loadCurrent() }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if restorationPending { pendingSeek = max(0, seconds); position = max(0, seconds); return }
        let time = min(max(0, seconds), max(0, duration))
        position = time; queue.position = time; reachedEnd = false
        seekTask?.cancel(); seekID = UUID()
        if player.currentItem?.status == .readyToPlay { performSeek(time) }
        else { restoredPosition = time }
        save(); updateNowPlaying()
    }
    private func performSeek(_ time: Double) {
        seekTask?.cancel()
        let token = UUID(), generation = loadID
        seekID = token; isSeeking = true
        seekTask = Task { [weak self] in
            guard let self else { return }
            _ = await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, generation == loadID, token == seekID else { return }
            isSeeking = false
            if wantsPlayback, !isInterrupted, activateAudio() { player.play() }
            updateNowPlaying()
        }
    }
    func enqueue(_ tracks: [Track], next: Bool = false) { if isAuditioning { endAudition() }; if restorationPending { pendingAppends.append((tracks, next)); return }; previousQueue = queue; queue.append(tracks, next: next); save() }
    @discardableResult func apply(_ arrangement: Arrangement) -> Bool {
        operationError = nil
        if let signature = arrangement.queueSignature, signature != restorableQueue.arrangementSignature { operationError = "队列已经变化，请重新编排后再应用。"; return false }
        if isAuditioning { endAudition() }
        previousQueue = queue; queue.applyArrangement(arrangement.tracks); save(); return true
    }
    func undo() {
        if isAuditioning { endAudition() }
        guard let previousQueue else { return }
        let changedCurrent = queue.currentID != previousQueue.currentID
        queue = previousQueue; self.previousQueue = nil
        if changedCurrent { loadCurrent(startPlaying: wantsPlayback) } else { save() }
    }
    func clear() {
        auditionReturn = nil; isAuditioning = false; operationError = nil
        restorationPending = false; resumeAfterRestoration = false; pendingAppends = []; pendingSeek = nil
        seekTask?.cancel(); isSeeking = false; isInterrupted = false; preparationMeasurement?.end(.cancelled); preparationMeasurement = nil; bufferingMeasurement?.end(.cancelled); bufferingMeasurement = nil
        loadingTask?.cancel(); prefetchTask?.cancel(); prefetched = nil; loadID = UUID(); player.pause(); player.removeAllItems()
        resolving = false; reachedEnd = false; attemptStartedAt = nil; reportedStart = false
        queue = .init(); previousQueue = nil; resourceCache = [:]; preparedQueue = nil; resource = nil; position = 0; duration = 0; error = nil; isPlaying = false; isBuffering = false; wantsPlayback = false
        setSleepTimer(minutes: nil); MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; save()
    }
    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel(); sleepDate = nil
        guard let minutes else { return }
        sleepDate = Date().addingTimeInterval(Double(minutes * 60))
        sleepTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(minutes * 60)); self?.pause(); self?.sleepDate = nil } catch { }
        }
    }
    func save() { guard !restorationPending else { return }; if isAuditioning { currentTrackID = current?.id; onStateChanged?(); return }; currentTrackID = current?.id; queue.position = position; onSave?(queue); onCheckpoint?(.init(currentID: queue.currentID, position: position)); onStateChanged?(); prepareNext() }
    private func checkpoint() { guard !isAuditioning else { return }; onCheckpoint?(.init(currentID: queue.currentID, position: position)) }
    private func discardPrepared() {
        prefetchTask?.cancel(); prefetchKey = nil; prefetched = nil; preparedQueue = nil
        for item in player.items().dropFirst() { player.remove(item) }
    }
    private var validPreparedQueue: QueueState? {
        guard let preparedQueue, preparedQueue.entries == queue.entries,
              preparedQueue.shuffle == queue.shuffle, preparedQueue.repeatMode == queue.repeatMode else { return nil }
        return preparedQueue
    }
    private func loadCurrent(retrying: Bool = false, startPlaying: Bool = true) {
        seekTask?.cancel(); isSeeking = false
        preparationMeasurement?.end(.cancelled)
        preparationMeasurement = PerformanceInterval(.playbackPreparation)
        loadingTask?.cancel(); prefetchTask?.cancel(); prefetchKey = nil; let generation = UUID(); loadID = generation
        resolving = true; reachedEnd = false
        guard let track = current else { resolving = false; isBuffering = false; wantsPlayback = false; return }; currentTrackID = track.id
        lastSavedAt = -1
        if !retrying { attemptStartedAt = .now; reportedStart = false; onPlaybackAttempt?() }
        let prepared = !retrying && prefetched?.entryID == queue.currentID && prefetched?.quality == quality ? prefetched : nil
        let reusable = prepared.map { $0.resource == nil || $0.resource!.expiresAt.timeIntervalSinceNow > 30 } ?? false
        if !reusable { player.pause(); player.removeAllItems() }
        itemObservation = nil
        position = queue.position; restoredPosition = queue.position; duration = track.duration; error = nil; resource = nil; nowPlayingArtwork = nil
        wantsPlayback = startPlaying; isPlaying = false; isBuffering = startPlaying && !isInterrupted
        let localURL = offlineURL?(track)
        prefetched = nil; preparedQueue = nil
        loadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                var track = track
                if track.metadataPending == true {
                    let songs: [Track]
                    if let saved = await cachedTrack?(track.id) { songs = [saved] }
                    else { songs = try await music.tracks(ids: [track.id]) }
                    try Task.checkCancellation(); guard generation == loadID else { return }
                    if let song = songs.first { track = song; if let index = queue.currentIndex { queue.entries[index].track = song }; duration = song.duration }
                }
                let item: AVPlayerItem
                if reusable, let prepared {
                    resource = prepared.resource; item = prepared.item
                } else if let localURL { item = AVPlayerItem(url: localURL) }
                else {
                    let cacheKey = "\(track.id)-\(quality.rawValue)"
                    if retrying { resourceCache[cacheKey] = nil }
                    let r: PlaybackResource
                    if let saved = resourceCache[cacheKey], saved.expiresAt.timeIntervalSinceNow > 30 { r = saved }
                    else { r = try await music.resource(track.id, quality: quality) }
                    try Task.checkCancellation(); guard generation == loadID else { return }
                    resourceCache[cacheKey] = r; resource = r; item = AVPlayerItem(url: r.url)
                }
                try Task.checkCancellation(); guard generation == loadID else { return }
                resolving = false
                item.preferredForwardBufferDuration = 15
                itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
                    let status = observed.status
                    Task { @MainActor in
                        guard let self, generation == self.loadID else { return }
                        if status == .readyToPlay {
                            let actual = self.player.currentItem?.duration.seconds ?? 0
                            if actual.isFinite && actual > 0 { self.duration = actual }
                            let restored = self.restoredPosition; self.restoredPosition = 0
                            if restored > 0 { self.performSeek(min(restored, max(0, self.duration - 0.05))) }
                            else if self.wantsPlayback, !self.isInterrupted, self.activateAudio() { self.player.play() }
                            self.updateNowPlaying(); self.prepareNext()
                        } else if status == .failed { self.handleFailure() }
                    }
                }
                if player.items().contains(where: { $0 === item }), player.currentItem !== item { player.advanceToNextItem() }
                else if player.currentItem !== item { player.removeAllItems(); player.insert(item, after: nil) }
                save(); updateNowPlaying()
                if let artwork = track.album.artwork, let image = try? await ArtworkStore.shared.image(artwork), generation == loadID {
                    nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }; updateNowPlaying()
                }
            } catch is CancellationError { }
            catch {
                guard generation == loadID else { return }
                preparationMeasurement?.end(.failed); preparationMeasurement = nil
                self.error = error.localizedDescription; resolving = false; isBuffering = false; wantsPlayback = false; updateNowPlaying()
            }
        }
    }
    @discardableResult private func activateAudio() -> Bool {
        do { let session = AVAudioSession.sharedInstance(); try session.setCategory(.playback, mode: .default, policy: .longFormAudio); try session.setActive(true); return true }
        catch { self.error = "暂时无法使用音频输出，请检查输出设备。"; pause(); return false }
    }
    private func prepareNext() {
        guard player.currentItem != nil, queue.repeatMode != .one else { discardPrepared(); return }
        if let preparedQueue, let prefetched, preparedQueue.currentID == prefetched.entryID,
           preparedQueue.entries == queue.entries, preparedQueue.shuffle == queue.shuffle,
           preparedQueue.repeatMode == queue.repeatMode, prefetched.quality == quality,
           prefetched.resource == nil || prefetched.resource!.expiresAt.timeIntervalSinceNow > 30 { return }
        var nextQueue = queue
        guard nextQueue.advance(manual: true), let next = nextQueue.current else { discardPrepared(); return }
        let key = "\(loadID)-\(next.id)-\(quality.rawValue)"
        if prefetchKey == key { return }
        discardPrepared(); prefetchKey = key; preparedQueue = nextQueue
        let generation = loadID, requestedQuality = quality, local = offlineURL?(next.track)
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            defer { if prefetchKey == key { prefetchKey = nil } }
            do {
                let resource: PlaybackResource?, item: AVPlayerItem
                if let local { resource = nil; item = AVPlayerItem(url: local) }
                else {
                    let cacheKey = "\(next.track.id)-\(requestedQuality.rawValue)"
                    if let saved = resourceCache[cacheKey], saved.expiresAt.timeIntervalSinceNow > 30 { resource = saved }
                    else { resource = try await music.resource(next.track.id, quality: requestedQuality) }
                    try Task.checkCancellation(); guard generation == loadID else { return }
                    resourceCache[cacheKey] = resource; item = AVPlayerItem(url: resource!.url)
                }
                try Task.checkCancellation()
                guard generation == loadID, requestedQuality == quality, preparedQueue?.currentID == next.id else { return }
                item.preferredForwardBufferDuration = 15
                guard player.canInsert(item, after: player.currentItem) else { return }
                for previous in player.items().dropFirst() { player.remove(previous) }
                player.insert(item, after: player.currentItem)
                prefetched = (next.id, requestedQuality, resource, item)
            } catch { }
        }
    }
    private func tick(_ seconds: Double) {
        guard seconds.isFinite, player.currentItem != nil, !isSeeking, restoredPosition == 0 else { return }
        position = max(0, seconds)
        if abs(position - lastSavedAt) > 10 { lastSavedAt = position; checkpoint() }
    }
    private func updateStatus() {
        isPlaying = wantsPlayback && !isInterrupted && player.timeControlStatus == .playing
        isBuffering = wantsPlayback && !isInterrupted && (resolving || player.currentItem?.status == .unknown || player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        if isBuffering, bufferingMeasurement == nil { bufferingMeasurement = PerformanceInterval(.playbackBuffering) }
        if !isBuffering { bufferingMeasurement?.end(isPlaying ? .success : .cancelled); bufferingMeasurement = nil }
        if isPlaying { preparationMeasurement?.end(.success); preparationMeasurement = nil }
        if isPlaying, !reportedStart, let track = current {
            reportedStart = true; if !isAuditioning { onTrackPlayed?(track) }
            if let attemptStartedAt { onPlaybackStart?(max(0, Date().timeIntervalSince(attemptStartedAt))) }
        }
        updateNowPlaying(); onStateChanged?()
    }
    private func ended() {
        if isAuditioning { endAudition(); return }
        position = duration; queue.position = duration
        guard wantsPlayback else { reachedEnd = true; return }
        if queue.repeatMode == .one {
            seek(0); if activateAudio() { player.play() }; return
        }
        reachedEnd = true
        if let preparedQueue = validPreparedQueue { queue = preparedQueue; retryCount = 0; loadCurrent() }
        else if queue.advance() { retryCount = 0; loadCurrent() }
        else if queue.autoplay, let continuationTracks {
            let generation = loadID
            loadingTask = Task { [weak self] in
                guard let self else { return }
                do { let tracks = try await continuationTracks(); guard generation == loadID, wantsPlayback else { return }; queue.append(tracks, origin: .ai); if queue.advance() { loadCurrent() } else { pause() } }
                catch { guard generation == loadID else { return }; self.error = "暂时无法续播，已保留当前队列。"; pause() }
            }
        } else { pause() }
    }
    private func handleFailure() {
        guard wantsPlayback else { return }
        if retryCount < 1 { retryCount += 1; queue.position = position; loadCurrent(retrying: true) }
        else { error = "播放中断，请重试或选择下一首。"; pause() }
    }
    private func interrupted(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
        if type == .began { isInterrupted = true; player.pause(); isPlaying = false; isBuffering = false; save(); updateNowPlaying() }
        else {
            isInterrupted = false
            let raw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if wantsPlayback, AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) { resume() }
            else { pause() }
        }
    }
    private func installRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
    }
    private func updateNowPlaying() {
        guard let track = current else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artistName, MPMediaItemPropertyAlbumTitle: track.album.name, MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0, MPNowPlayingInfoPropertyDefaultPlaybackRate: 1]
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
