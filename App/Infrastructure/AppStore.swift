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
    var profile: UserProfile?
    var library = LibrarySnapshot(accountID: 0)
    var discoveries: [Track] = []
    var preferences = UserPreferences()
    var history = ListeningHistory()
    var configurations: [AIProviderConfig] = []
    var arrangementProviderID: UUID?
    var explanationProviderID: UUID?
    var pendingMutations: [PendingMutation] = []
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
    @ObservationIgnored private var widgetUpdateAt = Date.distantPast
    init(persistence: LocalPersistence, preview: Bool = false, music: MusicService = MusicService()) {
        self.persistence = persistence; previewMode = preview
        self.music = music; player = PlaybackController(music: music); downloads = DownloadManager(music: music)
        configurations = persistence.load([AIProviderConfig].self, key: "ai.configurations") ?? []
        arrangementProviderID = persistence.load(UUID.self, key: "ai.arrangement")
        explanationProviderID = persistence.load(UUID.self, key: "ai.explanation")
        profile = persistence.load(UserProfile.self, key: "activeProfile")
        loadAccount()
        player.onSave = { [weak self] queue in guard let self else { return }; self.persist(queue, key: self.accountKey("queue")) }
        player.onPlaybackAttempt = { [weak self] in self?.recordPlaybackAttempt() }
        player.onPlaybackStart = { [weak self] seconds in self?.recordPlaybackStart(seconds: seconds) }
        player.onTrackPlayed = { [weak self] track in self?.recordPlayed(track) }
        player.onStateChanged = { [weak self] in self?.updateWidget() }
        player.offlineURL = { [weak self] track in self?.downloads.localURL(for: track) }
        player.continuationTracks = { [weak self] in guard let self else { return [] }; return try await self.music.recommendations() }
        downloads.onChange = { [weak self] records in guard let self else { return }; self.persist(records, key: self.accountKey("downloads")) }
        if preview { loadPreview() }
        if !persistence.blockedKeys.isEmpty { notify("部分本机资料暂时无法读取，原数据已保留。请更新应用，避免重新建立音乐库。") }
        Self.shared = self
    }
    var isLoggedIn: Bool { profile != nil }
    var likedIDs: Set<Int64> { Set(library.likedTracks.map(\.id)) }
    var rediscoveries: [Track] { library.likedTracks.sorted { (history.lastPlayed[$0.id] ?? .distantPast) < (history.lastPlayed[$1.id] ?? .distantPast) } }
    var activeProviderName: String? { configurations.first { $0.id == arrangementProviderID }?.name }
    var colorScheme: ColorScheme? { preferences.appearance == "light" ? .light : preferences.appearance == "dark" ? .dark : nil }
    func start() async {
        guard !started else { return }; started = true
        if previewMode { return }
        if profile != nil, let data = Keychain.read("netease.cookie"), let cookie = String(data: data, encoding: .utf8) {
            await music.setCookie(cookie)
            do { let actual = try await music.profile(); guard actual.id == profile?.id else { await logout(); return }; profile = actual; await syncLibrary() }
            catch { report(error); if error as? MusicError == .loginRequired { showLogin = true } }
        } else if profile != nil { showLogin = true }
        await refreshDiscoveries()
    }
    func acceptLogin(_ result: LoginResult) async throws {
        let former = profile?.id
        if let former, former != result.profile.id { await logout() }
        if former != result.profile.id { player.clear() }
        try Keychain.write(Data(result.cookie.utf8), key: "netease.cookie")
        accountGeneration = UUID(); await music.setCookie(result.cookie)
        profile = result.profile; persist(result.profile, key: "activeProfile"); loadAccount(); showLogin = false
        await syncLibrary(); await refreshDiscoveries()
    }
    func acceptQR(cookie: String) async throws {
        let temporary = MusicService(); await temporary.setCookie(cookie)
        let user = try await temporary.profile()
        try await acceptLogin(LoginResult(cookie: cookie, profile: user))
    }
    func logout() async {
        accountGeneration = UUID(); player.clear(); downloads.clearAccount()
        let old = profile?.id ?? 0
        Task { await ArtworkStore.shared.clear() }
        Keychain.remove("netease.cookie"); await music.setCookie("")
        try? persistence.remove(prefix: "account.\(old).")
        try? persistence.remove(prefix: "activeProfile")
        profile = nil; loadAccount(); discoveries = []; syncError = nil; SharedListening.clear(); WidgetCenter.shared.reloadAllTimelines()
        NotificationCenter.default.post(name: Notification.Name("YuyinLibraryDidChange"), object: nil)
        await refreshDiscoveries()
    }
    func accountKey(_ suffix: String) -> String { "account.\(profile?.id ?? 0).\(suffix)" }
    private func loadAccount() {
        isSyncing = false; isLoading = false
        library = persistence.load(LibrarySnapshot.self, key: accountKey("library")) ?? .init(accountID: profile?.id ?? 0)
        preferences = persistence.load(UserPreferences.self, key: accountKey("preferences")) ?? .init()
        history = persistence.load(ListeningHistory.self, key: accountKey("history")) ?? .init()
        pendingMutations = persistence.load([PendingMutation].self, key: accountKey("pending")) ?? []
        for index in pendingMutations.indices where pendingMutations[index].status == "正在同步" {
            pendingMutations[index].status = "上次同步中断，点击重试"
        }
        metrics = persistence.load(LocalMetrics.self, key: accountKey("metrics")) ?? .init()
        pendingCreation = persistence.load(PlaylistCreationAttempt.self, key: accountKey("pendingCreation"))
        recentArrangements = persistence.load([Arrangement].self, key: accountKey("ai.arrangements")) ?? []
        searchHistory = persistence.load([String].self, key: accountKey("searchHistory")) ?? []
        player.restore(persistence.load(QueueState.self, key: accountKey("queue")) ?? .init())
        downloads.configure(accountID: profile?.id ?? 0, records: persistence.load([DownloadRecord].self, key: accountKey("downloads")) ?? [])
        player.quality = preferences.quality; downloads.wifiOnly = preferences.wifiOnly
    }
    func syncLibrary() async {
        guard let profile, !isSyncing else { return }
        let generation = accountGeneration; isSyncing = true; syncError = nil
        defer { if generation == accountGeneration { isSyncing = false } }
        do {
            let snapshot = try await music.library(userID: profile.id, cached: library) { [self] message in await setSyncProgress(message, generation: generation) }
            guard generation == accountGeneration else { return }
            syncError = snapshot.partialFailures?.joined(separator: "\n")
            library = snapshot; persist(snapshot, key: accountKey("library")); updateWidget(force: true)
        } catch { guard generation == accountGeneration else { return }; syncError = error.localizedDescription; if error as? MusicError == .loginRequired { showLogin = true } }
    }
    private func setSyncProgress(_ message: String, generation: UUID) { if accountGeneration == generation { syncProgress = message } }
    func refreshDiscoveries() async {
        let generation = accountGeneration; isLoading = true; discoveryError = nil
        defer { if generation == accountGeneration { isLoading = false } }
        do {
            let tracks = try await music.recommendations(); guard generation == accountGeneration else { return }
            discoveries = tracks.map { var track = $0; track.reason = CollectionRetrieval.reason(for: track, library: library.likedTracks) ?? track.reason; return track }; persist(discoveries, key: accountKey("discoveries"))
        } catch { guard generation == accountGeneration else { return }; discoveryError = error.localizedDescription; if discoveries.isEmpty { discoveries = persistence.load([Track].self, key: accountKey("discoveries")) ?? [] } }
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
    func clearHistory() { history = .init(); searchHistory = []; persist(history, key: accountKey("history")); persist(searchHistory, key: accountKey("searchHistory")) }
    func pinPlaylist(_ id: Int64) { if preferences.pinnedPlaylists.contains(id) { preferences.pinnedPlaylists.remove(id) } else { preferences.pinnedPlaylists.insert(id) }; savePreferences() }
    func requireLogin() -> Bool { if !isLoggedIn { showLogin = true; return false }; return true }
    func toggleLike(_ track: Track) async {
        guard let profile else { showLogin = true; return }
        guard !pendingMutations.contains(where: { $0.kind == .like && $0.targetID == track.id }) else { notify("这首歌有待同步的更改，请在设置中重试或取消。"); return }
        let mutation = PendingMutation(accountID: profile.id, kind: .like, trackIDs: [track.id], targetID: track.id, liked: !likedIDs.contains(track.id))
        pendingMutations.append(mutation); savePending(); await retryMutation(mutation.id, knownTrack: track)
    }
    func changePlaylist(_ playlist: Playlist, tracks: [Track], adding: Bool) async {
        guard let profile else { showLogin = true; return }
        let mutation = PendingMutation(accountID: profile.id, kind: adding ? .addTracks : .removeTracks, trackIDs: tracks.map(\.id), targetID: playlist.id)
        pendingMutations.append(mutation); savePending(); await retryMutation(mutation.id)
    }
    func retryMutation(_ id: UUID, knownTrack: Track? = nil) async {
        guard let index = pendingMutations.firstIndex(where: { $0.id == id }), pendingMutations[index].status != "正在同步", let profile, pendingMutations[index].accountID == profile.id else { return }
        pendingMutations[index].status = "正在同步"; let mutation = pendingMutations[index]; savePending()
        let generation = accountGeneration
        do {
            switch mutation.kind {
            case .like: try await music.setLiked(mutation.targetID, liked: mutation.liked == true, userID: profile.id)
            case .addTracks: try await music.editPlaylist(mutation.targetID, tracks: mutation.trackIDs, adding: true)
            case .removeTracks: try await music.editPlaylist(mutation.targetID, tracks: mutation.trackIDs, adding: false)
            }
            guard generation == accountGeneration else { return }
            pendingMutations.removeAll { $0.id == id }; savePending()
            if mutation.kind != .like { invalidatePlaylist(mutation.targetID) }
            if mutation.kind == .like {
                library.likedTracks.removeAll { $0.id == mutation.targetID }
                if mutation.liked == true {
                    if let knownTrack { library.likedTracks.insert(knownTrack, at: 0) }
                    else {
                        let tracks = try await music.tracks(ids: [mutation.targetID])
                        guard generation == accountGeneration else { return }; library.likedTracks += tracks
                    }
                }
                persist(library, key: accountKey("library"))
            }
            notify("已同步到网易云音乐")
        } catch {
            guard generation == accountGeneration else { return }
            if let i = pendingMutations.firstIndex(where: { $0.id == id }) { pendingMutations[i].status = "同步失败，点击重试" }; savePending(); report(error)
        }
    }
    func discardMutation(_ id: UUID) { pendingMutations.removeAll { $0.id == id }; savePending() }
    private func savePending() { persist(pendingMutations, key: accountKey("pending")) }
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
            Task { do { let tracks = try await playlistTracks(id); player.play(tracks); showPlayer = true } catch { report(error) } }
        }
    }
    private func recordPlayed(_ track: Track) {
        history.lastPlayed[track.id] = .now; history.recent.removeAll { $0.id == track.id }; history.recent.insert(track, at: 0); history.recent = Array(history.recent.prefix(100))
        persist(history, key: accountKey("history")); updateWidget(force: true)
    }
    func updateWidget(force: Bool = false) {
        if force { NotificationCenter.default.post(name: Notification.Name("YuyinLibraryDidChange"), object: nil) }
        guard force || Date().timeIntervalSince(widgetUpdateAt) > 2 else { return }; widgetUpdateAt = .now
        let playlists = library.playlists.filter { preferences.pinnedPlaylists.contains($0.id) }.prefix(3).map { WidgetPlaylist(id: $0.id, name: $0.name) }
        SharedListening.write(.init(title: player.current?.title ?? "留一点时间给音乐", artist: player.current?.artistName ?? "打开余音，继续听", isPlaying: player.isPlaying, playlists: playlists))
        WidgetCenter.shared.reloadAllTimelines()
    }
    private func persist<T: Encodable>(_ value: T, key: String) { do { try persistence.save(value, key: key) } catch { notice = .init(message: "本地保存失败，请检查设备存储空间。") } }
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
