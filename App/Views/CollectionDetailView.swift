import SwiftUI
import MusicCore

struct CollectionDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var playlist: Playlist?
    var album: Album?
    var artist: Artist?
    @State private var tracks: [Track] = []
    @State private var artistAlbums: [Album] = []
    @State private var albumOffset = 0
    @State private var moreAlbums = false
    @State private var albumError: String?
    @State private var error: String?
    @State private var loading = true
    @State private var busy = false
    @State private var query = ""
    @State private var renamedTitle: String?
    @State private var proposedName = ""
    @State private var renaming = false
    @State private var deleting = false
    @State private var editing = false
    @State private var adding = false
    @State private var selecting = false
    @State private var selectedTracks: [Track] = []
    @State private var pickingDestination = false
    private var title: String { renamedTitle ?? playlist?.name ?? album?.name ?? artist?.name ?? "音乐" }
    private var artwork: URL? { playlist?.artwork ?? album?.artwork ?? artist?.artwork }
    private var owned: Bool { guard let playlist, let user = store.profile else { return false }; return playlist.creatorID == user.id }
    private var filtered: [Track] { tracks.filter { query.isEmpty || ($0.title + $0.artistName + $0.album.name).localizedCaseInsensitiveContains(query) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) { coverHeader; VStack(alignment: .leading, spacing: 16) { Artwork(url: artwork, size: 132, radius: artist == nil ? 6 : 66); heading } }
                if let summary = playlist?.summary, !summary.isEmpty { Text(summary).font(.subheadline).foregroundStyle(Palette.secondary).lineLimit(4) }
                HStack(spacing: 12) {
                    FilledButton(title: query.isEmpty ? "播放" : "播放筛选结果", symbol: "play.fill") { store.player.play(filtered, origin: album != nil ? .album : .playlist) }.disabled(filtered.isEmpty)
                    IconButton(symbol: "text.append", label: "加入队列") { store.player.enqueue(filtered); store.notify("已加入队列") }.disabled(filtered.isEmpty)
                    if let playlist { IconButton(symbol: store.preferences.pinnedPlaylists.contains(playlist.id) ? "pin.fill" : "pin", label: "固定歌单") { store.pinPlaylist(playlist.id) } }
                }
                if loading { ProgressView("正在读取音乐…").frame(maxWidth: .infinity).padding(30) }
                if let error { InlineError(message: error) { Task { await load(refresh: true) } } }
                if !tracks.isEmpty {
                    HStack { Image(systemName: "magnifyingglass"); TextField("在歌曲中查找", text: $query); if !query.isEmpty { IconButton(symbol: "xmark.circle.fill", label: "清除筛选") { query = "" } } }.foregroundStyle(Palette.secondary).frame(minHeight: 44)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, track in
                            TrackRow(track: track, index: index + 1) { store.player.play(filtered, at: index, origin: album != nil ? .album : .playlist) }
                        }
                    }
                    if filtered.isEmpty { Text("没有找到匹配的歌曲").foregroundStyle(Palette.secondary) }
                } else if !loading, error == nil { EmptyState(symbol: "music.note.list", title: "还没有歌曲", detail: owned ? "从右上角添加喜欢的音乐。" : "稍后刷新再看看。") }
                if artist != nil { albumsSection }
            }.padding(20)
        }.cabinetBackground().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if owned {
                        Button("添加歌曲", systemImage: "plus") { adding = true }
                        Button("调整顺序与移除", systemImage: "list.bullet") { editing = true }.disabled(tracks.isEmpty || loading)
                        Button("重命名歌单", systemImage: "pencil") { proposedName = title; renaming = true }
                        Button("删除歌单", systemImage: "trash", role: .destructive) { deleting = true }
                    } else { Button(isSubscribed ? "取消收藏" : "收藏", systemImage: isSubscribed ? "checkmark.circle" : "plus.circle") { subscribe() } }
                    Button("批量加入其他歌单", systemImage: "text.badge.plus") { if store.requireLogin() { selecting = true } }.disabled(tracks.isEmpty)
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("音乐操作").disabled(busy)
            }
        }
        .task { await load() }.refreshable { await load(refresh: true) }
        .alert("重命名歌单", isPresented: $renaming) { TextField("歌单名称", text: $proposedName); Button("取消", role: .cancel) { }; Button("保存") { rename() } }
        .confirmationDialog("从网易云删除“\(title)”？此操作无法撤销。", isPresented: $deleting, titleVisibility: .visible) { Button("删除歌单", role: .destructive) { delete() } }
        .sheet(isPresented: $editing, onDismiss: { Task { await load(refresh: true) } }) { if let playlist { PlaylistTrackEditor(playlist: playlist, original: tracks) } }
        .sheet(isPresented: $adding) {
            TrackSelectionView(title: "添加歌曲", tracks: store.library.likedTracks, allowsSearch: true) { selection in
                guard let playlist else { return }
                Task { await store.changePlaylist(playlist, tracks: selection, adding: true); await load(refresh: true) }
            }
        }
        .sheet(isPresented: $selecting, onDismiss: { if !selectedTracks.isEmpty { pickingDestination = true } }) {
            TrackSelectionView(tracks: filtered) { selectedTracks = $0 }
        }
        .sheet(isPresented: $pickingDestination, onDismiss: { selectedTracks = [] }) { PlaylistPicker(tracks: selectedTracks) }
    }
    private var coverHeader: some View { HStack(spacing: 20) { Artwork(url: artwork, size: 132, radius: artist == nil ? 6 : 66); heading.fixedSize(horizontal: false, vertical: true) } }
    private var heading: some View { VStack(alignment: .leading, spacing: 12) { Eyebrow(text: artist != nil ? "音乐人" : album != nil ? "专辑" : "歌单"); Text(title).font(.title2.weight(.medium)); Text(album?.artistName ?? "\(tracks.count) 首歌曲").font(.subheadline).foregroundStyle(Palette.secondary) } }
    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "专辑")
            ForEach(artistAlbums) { album in NavigationLink { CollectionDetailView(album: album) } label: { HStack(spacing: 14) { Artwork(url: album.artwork, size: 62); Text(album.name).foregroundStyle(Palette.text); Spacer(); Image(systemName: "chevron.right").font(.caption) } }.buttonStyle(.plain) }
            if let albumError { InlineError(message: albumError) { Task { await loadAlbums() } } }
            if moreAlbums { Button("更多专辑") { Task { await loadAlbums() } }.frame(minHeight: 44).disabled(busy) }
        }
    }
    private var isSubscribed: Bool { if let album { return store.library.albums.contains { $0.id == album.id } }; if let artist { return store.library.artists.contains { $0.id == artist.id } }; return store.library.playlists.contains { $0.id == playlist?.id } }
    private func load(refresh: Bool = false) async {
        loading = true; error = nil; defer { loading = false }
        do {
            if let playlist { tracks = try await store.playlistTracks(playlist.id, refresh: refresh) }
            if let album { tracks = try await store.albumTracks(album.id, refresh: refresh) }
            if let artist { tracks = try await store.artistTracks(artist.id, refresh: refresh) }
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
        if artist != nil, artistAlbums.isEmpty || refresh { artistAlbums = []; albumOffset = 0; await loadAlbums(refresh: refresh) }
    }
    private func loadAlbums(refresh: Bool = false) async {
        guard let artist else { return }; busy = true; albumError = nil; defer { busy = false }
        do {
            let page = try await store.artistAlbumPage(artist.id, offset: albumOffset, refresh: refresh)
            let existing = Set(artistAlbums.map(\.id)); let fresh = page.albums.filter { !existing.contains($0.id) }
            artistAlbums += fresh; albumOffset += page.albums.count; moreAlbums = page.more && !fresh.isEmpty
        } catch is CancellationError { } catch { albumError = error.localizedDescription }
    }
    private func rename() {
        guard let playlist, let id = store.profile?.id else { return }; busy = true
        Task { defer { busy = false }; do { try await store.music.renamePlaylist(playlist.id, name: proposedName, userID: id); guard store.profile?.id == id else { return }; renamedTitle = proposedName.trimmingCharacters(in: .whitespacesAndNewlines); await store.syncLibrary() } catch { self.error = error.localizedDescription } }
    }
    private func delete() {
        guard let playlist, let id = store.profile?.id else { return }; busy = true
        Task { defer { busy = false }; do { try await store.music.deletePlaylist(playlist.id, userID: id); guard store.profile?.id == id else { return }; store.invalidatePlaylist(playlist.id); store.preferences.pinnedPlaylists.remove(playlist.id); store.savePreferences(); await store.syncLibrary(); dismiss() } catch { self.error = error.localizedDescription } }
    }
    private func subscribe() {
        guard store.requireLogin() else { return }; busy = true
        let id = album?.id ?? artist?.id ?? playlist?.id ?? 0
        let kind: SearchKind = album != nil ? .albums : artist != nil ? .artists : .playlists
        let value = !isSubscribed
        Task { defer { busy = false }; do { try await store.music.subscribe(id: id, kind: kind, subscribed: value); await store.syncLibrary() } catch { store.report(error) } }
    }
}
struct PlaylistPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let tracks: [Track]
    var body: some View {
        NavigationStack {
            List { ForEach(store.library.playlists.filter { $0.creatorID == store.profile?.id }) { playlist in Button { Task { await store.changePlaylist(playlist, tracks: tracks, adding: true); dismiss() } } label: { HStack(spacing: 14) { Artwork(url: playlist.artwork, size: 48); Text(playlist.name).foregroundStyle(Palette.text) } }.listRowBackground(Palette.background) } }
                .cabinetList().navigationTitle("加入歌单").toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
    }
}
