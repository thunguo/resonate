import SwiftUI
import MusicCore
struct SearchView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var local: [Track] = []
    @State private var resultQuery = ""
    @State private var kind = SearchKind.tracks
    @State private var result = SearchResult()
    @State private var isSearching = false
    @State private var didSearch = false
    @State private var error: String?
    @State private var offset = 0
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("搜索").font(.largeTitle.weight(.semibold))
                HStack(spacing: 12) { Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary); TextField("歌曲、音乐人，或此刻的心情", text: $query).submitLabel(.search).onSubmit { search() }.accessibilityIdentifier("searchField"); if !query.isEmpty { IconButton(symbol: "xmark.circle.fill", label: "清空搜索", size: 16) { query = ""; task?.cancel(); generation = UUID(); result = .init(); didSearch = false; isSearching = false } } }.padding(.horizontal, 14).frame(minHeight: 54).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                if !query.isEmpty { Button { store.arrangementPrompt = query; store.showArrangement = true } label: { Label("用这句话编排音乐", systemImage: "slider.horizontal.3").font(.subheadline).frame(minHeight: 44) }.buttonStyle(.plain) }
                Picker("搜索类型", selection: $kind) { ForEach(SearchKind.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented).onChange(of: kind) { _, _ in if !query.isEmpty { search() } }
                if !didSearch && !isSearching { discovery }
                if let error { InlineError(message: error) { search() } }
                if kind == .tracks, !local.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeading(title: "你的收藏")
                        ForEach(Array(local.enumerated()), id: \.element.id) { index, track in TrackRow(track: track) { store.player.play(local, at: index, origin: .search) } }
                    }
                }
                if resultQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) { results }
                if isSearching { DelayedProgress(title: "正在寻找…"); Button("取消搜索") { task?.cancel(); generation = UUID(); isSearching = false }.font(.footnote).frame(minHeight: 44) }
                if result.hasMore && !isSearching { Button("加载更多") { search(more: true) }.frame(maxWidth: .infinity, minHeight: 44) }
                if didSearch && !isSearching && error == nil && local.isEmpty && result.tracks.isEmpty && result.albums.isEmpty && result.artists.isEmpty && result.playlists.isEmpty { EmptyState(symbol: "magnifyingglass", title: "还没有找到", detail: "换一个歌名或音乐人试试，也可以用一句话描述想听的音乐。") }
            }.padding(20)
        }.cabinetBackground().toolbar(.hidden, for: .navigationBar).onChange(of: query) { _, value in if value.isEmpty { task?.cancel(); generation = UUID(); local = []; didSearch = false; isSearching = false } else { search(debounce: true) } }
    }
    private var discovery: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !store.searchHistory.isEmpty { SectionHeading(title: "最近找过"); ForEach(store.searchHistory, id: \.self) { text in Button { query = text; search() } label: { HStack { Image(systemName: "clock").foregroundStyle(Palette.secondary); Text(text); Spacer(); Image(systemName: "arrow.up.left").font(.caption) }.frame(minHeight: 44) }.buttonStyle(.plain) } }
            SectionHeading(title: "也可以这样找", subtitle: "让音乐贴近此刻")
            ForEach(["把收藏里适合散步的歌排四十分钟", "想听轻松一点的，少些人声", "重听那些很久没听的喜欢"], id: \.self) { text in Button { store.arrangementPrompt = text; store.showArrangement = true } label: { HStack { Text(text).font(.subheadline).multilineTextAlignment(.leading); Spacer(); Image(systemName: "arrow.up.right").font(.caption) }.padding(.vertical, 12) }.buttonStyle(.plain) }
        }.padding(.top, 12)
    }
    @ViewBuilder private var results: some View {
        LazyVStack(spacing: 14) {
            switch kind {
            case .tracks: ForEach(Array(result.tracks.filter { track in !local.contains(where: { $0.id == track.id }) }.enumerated()), id: \.element.id) { index, track in TrackRow(track: track) { store.player.play(result.tracks, at: result.tracks.firstIndex(where: { $0.id == track.id }) ?? index, origin: .search) } }
            case .albums: ForEach(result.albums) { album in NavigationLink { CollectionDetailView(album: album) } label: { entityRow(title: album.name, detail: album.artistName, artwork: album.artwork) }.buttonStyle(.plain) }
            case .artists: ForEach(result.artists) { artist in NavigationLink { CollectionDetailView(artist: artist) } label: { entityRow(title: artist.name, detail: "音乐人", artwork: artist.artwork) }.buttonStyle(.plain) }
            case .playlists: ForEach(result.playlists) { playlist in NavigationLink { CollectionDetailView(playlist: playlist) } label: { entityRow(title: playlist.name, detail: "\(playlist.count) 首", artwork: playlist.artwork) }.buttonStyle(.plain) }
            }
        }
    }
    private func entityRow(title: String, detail: String, artwork: URL?) -> some View { HStack(spacing: 16) { Artwork(url: artwork, size: 62); VStack(alignment: .leading, spacing: 6) { Text(title).lineLimit(2); Text(detail).font(.subheadline).foregroundStyle(Palette.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption) } }
    private func search(more: Bool = false, debounce: Bool = false) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }
        task?.cancel(); let token = UUID(); generation = token; isSearching = true; error = nil
        if !more { offset = 0 }
        let pageOffset = more ? offset + 30 : 0, base = more ? result : SearchResult()
        let selectedKind = kind, account = store.accountGeneration
        task = Task {
            do {
                if !more {
                    let matches = selectedKind == .tracks ? await store.musicIndex.search(text, limit: 8) : []
                    try Task.checkCancellation(); guard generation == token else { return }; local = matches
                }
                if debounce { try await Task.sleep(for: .milliseconds(300)) }
                for try await response in store.searchUpdates(text, kind: selectedKind, offset: pageOffset) {
                    try Task.checkCancellation(); guard generation == token, account == store.accountGeneration else { return }
                    var combined = base
                    combined.tracks += response.tracks; combined.albums += response.albums
                    combined.artists += response.artists; combined.playlists += response.playlists; combined.hasMore = response.hasMore
                    result = combined; resultQuery = text; offset = pageOffset; didSearch = true
                }
                store.recordSearch(text)
            } catch is CancellationError { } catch { if generation == token { self.error = error.localizedDescription } }
            if generation == token { isSearching = false }
        }
    }
}
