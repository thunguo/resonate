import SwiftUI
import MusicCore

enum LibrarySection: String, CaseIterable, Identifiable {
    case favorites = "喜欢", playlists = "歌单", albums = "专辑", artists = "音乐人", downloads = "下载"
    var id: String { rawValue }
}
struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @State private var section = LibrarySection.favorites
    @State private var filter = ""
    @State private var newPlaylist = false
    private var sort: LibrarySort { store.preferences.librarySort[section.rawValue] ?? .original }
    private func sorted<T>(_ items: [T], name: (T) -> String, artist: (T) -> String = { _ in "" }) -> [T] {
        guard sort != .original else { return items }
        return items.enumerated().sorted { lhs, rhs in
            let a = sort == .artist ? artist(lhs.element) + name(lhs.element) : name(lhs.element)
            let b = sort == .artist ? artist(rhs.element) + name(rhs.element) : name(rhs.element)
            let order = a.localizedStandardCompare(b)
            return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
        }.map(\.element)
    }
    var filteredTracks: [Track] { sorted(store.library.likedTracks.filter { filter.isEmpty || ($0.title + $0.artistName + $0.album.name).localizedCaseInsensitiveContains(filter) }, name: { $0.title }, artist: { $0.artistName }) }
    private var playlists: [Playlist] {
        let items = sorted(store.library.playlists.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }, name: { $0.name })
        return items.filter { store.preferences.pinnedPlaylists.contains($0.id) } + items.filter { !store.preferences.pinnedPlaylists.contains($0.id) }
    }
    private var albums: [Album] { sorted(store.library.albums.filter { filter.isEmpty || ($0.name + $0.artistName).localizedCaseInsensitiveContains(filter) }, name: { $0.name }, artist: { $0.artistName }) }
    private var artists: [Artist] { sorted(store.library.artists.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }, name: { $0.name }) }
    private var matchCount: Int { switch section { case .favorites: return filteredTracks.count; case .playlists: return playlists.count; case .albums: return albums.count; case .artists: return artists.count; case .downloads: return 1 } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) { VStack(alignment: .leading, spacing: 8) { Eyebrow(text: store.profile?.name ?? "私人音乐藏馆"); Text("音乐库").font(.largeTitle.weight(.medium)) }; Spacer(); IconButton(symbol: "slider.horizontal.3", label: "设置") { store.showSettings = true }.accessibilityIdentifier("settingsButton") }
                if !store.isLoggedIn && !store.previewMode {
                    Button { store.showLogin = true } label: { HStack { Image(systemName: "person.crop.circle"); Text("连接网易云，带上你的收藏"); Spacer(); Image(systemName: "arrow.up.right") }.font(.subheadline).padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LibrarySection.allCases) { item in Button { section = item } label: { Text(item.rawValue).font(.subheadline.weight(section == item ? .semibold : .regular)).padding(.horizontal, 16).frame(minHeight: 44).foregroundStyle(section == item ? Palette.background : Palette.secondary).background(section == item ? Palette.accent : Palette.surface.opacity(0.5), in: Capsule()) }.buttonStyle(.plain) }
                    }
                }
                if section != .downloads {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                        TextField("在\(section.rawValue)中查找", text: $filter).submitLabel(.search)
                        if !filter.isEmpty { Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }.accessibilityLabel("清除筛选") }
                        Menu { ForEach(LibrarySort.allCases.filter { $0 != .artist || section == .favorites || section == .albums }) { value in
                            Button { store.preferences.librarySort[section.rawValue] = value; store.savePreferences() } label: { Label(value.label, systemImage: sort == value ? "checkmark" : "") }
                        } } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44) }.accessibilityLabel("排序")
                    }.padding(.leading, 12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                }
                if store.isSyncing { ProgressView(store.syncProgress).font(.subheadline) }
                if let error = store.syncError { InlineError(message: "部分收藏未更新，已保留相应的上次资料。\n" + error) { Task { await store.syncLibrary() } } }
                if !store.pendingMutations.isEmpty { NavigationLink { PendingSyncView() } label: { Label("\(store.pendingMutations.count) 项更改待同步", systemImage: "arrow.triangle.2.circlepath").font(.subheadline) } }
                if store.pendingCreation != nil { Button("核对上次创建的歌单") { newPlaylist = true }.frame(minHeight: 44) }
                content
                if !filter.isEmpty, matchCount == 0 { Text("没有找到匹配的收藏").font(.subheadline).foregroundStyle(Palette.secondary).padding(.vertical, 20) }
            }.padding(20)
        }.cabinetBackground().toolbar(.hidden, for: .navigationBar).refreshable { await store.syncLibrary() }
        .onChange(of: section) { _, _ in filter = "" }
        .sheet(isPresented: $newPlaylist) { PlaylistCreationView() }

    }
    @ViewBuilder private var content: some View {
        switch section {
        case .favorites:
            Text("\(filteredTracks.count) 首喜欢").font(.subheadline).foregroundStyle(Palette.secondary)
            if !store.library.likedTracks.isEmpty {
                FilledButton(title: "播放喜欢的歌", symbol: "play.fill") { store.player.play(filteredTracks) }.disabled(filteredTracks.isEmpty)
                LazyVStack(spacing: 0) { ForEach(Array(filteredTracks.enumerated()), id: \.element.id) { i, track in TrackRow(track: track) { store.player.play(filteredTracks, at: i) } } }
            } else { EmptyState(symbol: "heart", title: "喜欢会慢慢积累", detail: "遇到想再听一次的歌，点一下喜欢。") }
        case .playlists:
            HStack { SectionHeading(title: "你的歌单"); IconButton(symbol: "plus", label: "新建歌单") { if store.requireLogin() { newPlaylist = true } } }
            ForEach(playlists) { playlist in
                NavigationLink { CollectionDetailView(playlist: playlist) } label: {
                    HStack(spacing: 14) { Artwork(url: playlist.artwork, size: 62); VStack(alignment: .leading, spacing: 6) { Text(playlist.name).lineLimit(2); Text("\(playlist.count) 首").font(.caption).foregroundStyle(Palette.secondary) }; Spacer(); if store.preferences.pinnedPlaylists.contains(playlist.id) { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Palette.accent) } }
                }.buttonStyle(.plain).contextMenu { Button(store.preferences.pinnedPlaylists.contains(playlist.id) ? "取消固定" : "固定歌单", systemImage: "pin") { store.pinPlaylist(playlist.id) } }
            }
            if store.library.playlists.isEmpty { EmptyState(symbol: "music.note.list", title: "留一张歌单", detail: "同步网易云歌单，或将一段新的听歌体验保存下来。") }
        case .albums:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 20)], spacing: 24) {
                ForEach(albums) { album in NavigationLink { CollectionDetailView(album: album) } label: { VStack(alignment: .leading, spacing: 8) { GeometryReader { g in Artwork(url: album.artwork, size: g.size.width) }.aspectRatio(1, contentMode: .fit); Text(album.name).font(.subheadline).lineLimit(2); Text(album.artistName).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1) } }.buttonStyle(.plain) }
            }
            if store.library.albums.isEmpty { EmptyState(symbol: "square.stack", title: "整张专辑，完整聆听", detail: "收藏的专辑会放在这里。") }
        case .artists:
            ForEach(artists) { artist in NavigationLink { CollectionDetailView(artist: artist) } label: { HStack(spacing: 16) { Artwork(url: artist.artwork, size: 60, radius: 30); Text(artist.name); Spacer(); Image(systemName: "chevron.right").font(.caption) } }.buttonStyle(.plain) }
            if store.library.artists.isEmpty { EmptyState(symbol: "person.crop.circle", title: "跟随喜欢的声音", detail: "关注的音乐人会放在这里。") }
        case .downloads: DownloadListContent()
        }
    }
}
struct PendingSyncView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        List { ForEach(store.pendingMutations) { item in VStack(alignment: .leading, spacing: 8) { Text(item.kind == .like ? "更新喜欢的歌曲" : "更新歌单"); Text(item.status).font(.caption).foregroundStyle(Palette.secondary); HStack { Button("重试") { Task { await store.retryMutation(item.id) } }.disabled(item.status == "正在同步"); Spacer(); Button("取消重试", role: .destructive) { store.discardMutation(item.id) } } }.listRowBackground(Palette.background) } }.cabinetList().navigationTitle("待同步更改")
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
