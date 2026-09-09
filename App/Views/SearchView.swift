import SwiftUI
import MusicCore
struct SearchView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var kind = SearchKind.tracks
    @State private var sessions: [SearchSessionKey: SearchSession] = [:]
    @State private var isSearching = false
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    private var key: SearchSessionKey { .init(account: store.profile?.id ?? 0, query: query, kind: kind) }
    private var session: SearchSession { sessions[key] ?? .init() }
    private var local: [Track] { session.local }
    private var result: SearchResult { session.result }
    private var didSearch: Bool { session.didSearch }
    private var error: String? { session.error }
    private var anchor: Binding<String?> { let selected = key; return Binding(get: { sessions[selected]?.anchor }, set: { sessions[selected, default: .init()].anchor = $0 }) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("搜索").font(.largeTitle.weight(.semibold))
                HStack(spacing: 12) { Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary); TextField("歌曲、音乐人，或此刻的心情", text: $query).submitLabel(.search).onSubmit { search() }.accessibilityIdentifier("searchField"); if !query.isEmpty { IconButton(symbol: "xmark.circle.fill", label: "清空搜索", size: 16) { query = "" } } }.padding(.horizontal, 14).frame(minHeight: 54).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                if !query.isEmpty { Button { store.arrangementPrompt = query; store.showArrangement = true } label: { Label("用这句话编排音乐", systemImage: "slider.horizontal.3").font(.subheadline).frame(minHeight: 44) }.buttonStyle(.plain) }
                Picker("搜索类型", selection: $kind) { ForEach(SearchKind.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented).onChange(of: kind) { _, _ in if !query.isEmpty { search() } }
                if key.query.isEmpty { discovery }
                if let error { InlineError(message: error) { search(retry: true) } }
                if kind == .tracks, !local.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeading(title: "你的收藏")
                        ForEach(Array(local.enumerated()), id: \.element.id) { index, track in TrackRow(track: track) { store.player.play(local, at: index, origin: .search) }.id("local-\(track.id)") }
                    }
                }
                if !key.query.isEmpty { results }
                if isSearching { DelayedProgress(title: "正在寻找…"); Button("取消搜索") { task?.cancel(); generation = UUID(); isSearching = false }.font(.footnote).frame(minHeight: 44) }
                if !key.query.isEmpty && result.hasMore && !isSearching && error == nil { Button("加载更多") { search(more: true) }.accessibilityIdentifier("searchMore").frame(maxWidth: .infinity, minHeight: 44) }
                if didSearch && !isSearching && error == nil && local.isEmpty && result.tracks.isEmpty && result.albums.isEmpty && result.artists.isEmpty && result.playlists.isEmpty { EmptyState(symbol: "magnifyingglass", title: "还没有找到", detail: "换一个歌名或音乐人试试，也可以用一句话描述想听的音乐。") }
            }.padding(20)
        }.scrollDismissesKeyboard(.interactively).scrollPosition(id: anchor, anchor: .top).cabinetBackground().toolbar(.hidden, for: .navigationBar)
            .onChange(of: query) { _, _ in
                task?.cancel(); generation = UUID(); isSearching = false
                if !key.query.isEmpty { search(debounce: true) }
            }
            .onChange(of: store.accountGeneration) { _, _ in task?.cancel(); generation = UUID(); sessions = [:]; query = ""; isSearching = false }
            .onDisappear { task?.cancel(); generation = UUID(); isSearching = false }
    }
    private var discovery: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !store.searchHistory.isEmpty { SectionHeading(title: "最近找过"); ForEach(store.searchHistory, id: \.self) { text in Button { query = text } label: { HStack { Image(systemName: "clock").foregroundStyle(Palette.secondary); Text(text); Spacer(); Image(systemName: "arrow.up.left").font(.caption) }.frame(minHeight: 44) }.buttonStyle(.plain) } }
            SectionHeading(title: "也可以这样找", subtitle: "让音乐贴近此刻")
            ForEach(["把收藏里适合散步的歌排四十分钟", "想听轻松一点的，少些人声", "重听那些很久没听的喜欢"], id: \.self) { text in Button { store.arrangementPrompt = text; store.showArrangement = true } label: { HStack { Text(text).font(.subheadline).multilineTextAlignment(.leading); Spacer(); Image(systemName: "arrow.up.right").font(.caption) }.padding(.vertical, 12) }.buttonStyle(.plain) }
        }.padding(.top, 12)
    }
    @ViewBuilder private var results: some View {
        LazyVStack(spacing: 14) {
            switch kind {
            case .tracks: ForEach(Array(result.tracks.filter { track in !local.contains(where: { $0.id == track.id }) }.enumerated()), id: \.element.id) { index, track in TrackRow(track: track) { store.player.play(result.tracks, at: result.tracks.firstIndex(where: { $0.id == track.id }) ?? index, origin: .search) }.id("track-\(track.id)") }
            case .albums: ForEach(result.albums) { album in NavigationLink { CollectionDetailView(album: album) } label: { entityRow(title: album.name, detail: album.artistName, artwork: album.artwork) }.buttonStyle(.plain).id("album-\(album.id)") }
            case .artists: ForEach(result.artists) { artist in NavigationLink { CollectionDetailView(artist: artist) } label: { entityRow(title: artist.name, detail: "音乐人", artwork: artist.artwork) }.buttonStyle(.plain).id("artist-\(artist.id)") }
            case .playlists: ForEach(result.playlists) { playlist in NavigationLink { CollectionDetailView(playlist: playlist) } label: { entityRow(title: playlist.name, detail: "\(playlist.count) 首", artwork: playlist.artwork) }.buttonStyle(.plain).id("playlist-\(playlist.id)") }
            }
        }.scrollTargetLayout()
    }
    private func entityRow(title: String, detail: String, artwork: URL?) -> some View { HStack(spacing: 16) { Artwork(url: artwork, size: 62); VStack(alignment: .leading, spacing: 6) { Text(title).lineLimit(2); Text(detail).font(.subheadline).foregroundStyle(Palette.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption) } }
    private func search(more: Bool = false, debounce: Bool = false, retry: Bool = false) {
        let requested = key; guard !requested.query.isEmpty else { return }
        let pageOffset = retry ? session.failedOffset ?? 0 : more ? session.nextOffset : 0
        task?.cancel(); let token = UUID(); generation = token; isSearching = true
        sessions[requested, default: .init()].begin()
        let account = store.accountGeneration
        task = Task {
            defer { if generation == token { isSearching = false } }
            do {
                if !more && !retry {
                    let matches = requested.kind == .tracks ? await store.musicIndex.search(requested.query, limit: 8) : []
                    try Task.checkCancellation(); guard generation == token, account == store.accountGeneration else { return }
                    sessions[requested, default: .init()].local = matches
                }
                if debounce { try await Task.sleep(for: .milliseconds(300)) }
                for try await response in store.searchUpdates(requested.query, kind: requested.kind, offset: pageOffset) {
                    try Task.checkCancellation(); guard generation == token, account == store.accountGeneration else { return }
                    sessions[requested, default: .init()].accept(response, offset: pageOffset)
                }
                store.recordSearch(requested.query)
            } catch is CancellationError { } catch {
                if generation == token, account == store.accountGeneration { sessions[requested, default: .init()].fail(error.localizedDescription, offset: pageOffset) }
            }
        }
    }
}
