import Foundation
import AVFoundation
import MediaPlayer
import Observation
import MusicCore

@MainActor @Observable final class PlaybackController {
    var queue = QueueState()
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var resource: PlaybackResource?
    private(set) var error: String?
    private(set) var sleepDate: Date?
    var quality: AudioQuality = .exhigh
    var onSave: ((QueueState) -> Void)?
    var onTrackPlayed: ((Track) -> Void)?
    var onPlaybackAttempt: (() -> Void)?
    var onPlaybackStart: ((Double) -> Void)?
    var onStateChanged: (() -> Void)?
    var offlineURL: ((Track) -> URL?)?
    var continuationTracks: (() async throws -> [Track])?
    var previousQueue: QueueState?
    @ObservationIgnored private let music: MusicService
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var resolving = false
    @ObservationIgnored private var reachedEnd = false
    @ObservationIgnored private var attemptStartedAt: Date?
    @ObservationIgnored private var reportedStart = false
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchKey: String?
    @ObservationIgnored private var prefetched: (trackID: Int64, quality: AudioQuality, resource: PlaybackResource, asset: AVURLAsset)?
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var restoredPosition: Double = 0
    @ObservationIgnored private var lastSavedAt: Double = -1
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    init(music: MusicService) {
        self.music = music
        player.automaticallyWaitsToMinimizeStalling = true
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
            Task { @MainActor in guard let self else { return }; let resume = self.wantsPlayback; self.loadingTask?.cancel(); self.loadID = UUID(); self.player.replaceCurrentItem(with: nil); self.itemObservation = nil; self.prefetchTask?.cancel(); self.prefetched = nil; self.queue.position = self.position; if resume { self.loadCurrent(retrying: true) } else { self.pause() } }
        })
        installRemoteCommands()
    }
    var current: Track? { queue.current?.track }
    var isPreview: Bool { resource?.availability == .preview }
    func restore(_ state: QueueState) { queue = state; position = state.position; duration = state.current?.track.duration ?? 0; updateNowPlaying() }
    func play(_ tracks: [Track], at index: Int = 0, origin: QueueOrigin = .playlist) {
        guard !tracks.isEmpty else { return }
        previousQueue = queue; queue.replace(tracks, startingAt: index, origin: origin); retryCount = 0; loadCurrent()
    }
    func toggle() { isPlaying || isBuffering ? pause() : resume() }
    func resume() {
        wantsPlayback = true
        if player.currentItem == nil || player.currentItem?.status == .failed {
            retryCount = 0; queue.position = position; loadCurrent()
        } else if reachedEnd {
            reachedEnd = false; seek(0)
            if activateAudio() { player.play() }
        } else if player.currentItem?.status == .readyToPlay, activateAudio() { player.play() }
    }
    func pause() { wantsPlayback = false; player.pause(); isPlaying = false; isBuffering = false; save(); updateNowPlaying() }
    func next() {
        if queue.advance(manual: true) { retryCount = 0; loadCurrent() } else { pause() }
    }
    func previous() { queue.position = position; queue.previous(); retryCount = 0; loadCurrent() }
    func jump(_ id: UUID) { guard queue.entries.contains(where: { $0.id == id }) else { return }; queue.currentID = id; queue.position = 0; retryCount = 0; loadCurrent() }
    func seek(_ seconds: Double) {
        let time = min(max(0, seconds), max(0, duration))
        position = time; queue.position = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        save(); updateNowPlaying()
    }
    func enqueue(_ tracks: [Track], next: Bool = false) { previousQueue = queue; queue.append(tracks, next: next); save() }
    @discardableResult func apply(_ arrangement: Arrangement) -> Bool {
        if let signature = arrangement.queueSignature, signature != queue.arrangementSignature { error = "队列已经变化，请重新编排后再应用。"; return false }
        previousQueue = queue; queue.applyArrangement(arrangement.tracks); save(); return true
    }
    func undo() {
        guard let previousQueue else { return }
        let changedCurrent = queue.currentID != previousQueue.currentID
        queue = previousQueue; self.previousQueue = nil
        if changedCurrent { loadCurrent() } else { save() }
    }
    func clear() {
        loadingTask?.cancel(); prefetchTask?.cancel(); prefetched = nil; loadID = UUID(); player.pause(); player.replaceCurrentItem(with: nil)
        resolving = false; reachedEnd = false; attemptStartedAt = nil; reportedStart = false
        queue = .init(); previousQueue = nil; resource = nil; position = 0; duration = 0; error = nil; isPlaying = false; isBuffering = false; wantsPlayback = false
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
    func save() { queue.position = position; onSave?(queue); onStateChanged?(); prepareNext() }
    private func loadCurrent(retrying: Bool = false) {
        loadingTask?.cancel(); prefetchTask?.cancel(); prefetchKey = nil; let generation = UUID(); loadID = generation
        resolving = true; reachedEnd = false
        guard let track = current else { resolving = false; return }
        lastSavedAt = -1
        if !retrying { attemptStartedAt = .now; reportedStart = false; onPlaybackAttempt?() }
        player.pause(); player.replaceCurrentItem(with: nil); itemObservation = nil
        position = queue.position; restoredPosition = queue.position; duration = track.duration; error = nil; resource = nil; nowPlayingArtwork = nil
        wantsPlayback = true; isPlaying = false; isBuffering = true
        let localURL = offlineURL?(track)
        let prepared = prefetched; prefetched = nil
        loadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let item: AVPlayerItem
                if let localURL { item = AVPlayerItem(url: localURL) }
                else if !retrying, let prepared, prepared.trackID == track.id, prepared.quality == quality, prepared.resource.expiresAt.timeIntervalSinceNow > 30 {
                    resource = prepared.resource; item = AVPlayerItem(asset: prepared.asset)
                } else {
                    let r = try await music.resource(track.id, quality: quality)
                    try Task.checkCancellation(); guard generation == loadID else { return }
                    resource = r; item = AVPlayerItem(url: r.url)
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
                            if restored > 0 {
                                let target = restored >= self.duration - 0.5 ? 0 : restored
                                _ = await self.player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                                guard generation == self.loadID else { return }
                            }
                            if self.wantsPlayback, self.activateAudio() { self.player.play() }
                            self.updateNowPlaying(); self.prepareNext()
                        } else if status == .failed { self.handleFailure() }
                    }
                }
                player.replaceCurrentItem(with: item)
                save(); updateNowPlaying()
                if let artwork = track.album.artwork, let image = try? await ArtworkStore.shared.image(artwork), generation == loadID {
                    nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }; updateNowPlaying()
                }
            } catch is CancellationError { }
            catch {
                guard generation == loadID else { return }
                self.error = error.localizedDescription; resolving = false; isBuffering = false; wantsPlayback = false; updateNowPlaying()
            }
        }
    }
    @discardableResult private func activateAudio() -> Bool {
        do { let session = AVAudioSession.sharedInstance(); try session.setCategory(.playback, mode: .default, policy: .longFormAudio); try session.setActive(true); return true }
        catch { self.error = "暂时无法使用音频输出，请检查输出设备。"; pause(); return false }
    }
    private func prepareNext() {
        guard !queue.shuffle, queue.repeatMode != .one, let track = queue.upcoming.first?.track, offlineURL?(track) == nil else { prefetchTask?.cancel(); prefetched = nil; return }
        if let prefetched, prefetched.trackID == track.id, prefetched.quality == quality, prefetched.resource.expiresAt.timeIntervalSinceNow > 30 { return }
        let key = "\(loadID)-\(track.id)-\(quality.rawValue)"
        if prefetchKey == key { return }
        prefetchKey = key
        // A failed speculative fetch must never interrupt the current song.
        prefetchTask?.cancel(); let generation = loadID, requestedQuality = quality
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            defer { if prefetchKey == key { prefetchKey = nil } }
            do {
                let resource = try await music.resource(track.id, quality: requestedQuality)
                let asset = AVURLAsset(url: resource.url)
                guard try await asset.load(.isPlayable) else { return }
                try Task.checkCancellation()
                guard generation == loadID, queue.upcoming.first?.track.id == track.id, requestedQuality == quality else { return }
                prefetched = (track.id, requestedQuality, resource, asset)
            } catch { }
        }
    }
    private func tick(_ seconds: Double) {
        guard seconds.isFinite, player.currentItem != nil else { return }
        position = max(0, seconds)
        if abs(position - lastSavedAt) > 10 { lastSavedAt = position; save() }
    }
    private func updateStatus() {
        isPlaying = player.timeControlStatus == .playing
        isBuffering = wantsPlayback && (resolving || player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        if isPlaying, !reportedStart, let track = current {
            reportedStart = true; onTrackPlayed?(track)
            if let attemptStartedAt { onPlaybackStart?(max(0, Date().timeIntervalSince(attemptStartedAt))) }
        }
        updateNowPlaying(); onStateChanged?()
    }
    private func ended() {
        position = duration; queue.position = duration
        guard wantsPlayback else { reachedEnd = true; return }
        if queue.repeatMode == .one {
            seek(0); if activateAudio() { player.play() }; return
        }
        reachedEnd = true
        if queue.advance() { retryCount = 0; loadCurrent() }
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
        if type == .began { player.pause(); save() }
        else if wantsPlayback, let raw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt, AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) { resume() }
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
