import SwiftUI
import Observation
import MusicCore
import WidgetKit

struct AppNotice: Identifiable { let id = UUID(); var message: String }
@MainActor @Observable final class AppStore {
    static var shared: AppStore?
    let music: MusicService
    let player: PlaybackController
    let downloads: DownloadManager
    let persistence: LocalPersistence
    let background: BackgroundPersistence
    let repository: MusicRepository
    let musicIndex = LocalMusicIndex()
    let preheater = SmartPreheater()
    private(set) var likedIDs = Set<Int64>()
    private(set) var rediscoveries: [Track] = []
    private(set) var libraryRevision = 0
    private(set) var cacheBytes = 0
    var sessionExpired = false
    @ObservationIgnored private var indexingTask: Task<Void, Never>?
    @ObservationIgnored private var hydrationTask: Task<Void, Never>?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var queueWasChanged = false
    @ObservationIgnored private var lastLibraryCheck = Date.distantPast
    @ObservationIgnored private var lastDiscoveryCheck = Date.distantPast
    @ObservationIgnored private var lastProfileCheck = Date.distantPast
    @ObservationIgnored private var lastWidgetSignature = ""
    var profile: UserProfile?
    var library = LibrarySnapshot(accountID: 0) { didSet { rebuildLibraryIndex() } }
    var discoveries: [Track] = []
    var preferences = UserPreferences()
    var history = ListeningHistory()
    var configurations: [AIProviderConfig] = []
    var arrangementProviderID: UUID?
    var explanationProviderID: UUID?
    var pendingMutations: [PendingMutation] = []
    @ObservationIgnored private var confirmedMutationRevision = 0
    @ObservationIgnored private var basicPreheatTask: Task<Void, Never>?
    @ObservationIgnored private var activeLikeMutations = Set<UUID>()
    @ObservationIgnored private var activePlaylistTargets = Set<String>()
    var isLoading = false
    var isSyncing = false
    var syncProgress = "正在同步收藏…"
    var syncError: String?
    var discoveryError: String?
    var showLogin = false
    var showPlayer = false
    var showSettings = false
    var showArrangement = false
    var arrangementPrompt = ""
    var selectedTab = 0
    var notice: AppNotice?
    var searchHistory: [String] = []
    var recentArrangements: [Arrangement] = []
    var pendingCreation: PlaylistCreationAttempt?
    var isCreatingPlaylist = false
    var metrics = LocalMetrics()
    var previewMode = false
    @ObservationIgnored private(set) var accountGeneration = UUID()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var restoringAccount = true
    @ObservationIgnored private var widgetUpdateAt = Date.distantPast
    init(persistence: LocalPersistence, preview: Bool = false, music: MusicService = MusicService()) {
        self.persistence = persistence; previewMode = preview
        let worker = BackgroundPersistence(modelContainer: persistence.container)
        background = worker; repository = MusicRepository(storage: worker)
        self.music = music; player = PlaybackController(music: music); downloads = DownloadManager(music: music)
        configurations = persistence.load([AIProviderConfig].self, key: "ai.configurations") ?? []
        arrangementProviderID = persistence.load(UUID.self, key: "ai.arrangement")
        explanationProviderID = persistence.load(UUID.self, key: "ai.explanation")
        profile = persistence.load(UserProfile.self, key: "activeProfile")
        loadAccount()
        player.onSave = { [weak self] queue in
            guard let self else { return }; self.queueWasChanged = true
            self.saveInBackground(queue, key: self.accountKey("queue")); self.saveHomeSnapshot()
        }
        player.onCheckpoint = { [weak self] checkpoint in
            guard let self else { return }; self.saveInBackground(checkpoint, key: self.accountKey("checkpoint"))
        }
        player.onPlaybackAttempt = { [weak self] in self?.preheater.stop(); self?.recordPlaybackAttempt() }
        player.onPlaybackStart = { [weak self] seconds in self?.recordPlaybackStart(seconds: seconds); self?.schedulePreheat() }
        player.onTrackPlayed = { [weak self] track in self?.recordPlayed(track); self?.prepareCurrentContext() }
        player.onStateChanged = { [weak self] in self?.updateWidget() }
        player.cachedTrack = { [weak self] id in
            guard let self else { return nil }
            return try? await self.background.track(id, accountID: self.profile?.id ?? 0)
        }
        player.offlineURL = { [weak self] track in self?.downloads.localURL(for: track) }
        player.continuationTracks = { [weak self] in guard let self else { return [] }; return try await self.music.recommendations() }
        downloads.onChange = { [weak self] records in guard let self else { return }; self.persist(records, key: self.accountKey("downloads")) }
        if preview { loadPreview() }
        if !persistence.blockedKeys.isEmpty { notify("部分本机资料暂时无法读取，原数据已保留。请更新应用，避免重新建立音乐库。") }
        Self.shared = self
    }
    var isLoggedIn: Bool { profile != nil }
    var activeProviderName: String? { configurations.first { $0.id == arrangementProviderID }?.name }
    var colorScheme: ColorScheme? { preferences.appearance == "light" ? .light : preferences.appearance == "dark" ? .dark : nil }
    func start() async {
        guard !started else { return }; started = true
        if previewMode { return }
        let generation = accountGeneration
        await hydrateAccount()
        guard generation == accountGeneration else { return }
        if profile != nil, let data = Keychain.read("netease.cookie"), let cookie = String(data: data, encoding: .utf8) {
            await music.setCookie(cookie)
            async let account: Void = refreshProfile()
            async let collection: Void = syncLibrary(refresh: false)
            async let discoveries: Void = refreshDiscoveries(refresh: false)
            _ = await (account, collection, discoveries)
        } else {
            sessionExpired = profile != nil
            await refreshDiscoveries(refresh: false)
        }
        schedulePreheat()
    }
    func becameActive() async {
        guard started, !previewMode, !restoringAccount else { return }
        async let account: Void = refreshProfile()
        async let collection: Void = syncLibrary(refresh: false)
        async let discovery: Void = refreshDiscoveries(refresh: false)
        _ = await (account, collection, discovery)
        schedulePreheat()
    }
    private func refreshProfile() async {
        guard let id = profile?.id, Date().timeIntervalSince(lastProfileCheck) >= Freshness.profile else { return }
        let generation = accountGeneration
        do {
            let actual = try await music.profile()
            guard generation == accountGeneration else { return }
            guard actual.id == id else { sessionExpired = true; return }
            profile = actual; sessionExpired = false; lastProfileCheck = .now
            persist(actual, key: "activeProfile")
            persist(lastProfileCheck, key: accountKey("profileCheckedAt"))
        } catch {
            guard generation == accountGeneration else { return }
            if error as? MusicError == .loginRequired { sessionExpired = true }
        }
    }
    func acceptLogin(_ result: LoginResult) async throws {
        let former = profile?.id
        if let former, former != result.profile.id { await logout() }
        if former != result.profile.id { player.clear() }
        try Keychain.write(Data(result.cookie.utf8), key: "netease.cookie")
        accountGeneration = UUID(); try? await repository.reset(); await music.setCookie(result.cookie)
        profile = result.profile; persist(result.profile, key: "activeProfile"); loadAccount(); showLogin = false; sessionExpired = false
        await hydrateAccount()
        async let collection: Void = syncLibrary()
        async let discovery: Void = refreshDiscoveries()
        _ = await (collection, discovery); schedulePreheat()
    }
    func acceptQR(cookie: String) async throws {
        let temporary = MusicService(); await temporary.setCookie(cookie)
        let user = try await temporary.profile()
        try await acceptLogin(LoginResult(cookie: cookie, profile: user))
    }
    func logout() async {
        basicPreheatTask?.cancel()
        accountGeneration = UUID(); hydrationTask?.cancel(); indexingTask?.cancel(); preheater.stop(); player.clear(); downloads.clearAccount()
        let old = profile?.id ?? 0
        await persistTask?.value
        Task { await ArtworkStore.shared.clear() }
        Keychain.remove("netease.cookie"); await music.setCookie("")
        try? await repository.reset(removing: "account.\(old).")
        try? persistence.remove(prefix: "activeProfile")
        profile = nil; sessionExpired = false; loadAccount(); discoveries = []; syncError = nil; SharedListening.clear(); WidgetCenter.shared.reloadAllTimelines()
        NotificationCenter.default.post(name: Notification.Name("YuyinLibraryDidChange"), object: nil)
        await refreshDiscoveries()
    }
    func accountKey(_ suffix: String) -> String { "account.\(profile?.id ?? 0).\(suffix)" }
    private func loadAccount() {
        isSyncing = false; isLoading = false; restoringAccount = true
        let home = persistence.load(HomeSnapshot.self, key: accountKey("home"))
        library = .init(accountID: profile?.id ?? 0, likedTracks: home?.tracks ?? [], syncedAt: .distantPast)
        discoveries = home?.discoveries ?? []
        lastProfileCheck = persistence.load(Date.self, key: accountKey("profileCheckedAt")) ?? .distantPast
        lastLibraryCheck = .distantPast; lastDiscoveryCheck = .distantPast; queueWasChanged = false
        preferences = persistence.load(UserPreferences.self, key: accountKey("preferences")) ?? .init()
        history = .init()
        pendingMutations = persistence.load([PendingMutation].self, key: accountKey("pending")) ?? []
        for index in pendingMutations.indices where pendingMutations[index].status == "正在同步" {
            pendingMutations[index].status = "上次同步中断，点击重试"
        }
        metrics = persistence.load(LocalMetrics.self, key: accountKey("metrics")) ?? .init()
        pendingCreation = persistence.load(PlaylistCreationAttempt.self, key: accountKey("pendingCreation"))
        recentArrangements = persistence.load([Arrangement].self, key: accountKey("ai.arrangements")) ?? []
        searchHistory = persistence.load([String].self, key: accountKey("searchHistory")) ?? []
        player.restore(home?.currentQueue ?? .init()); player.restorationPending = !previewMode
        downloads.configure(accountID: profile?.id ?? 0, records: persistence.load([DownloadRecord].self, key: accountKey("downloads")) ?? [])
        player.quality = preferences.quality; downloads.wifiOnly = preferences.wifiOnly; rebuildLibraryIndex()
    }
    func syncLibrary(refresh: Bool = true) async {
        guard let profile, !isSyncing, refresh || Date().timeIntervalSince(lastLibraryCheck) >= Freshness.collection else { return }
        let generation = accountGeneration, mutationRevision = confirmedMutationRevision; isSyncing = true; syncError = nil
        defer { if generation == accountGeneration { isSyncing = false } }
        do {
            let snapshot = try await music.library(userID: profile.id, cached: library) { [self] message in await setSyncProgress(message, generation: generation) }
            guard generation == accountGeneration else { return }
            syncError = snapshot.partialFailures?.joined(separator: "\n")
            guard mutationRevision == confirmedMutationRevision else { lastLibraryCheck = .distantPast; return }
            library = snapshot; lastLibraryCheck = .now
            saveInBackground(snapshot, key: accountKey("library")); saveHomeSnapshot(); updateWidget(force: true)
        } catch { guard generation == accountGeneration else { return }; syncError = error.localizedDescription; if error as? MusicError == .loginRequired { sessionExpired = true } }
    }
    private func setSyncProgress(_ message: String, generation: UUID) { if accountGeneration == generation { syncProgress = message } }
    func refreshDiscoveries(refresh: Bool = true) async {
        guard !isLoading, refresh || Date().timeIntervalSince(lastDiscoveryCheck) >= Freshness.discoveries else { return }
        let generation = accountGeneration; isLoading = true; discoveryError = nil
        defer { if generation == accountGeneration { isLoading = false } }
        do {
            let tracks = try await repository.value([Track].self, key: accountKey("cache.discoveries"), lifetime: Freshness.discoveries, refresh: refresh) { [music] in try await music.recommendations() }
            guard generation == accountGeneration else { return }; lastDiscoveryCheck = .now
            discoveries = tracks.map { var track = $0; track.reason = CollectionRetrieval.reason(for: track, library: library.likedTracks) ?? track.reason; return track }; saveHomeSnapshot()
        } catch { guard generation == accountGeneration else { return }; discoveryError = error.localizedDescription }
    }
    func report(_ error: Error) { if error is CancellationError { return }; notice = .init(message: error.localizedDescription) }
    func notify(_ message: String) { notice = .init(message: message) }
    func savePreferences() { player.quality = preferences.quality; downloads.wifiOnly = preferences.wifiOnly; persist(preferences, key: accountKey("preferences")); updateWidget(force: true) }
    func saveArrangement(_ value: Arrangement) {
        recentArrangements.removeAll { $0.id == value.id }; recentArrangements.insert(value, at: 0)
        recentArrangements = Array(recentArrangements.prefix(10)); persist(recentArrangements, key: accountKey("ai.arrangements"))
    }
    func explanationRecord(_ id: Int64) -> ExplanationRecord? { persistence.load(ExplanationRecord.self, key: accountKey("ai.explanation.\(id)")) }
    func saveExplanation(_ value: ExplanationRecord) { persist(value, key: accountKey("ai.explanation.\(value.trackID)")) }
    func clearAIHistory() {
        do { try persistence.remove(prefix: accountKey("ai.")); recentArrangements = []; notify("已清除本机编排和导读") } catch { report(error) }
    }
    func recordSearch(_ query: String) { searchHistory.removeAll { $0 == query }; searchHistory.insert(query, at: 0); searchHistory = Array(searchHistory.prefix(12)); persist(searchHistory, key: accountKey("searchHistory")) }
    func clearHistory() { history = .init(); searchHistory = []; rebuildLibraryIndex(); persist(history, key: accountKey("history")); persist(searchHistory, key: accountKey("searchHistory")) }
    func pinPlaylist(_ id: Int64) { if preferences.pinnedPlaylists.contains(id) { preferences.pinnedPlaylists.remove(id) } else { preferences.pinnedPlaylists.insert(id) }; savePreferences() }
    func requireLogin() -> Bool { if !isLoggedIn { showLogin = true; return false }; return true }
    func toggleLike(_ track: Track) async {
        guard let profile else { showLogin = true; return }
        let desired = !likedIDs.contains(track.id)
        let id: UUID
        if let index = pendingMutations.firstIndex(where: { $0.kind == .like && $0.targetID == track.id && $0.accountID == profile.id }) {
            pendingMutations[index].liked = desired
            pendingMutations[index].operationVersion = (pendingMutations[index].operationVersion ?? 0) + 1
            pendingMutations[index].track = track; id = pendingMutations[index].id
        } else {
            var mutation = PendingMutation(accountID: profile.id, kind: .like, trackIDs: [track.id], targetID: track.id, liked: desired)
            mutation.confirmedLiked = library.likedTracks.contains { $0.id == track.id }; mutation.operationVersion = 1; mutation.track = track
            pendingMutations.append(mutation); id = mutation.id
        }
        savePending(); await retryMutation(id, knownTrack: track)
    }
    private func syncLike(_ id: UUID, knownTrack: Track?) async {
        guard !activeLikeMutations.contains(id), let profile else { return }
        activeLikeMutations.insert(id); defer { activeLikeMutations.remove(id) }
        let generation = accountGeneration
        while let index = pendingMutations.firstIndex(where: { $0.id == id && $0.accountID == profile.id }) {
            guard generation == accountGeneration, !Task.isCancelled else { return }
            pendingMutations[index].status = "正在同步"
            let sent = pendingMutations[index], version = sent.operationVersion ?? 0
            savePending()
            do {
                try await music.setLiked(sent.targetID, liked: sent.liked == true, userID: profile.id)
                guard generation == accountGeneration else { return }
                confirmedMutationRevision += 1
                var confirmed = library
                let existing = confirmed.likedTracks.first { $0.id == sent.targetID }
                confirmed.likedTracks.removeAll { $0.id == sent.targetID }
                if sent.liked == true {
                    var placeholder = Track(id: sent.targetID, title: "正在读取歌曲资料", artists: [], album: .init(id: 0, name: ""), duration: 0)
                    placeholder.metadataPending = true
                    confirmed.likedTracks.insert(sent.track ?? knownTrack ?? existing ?? placeholder, at: 0)
                }
                if let current = pendingMutations.firstIndex(where: { $0.id == id }) {
                    if (pendingMutations[current].operationVersion ?? 0) == version { pendingMutations.remove(at: current) }
                    else { pendingMutations[current].confirmedLiked = sent.liked }
                }
                library = confirmed
                savePending(); saveInBackground(library, key: accountKey("library")); saveHomeSnapshot()
            } catch {
                guard generation == accountGeneration else { return }
                guard let current = pendingMutations.firstIndex(where: { $0.id == id }) else { return }
                if (pendingMutations[current].operationVersion ?? 0) != version { continue }
                pendingMutations[current].status = "同步未确认，点击重试"; savePending(); return
            }
        }
    }
    func changePlaylist(_ playlist: Playlist, tracks: [Track], adding: Bool) async {
        guard let profile else { showLogin = true; return }
        let mutation = PendingMutation(accountID: profile.id, kind: adding ? .addTracks : .removeTracks, trackIDs: tracks.map(\.id), targetID: playlist.id)
        pendingMutations.append(mutation); savePending(); await retryMutation(mutation.id)
    }
    func retryMutation(_ id: UUID, knownTrack: Track? = nil) async {
        if pendingMutations.first(where: { $0.id == id })?.kind == .like { await syncLike(id, knownTrack: knownTrack); return }
        guard let index = pendingMutations.firstIndex(where: { $0.id == id }), pendingMutations[index].status != "正在同步", let profile, pendingMutations[index].accountID == profile.id else { return }
        let generation = accountGeneration
        let target = pendingMutations[index].targetID
        let targetKey = "\(generation.uuidString).\(target)"
        guard !activePlaylistTargets.contains(targetKey) else { return }
        activePlaylistTargets.insert(targetKey)
        defer {
            activePlaylistTargets.remove(targetKey)
            if generation == accountGeneration, let next = pendingMutations.first(where: { $0.kind != .like && $0.targetID == target && $0.status == "等待同步" }) {
                Task { await retryMutation(next.id) }
            }
        }
        pendingMutations[index].status = "正在同步"; let mutation = pendingMutations[index]; savePending()
        do {
            switch mutation.kind {
            case .like: try await music.setLiked(mutation.targetID, liked: mutation.liked == true, userID: profile.id)
            case .addTracks: try await music.editPlaylist(mutation.targetID, tracks: mutation.trackIDs, adding: true)
            case .removeTracks: try await music.editPlaylist(mutation.targetID, tracks: mutation.trackIDs, adding: false)
            }
            guard generation == accountGeneration else { return }
            pendingMutations.removeAll { $0.id == id }; savePending()
            if mutation.kind != .like {
                confirmedMutationRevision += 1
                await invalidatePlaylist(mutation.targetID)
                if let tracks = try? await playlistTracks(mutation.targetID, refresh: true), generation == accountGeneration,
                   let index = library.playlists.firstIndex(where: { $0.id == mutation.targetID }) {
                    library.playlists[index].count = tracks.count
                    saveInBackground(library, key: accountKey("library")); saveHomeSnapshot()
                }
            }
            notify("已同步到网易云音乐")
        } catch {
            guard generation == accountGeneration else { return }
            if let i = pendingMutations.firstIndex(where: { $0.id == id }) { pendingMutations[i].status = "同步失败，点击重试" }; savePending(); report(error)
        }
    }
    func discardMutation(_ id: UUID) { guard !activeLikeMutations.contains(id), pendingMutations.first(where: { $0.id == id })?.status != "正在同步" else { return }; pendingMutations.removeAll { $0.id == id }; savePending() }
    private func savePending() { rebuildLikedIDs(); persist(pendingMutations, key: accountKey("pending")) }
    func saveConfiguration(_ config: AIProviderConfig, secrets: AISecrets) throws {
        _ = try config.endpoint("chat/completions")
        try Keychain.write(try JSONEncoder().encode(secrets), key: config.secretID)
        configurations.removeAll { $0.id == config.id }; configurations.append(config)
        if arrangementProviderID == nil { arrangementProviderID = config.id }
        saveProviderChoices()
    }
    func removeConfiguration(_ config: AIProviderConfig) {
        Keychain.remove(config.secretID); configurations.removeAll { $0.id == config.id }
        // Removing the active provider disables that role; never silently switches vendors.
        if arrangementProviderID == config.id { arrangementProviderID = nil }
        if explanationProviderID == config.id { explanationProviderID = nil }
        saveProviderChoices()
    }
    func saveProviderChoices() {
        persist(configurations, key: "ai.configurations")
        if let arrangementProviderID { persist(arrangementProviderID, key: "ai.arrangement") } else { try? persistence.remove(prefix: "ai.arrangement") }
        if let explanationProviderID { persist(explanationProviderID, key: "ai.explanation") } else { try? persistence.remove(prefix: "ai.explanation") }
    }
    func provider(explanation: Bool = false) throws -> AIProvider {
        let id = explanation ? explanationProviderID ?? arrangementProviderID : arrangementProviderID
        guard let config = configurations.first(where: { $0.id == id }), config.consentDate != nil,
              let data = Keychain.read(config.secretID), let secrets = try? JSONDecoder().decode(AISecrets.self, from: data) else { throw MusicError.message("请先在设置中连接一个模型服务。") }
        return AIProvider(config: config, secrets: secrets)
    }
    func handleURL(_ url: URL) {
        guard url.scheme == "yuyin" else { return }
        if url.host == "resume" { player.resume(); showPlayer = player.current != nil }
        else if url.host == "playlist", let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value, let id = Int64(raw) {
            let generation = accountGeneration
            Task { do { let tracks = try await playlistTracks(id); guard generation == accountGeneration else { return }; player.play(tracks); showPlayer = !tracks.isEmpty } catch { if generation == accountGeneration { report(error) } } }
        }
    }
    private func recordPlayed(_ track: Track) {
        history.lastPlayed[track.id] = .now; history.recent.removeAll { $0.id == track.id }; history.recent.insert(track, at: 0); history.recent = Array(history.recent.prefix(100))
        persist(history, key: accountKey("history")); rebuildLibraryIndex(); saveHomeSnapshot(); updateWidget(force: true)
    }
    func updateWidget(force: Bool = false) {
        if force { NotificationCenter.default.post(name: Notification.Name("YuyinLibraryDidChange"), object: nil) }
        let signature = "\(player.current?.id ?? 0)-\(player.isPlaying)-\(preferences.pinnedPlaylists.sorted())"
        guard force || signature != lastWidgetSignature else { return }
        lastWidgetSignature = signature; widgetUpdateAt = .now
        let playlists = library.playlists.filter { preferences.pinnedPlaylists.contains($0.id) }.prefix(3).map { WidgetPlaylist(id: $0.id, name: $0.name) }
        SharedListening.write(.init(title: player.current?.title ?? "留一点时间给音乐", artist: player.current?.artistName ?? "打开余音，继续听", isPlaying: player.isPlaying, playlists: playlists))
        WidgetCenter.shared.reloadAllTimelines()
    }
    private func persist<T: Encodable>(_ value: T, key: String) { do { try persistence.save(value, key: key) } catch { notice = .init(message: "本地保存失败，请检查设备存储空间。") } }
    private func hydrateAccount() async {
        let generation = accountGeneration, prefix = accountKey("")
        defer { if generation == accountGeneration { restoringAccount = false; player.finishRestoration(nil) } }
        do {
            if let saved = try await background.load(ListeningHistory.self, key: prefix + "history"), generation == accountGeneration { history = saved }
            if let queue = try await background.load(QueueState.self, key: prefix + "queue"), generation == accountGeneration, !queueWasChanged {
                var restored = queue
                if let checkpoint = try await background.load(PlaybackCheckpoint.self, key: prefix + "checkpoint"), checkpoint.currentID == queue.currentID { restored.position = checkpoint.position }
                guard generation == accountGeneration else { return }
                if !queueWasChanged { player.finishRestoration(restored) }
            } else if generation == accountGeneration { player.finishRestoration(nil) }
            if let saved = try await background.load(LibrarySnapshot.self, key: prefix + "library"), generation == accountGeneration {
                library = saved; lastLibraryCheck = saved.syncedAt
            }
            if let cached = try await repository.cached([Track].self, key: prefix + "cache.discoveries"), generation == accountGeneration {
                discoveries = cached.value; lastDiscoveryCheck = cached.updatedAt
            } else if let legacy = try await background.load([Track].self, key: prefix + "discoveries"), generation == accountGeneration { discoveries = legacy }
            guard generation == accountGeneration else { return }; saveHomeSnapshot()
        } catch { if generation == accountGeneration { notify("部分本机资料暂时无法读取，原数据已保留。") } }
    }
    private func rebuildLikedIDs() {
        var ids = Set(library.likedTracks.map(\.id))
        for mutation in pendingMutations where mutation.kind == .like {
            if mutation.liked == true { ids.insert(mutation.targetID) } else { ids.remove(mutation.targetID) }
        }
        likedIDs = ids
    }
    private func rebuildLibraryIndex() {
        rebuildLikedIDs(); libraryRevision += 1; indexingTask?.cancel()
        let tracks = library.likedTracks, recent = history.lastPlayed, generation = accountGeneration, revision = libraryRevision
        indexingTask = Task { [weak self, musicIndex] in
            guard !Task.isCancelled else { return }
            await musicIndex.replace(tracks, revision: revision)
            let ordered = await Task.detached(priority: .utility) { tracks.sorted { (recent[$0.id] ?? .distantPast) < (recent[$1.id] ?? .distantPast) } }.value
            guard !Task.isCancelled, let self, self.accountGeneration == generation else { return }
            self.rediscoveries = ordered
        }
    }
    func saveInBackground<Value: Codable & Sendable>(_ value: Value, key: String) {
        let previous = persistTask, worker = background
        persistTask = Task { [weak self] in
            await previous?.value
            do { try await worker.save(value, key: key) } catch { self?.notify("本地保存失败，原资料已保留。") }
        }
    }
    func saveHomeSnapshot() {
        var summary = QueueState()
        if let current = player.queue.current { summary.entries = [current]; summary.currentID = current.id; summary.position = player.position }
        saveInBackground(HomeSnapshot(tracks: Array(library.likedTracks.prefix(12)), discoveries: Array(discoveries.prefix(6)), currentQueue: summary), key: accountKey("home"))
    }
    private func prepareCurrentContext() {
        basicPreheatTask?.cancel()
        guard !previewMode, let track = player.current else { return }
        let generation = accountGeneration
        let covers = ([track] + player.queue.upcoming.prefix(2).map(\.track)).compactMap { $0.album.artwork }
        basicPreheatTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = try? await lyricLines(track.id)
            for url in covers {
                guard generation == accountGeneration, !Task.isCancelled else { return }
                _ = try? await ArtworkStore.shared.image(url, pixels: 160)
            }
        }
    }
    func schedulePreheat() {
        guard !previewMode, preferences.smartPreheat else { preheater.stop(); return }
        let pinned = library.playlists.filter { preferences.pinnedPlaylists.contains($0.id) }
        let other = library.playlists.filter { !preferences.pinnedPlaylists.contains($0.id) }
        preheater.schedule(playlists: Array((pinned + other).prefix(20)), tracks: Array((history.recent + discoveries + library.likedTracks).prefix(200)), music: music, repository: repository, prefix: accountKey("cache."))
    }
    func updateCacheUsage() async {
        let metadata = (try? await background.byteCount(prefix: accountKey("cache."))) ?? 0
        cacheBytes = metadata + (await ArtworkStore.shared.byteCount)
    }
    private func loadPreview() {
        guard let url = Bundle.main.url(forResource: "PreviewTracks", withExtension: "json"), let data = try? Data(contentsOf: url), let j = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        let tracks = j["songs"].array.map(Track.init(json:))
        discoveries = tracks; library = .init(accountID: 0, likedTracks: tracks)
        if !tracks.isEmpty { var q = QueueState(); q.replace(tracks, origin: .album); q.position = 48; player.restore(q) }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--home-guest") { player.clear(); library = .init(accountID: 0); profile = nil }
        if arguments.contains("--home-signed-in") {
            player.clear(); profile = .init(id: 1, name: "界面测试账户"); library.accountID = 1
            if arguments.contains("--home-empty") { library.likedTracks = [] }
            if arguments.contains("--home-syncing") { library.likedTracks = []; isSyncing = true }
            if arguments.contains("--home-sync-failed") { library.likedTracks = []; syncError = "测试同步失败" }
        }
        loadAdditionalPreviewFixtures()
        #endif
    }
}
