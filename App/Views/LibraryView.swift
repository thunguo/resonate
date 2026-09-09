import SwiftUI
import MusicCore

enum LibrarySection: String, CaseIterable, Identifiable {
    case favorites = "喜欢", playlists = "歌单", albums = "专辑", artists = "音乐人", downloads = "下载"
    var id: String { rawValue }
}
struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @State private var section = LibrarySection.favorites
    @State private var filters: [LibrarySection: String] = [:]
    @State private var anchors: [LibrarySection: String] = [:]
    private var filter: String { filters[section] ?? "" }
    private var filterBinding: Binding<String> { Binding(get: { filter }, set: { filters[section] = $0 }) }
    private var anchor: Binding<String?> { let selected = section; return Binding(get: { anchors[selected] }, set: { anchors[selected] = $0 }) }
    @State private var newPlaylist = false
    private var sort: LibrarySort { store.preferences.librarySort[section.rawValue] ?? .original }
    @State private var filteredTracks: [Track] = []
    @State private var playlists: [Playlist] = []
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    private var filterKey: String { "\(store.libraryRevision)|\(filter)|\(section)|\(sort)|\(store.preferences.pinnedPlaylists.sorted())" }
    private var matchCount: Int { switch section { case .favorites: return filteredTracks.count; case .playlists: return playlists.count; case .albums: return albums.count; case .artists: return artists.count; case .downloads: return 1 } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) { Text("音乐库").font(.largeTitle.weight(.semibold)); Spacer(); IconButton(symbol: "slider.horizontal.3", label: "设置") { store.showSettings = true }.accessibilityIdentifier("settingsButton") }
                if !store.isLoggedIn && !store.previewMode {
                    Button { store.showLogin = true } label: { HStack { Image(systemName: "person.crop.circle"); Text("连接网易云，带上你的收藏"); Spacer(); Image(systemName: "arrow.up.right") }.font(.subheadline).padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LibrarySection.allCases.filter { $0 != .downloads || !store.downloads.records.isEmpty }) { item in Button { section = item } label: { Text(item.rawValue).font(.body.weight(section == item ? .semibold : .regular)).padding(.horizontal, 10).frame(minHeight: 44).foregroundStyle(section == item ? Palette.text : Palette.secondary).overlay(alignment: .bottom) { if section == item { Capsule().fill(Palette.accent).frame(height: 2) } } }.buttonStyle(.plain) }
                    }
                }
                if section != .downloads {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                        TextField("在\(section.rawValue)中查找", text: filterBinding).submitLabel(.search)
                        if !filter.isEmpty { Button { filters[section] = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }.accessibilityLabel("清除筛选") }
                        Menu { ForEach(LibrarySort.allCases.filter { $0 != .artist || section == .favorites || section == .albums }) { value in
                            Button { store.preferences.librarySort[section.rawValue] = value; store.savePreferences() } label: { Label(value.label, systemImage: sort == value ? "checkmark" : "") }
                        } } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44) }.accessibilityLabel("排序")
                    }.padding(.leading, 12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                }
                if store.isSyncing && store.library.likedTracks.isEmpty { DelayedProgress(title: store.syncProgress) }
                if let error = store.syncError { InlineError(message: "部分收藏未更新，已保留相应的上次资料。\n" + error) { Task { await store.syncLibrary() } } }
                if !store.pendingMutations.isEmpty { NavigationLink { PendingSyncView() } label: { Label("\(store.pendingMutations.count) 项更改待同步", systemImage: "arrow.triangle.2.circlepath").font(.subheadline) } }
                if store.pendingCreation != nil { Button("核对上次创建的歌单") { newPlaylist = true }.frame(minHeight: 44) }
                content
                if !filter.isEmpty, matchCount == 0 { Text("没有找到匹配的收藏").font(.subheadline).foregroundStyle(Palette.secondary).padding(.vertical, 20) }
            }.scrollTargetLayout().padding(20)
        }.scrollPosition(id: anchor, anchor: .top).cabinetBackground().toolbar(.hidden, for: .navigationBar).refreshable { await store.syncLibrary() }
        .task(id: filterKey) {
            let library = store.library, query = filter, order = sort, pinned = store.preferences.pinnedPlaylists
            let value = await Task.detached(priority: .userInitiated) { LibraryDisplay.make(library, query: query, order: order, pinned: pinned) }.value
            guard !Task.isCancelled else { return }
            filteredTracks = value.tracks; playlists = value.playlists; albums = value.albums; artists = value.artists
        }
        .onChange(of: store.accountGeneration) { _, _ in filters = [:]; anchors = [:]; section = .favorites }
        .sheet(isPresented: $newPlaylist) { PlaylistCreationView() }

    }
    @ViewBuilder private var content: some View {
        switch section {
        case .favorites:
            if !store.library.likedTracks.isEmpty {
                HStack {
                    Text("\(filteredTracks.count) 首喜欢").font(.subheadline).foregroundStyle(Palette.secondary)
                    Spacer()
                    Button { store.player.play(filteredTracks) } label: { Label("播放", systemImage: "play.fill").font(.subheadline.weight(.medium)).frame(minHeight: 44) }.buttonStyle(MusicPressStyle()).disabled(filteredTracks.isEmpty)
                }
                LazyVStack(spacing: 0) { ForEach(Array(filteredTracks.enumerated()), id: \.element.id) { i, track in TrackRow(track: track) { store.player.play(filteredTracks, at: i) }.id("track-\(track.id)") } }.scrollTargetLayout()
            } else { EmptyState(symbol: "heart", title: "喜欢会慢慢积累", detail: "遇到想再听一次的歌，点一下喜欢。") }
        case .playlists:
            HStack { SectionHeading(title: "你的歌单"); IconButton(symbol: "plus", label: "新建歌单") { if store.requireLogin() { newPlaylist = true } } }
            ForEach(playlists) { playlist in
                NavigationLink { CollectionDetailView(playlist: playlist) } label: {
                    HStack(spacing: 14) { Artwork(url: playlist.artwork, size: 62); VStack(alignment: .leading, spacing: 6) { Text(playlist.name).lineLimit(2); Text("\(playlist.count) 首").font(.caption).foregroundStyle(Palette.secondary) }; Spacer(); if store.preferences.pinnedPlaylists.contains(playlist.id) { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Palette.accent) } }
                }.buttonStyle(.plain).id("playlist-\(playlist.id)").contextMenu { Button(store.preferences.pinnedPlaylists.contains(playlist.id) ? "取消固定" : "固定歌单", systemImage: "pin") { store.pinPlaylist(playlist.id) } }
            }
            if store.library.playlists.isEmpty { EmptyState(symbol: "music.note.list", title: "留一张歌单", detail: "同步网易云歌单，或将一段新的听歌体验保存下来。") }
        case .albums:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 20)], spacing: 24) {
                ForEach(albums) { album in NavigationLink { CollectionDetailView(album: album) } label: { VStack(alignment: .leading, spacing: 8) { GeometryReader { g in Artwork(url: album.artwork, size: g.size.width) }.aspectRatio(1, contentMode: .fit); Text(album.name).font(.subheadline).lineLimit(2); Text(album.artistName).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1) } }.buttonStyle(.plain).id("album-\(album.id)") }
            }.scrollTargetLayout()
            if store.library.albums.isEmpty { EmptyState(symbol: "square.stack", title: "整张专辑，完整聆听", detail: "收藏的专辑会放在这里。") }
        case .artists:
            ForEach(artists) { artist in NavigationLink { CollectionDetailView(artist: artist) } label: { HStack(spacing: 16) { Artwork(url: artist.artwork, size: 60, radius: 30); Text(artist.name); Spacer(); Image(systemName: "chevron.right").font(.caption) } }.buttonStyle(.plain).id("artist-\(artist.id)") }
            if store.library.artists.isEmpty { EmptyState(symbol: "person.crop.circle", title: "跟随喜欢的声音", detail: "关注的音乐人会放在这里。") }
        case .downloads: DownloadListContent()
        }
    }
}
struct PendingSyncView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        List { ForEach(store.pendingMutations) { item in VStack(alignment: .leading, spacing: 8) { Text(item.kind == .like ? "更新喜欢的歌曲" : "更新歌单"); Text(item.status).font(.caption).foregroundStyle(Palette.secondary); HStack { Button("重试") { Task { await store.retryMutation(item.id) } }.disabled(item.status == "正在同步"); Spacer(); Button("取消重试", role: .destructive) { store.discardMutation(item.id) }.disabled(item.status == "正在同步") } }.listRowBackground(Palette.background) } }.cabinetList().navigationTitle("待同步更改")
    }
}
struct DownloadListContent: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeading(title: "已下载", subtitle: "\(store.downloads.records.filter { $0.status == .complete }.count) 首 · \(ByteCountFormatter.string(fromByteCount: store.downloads.records.reduce(0) { $0 + $1.bytes }, countStyle: .file))")
            if !store.downloads.isAuthorized { Text("离线下载尚未开放。获得相应下载授权后，此功能会在更新中启用。").font(.subheadline).foregroundStyle(Palette.secondary).lineSpacing(4) }
            ForEach(store.downloads.records) { record in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Artwork(url: record.track.album.artwork, size: 44); VStack(alignment: .leading) { Text(record.track.title); Text(record.licenseExpiresAt < .now ? "授权已到期" : status(record)).font(.caption).foregroundStyle(Palette.secondary) }; Spacer();
                        if record.status == .complete { IconButton(symbol: "play.fill", label: "播放下载") { store.player.play([record.track]) } }
                        else if record.status == .downloading || record.status == .waiting { IconButton(symbol: "pause", label: "暂停下载") { store.downloads.pause(record.id) } }
                        else { IconButton(symbol: "arrow.clockwise", label: "恢复下载") { store.downloads.start(record.id) } }
                        IconButton(symbol: "trash", label: "删除下载") { store.downloads.remove(record.id) }
                    }
                    if record.status == .downloading { ProgressView(value: record.progress).tint(Palette.accent) }
                }
            }
            if store.downloads.records.isEmpty { EmptyState(symbol: "arrow.down.circle", title: "把音乐带在身边", detail: "可下载的歌曲会保存在设备上，方便离线聆听。") }
        }
    }
    func status(_ record: DownloadRecord) -> String { switch record.status { case .waiting: return "等待下载"; case .downloading: return "正在下载 \(Int(record.progress * 100))%"; case .paused: return "已暂停"; case .complete: return "可离线播放"; case .failed: return record.error ?? "下载失败" } }
}

private struct LibraryDisplay: Sendable {
    var tracks: [Track]; var playlists: [Playlist]; var albums: [Album]; var artists: [Artist]
    static func make(_ library: LibrarySnapshot, query: String, order: LibrarySort, pinned: Set<Int64>) -> Self {
        func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }
        func sorted<T>(_ items: [T], name: (T) -> String, artist: (T) -> String = { _ in "" }) -> [T] {
            guard order != .original else { return items }
            return items.enumerated().sorted {
                let a = order == .artist ? artist($0.element) + name($0.element) : name($0.element)
                let b = order == .artist ? artist($1.element) + name($1.element) : name($1.element)
                let result = a.localizedStandardCompare(b)
                return result == .orderedSame ? $0.offset < $1.offset : result == .orderedAscending
            }.map(\.element)
        }
        let lists = sorted(library.playlists.filter { matches($0.name) }, name: { $0.name })
        return .init(tracks: sorted(library.likedTracks.filter { matches($0.title + $0.artistName + $0.album.name) }, name: { $0.title }, artist: { $0.artistName }),
            playlists: lists.filter { pinned.contains($0.id) } + lists.filter { !pinned.contains($0.id) },
            albums: sorted(library.albums.filter { matches($0.name + $0.artistName) }, name: { $0.name }, artist: { $0.artistName }),
            artists: sorted(library.artists.filter { matches($0.name) }, name: { $0.name }))
    }
}
