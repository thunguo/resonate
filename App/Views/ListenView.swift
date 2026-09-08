import SwiftUI
import MusicCore

struct ListenView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                if let current = store.player.current { continueCard(current) }
                else if store.isLoggedIn { libraryStartCard }
                else { welcomeCard }
                collectionSection
                discoverySection
                arrangementEntry
                HStack { Rectangle().fill(Palette.line).frame(height: 1); Image(systemName: "waveform").font(.caption).foregroundStyle(Palette.secondary); Rectangle().fill(Palette.line).frame(height: 1) }.padding(.vertical, 12).accessibilityHidden(true)
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
        }.cabinetBackground().toolbar(.hidden, for: .navigationBar).refreshable { await store.syncLibrary(); await store.refreshDiscoveries() }
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 12) { Eyebrow(text: store.previewMode ? "界面预览 · 示例音乐" : Date.now.formatted(.dateTime.month(.wide).day()) + " · 留一点时间给音乐"); Text("慢慢听。").font(.system(.largeTitle, design: .serif).weight(.medium)).foregroundStyle(Palette.text) }
            Spacer()
            Image(systemName: "sun.horizon").font(.system(size: 25, weight: .ultraLight)).foregroundStyle(Palette.accent).padding(.top, 10).accessibilityHidden(true)
        }
    }
    private func continueCard(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Eyebrow(text: "继续听"); Spacer(); Text("\(timeLabel(store.player.position)) / \(timeLabel(store.player.duration))").font(.caption.monospacedDigit()).foregroundStyle(Palette.secondary) }
            HStack(alignment: .center, spacing: 20) {
                Artwork(url: track.album.artwork, size: typeSize.isAccessibilitySize ? 96 : 132, radius: 6)
                VStack(alignment: .leading, spacing: 9) {
                    Text(track.title).font(.title3.weight(.medium)).lineLimit(3)
                    Text(track.artistName).font(.subheadline).foregroundStyle(Palette.secondary).lineLimit(2)
                    Button { store.player.resume() } label: { Label("继续播放", systemImage: "play.fill").font(.subheadline.weight(.medium)).frame(minHeight: 44) }.buttonStyle(.plain).foregroundStyle(Palette.accent).accessibilityIdentifier("continuePlayback")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).background(Palette.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
    }
    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow(text: "你的音乐藏馆")
            Text("熟悉的旋律，\n也值得重新遇见。").font(.title2.weight(.regular)).lineSpacing(6)
            Text("带上网易云里的收藏，从喜欢的音乐开始。").font(.subheadline).foregroundStyle(Palette.secondary).lineSpacing(4)
            Button { store.showLogin = true } label: { Label("连接网易云音乐", systemImage: "arrow.up.right").frame(minHeight: 44) }.buttonStyle(.plain).foregroundStyle(Palette.accent).accessibilityIdentifier("connectMusic")
        }.frame(maxWidth: .infinity, alignment: .leading).padding(24).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }
    private var libraryStartCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow(text: "你的音乐藏馆")
            Text("从收藏开始听").font(.title2).accessibilityIdentifier("libraryStartTitle")
            if !store.library.likedTracks.isEmpty {
                Text("\(store.library.likedTracks.count) 首喜欢的歌，等你重新听见。").font(.subheadline).foregroundStyle(Palette.secondary)
                Button { store.player.play(store.library.likedTracks) } label: { Label("播放喜欢的歌", systemImage: "play.fill").frame(minHeight: 44) }.accessibilityIdentifier("playLibrary")
            } else if store.isSyncing {
                ProgressView("正在同步你的收藏…").accessibilityIdentifier("homeSyncProgress")
            } else if store.syncError != nil {
                Text("暂时没能读取收藏，可以重新同步。").font(.subheadline).foregroundStyle(Palette.secondary)
                Button("重新同步收藏") { Task { await store.syncLibrary() } }.frame(minHeight: 44).accessibilityIdentifier("retryHomeSync")
            } else if !store.library.playlists.isEmpty || !store.library.albums.isEmpty || !store.library.artists.isEmpty {
                Text("打开音乐库，挑一张熟悉的专辑或歌单。").font(.subheadline).foregroundStyle(Palette.secondary)
                Button("打开音乐库") { store.selectedTab = 1 }.frame(minHeight: 44)
            } else {
                Text("还没有收藏，从一首喜欢的歌开始。").font(.subheadline).foregroundStyle(Palette.secondary)
                Button("去找喜欢的歌") { store.selectedTab = 2 }.frame(minHeight: 44).accessibilityIdentifier("findFirstTrack")
            }
        }.buttonStyle(.plain).tint(Palette.accent).frame(maxWidth: .infinity, alignment: .leading).padding(24).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }
    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: "从收藏里听起", subtitle: "那些很久没听的喜欢")
            if store.rediscoveries.isEmpty {
                HStack(spacing: 16) { Image(systemName: "heart").font(.title2.weight(.ultraLight)); Text(store.isSyncing ? "正在找回你的收藏…" : store.syncError != nil && store.isLoggedIn ? "同步后，你的收藏会出现在这里。" : store.isLoggedIn ? "收藏几首歌，这里会慢慢长成你的样子。" : "登录后，让旧收藏重新响起。").font(.subheadline).foregroundStyle(Palette.secondary); Spacer() }.padding(.vertical, 12)
            } else {
                let tracks = Array(store.rediscoveries.prefix(3))
                ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in TrackRow(track: track) { store.player.play(store.rediscoveries, at: i) } }
                Button { store.recordCollectionReplay(); store.player.play(store.rediscoveries) } label: { Label("重听收藏", systemImage: "play.fill").font(.subheadline).frame(minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
            }
        }
    }
    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeading(title: "今天的新发现", subtitle: store.isLoggedIn ? "来自网易云每日推荐" : "从新的旋律开始探索")
            if store.isLoading && store.discoveries.isEmpty { ProgressView("正在寻找音乐…").frame(maxWidth: .infinity).padding(30) }
            if let error = store.discoveryError, store.discoveries.isEmpty { InlineError(message: error) { Task { await store.refreshDiscoveries() } } }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 230 : 150), spacing: 20)], alignment: .leading, spacing: 24) {
                ForEach(Array(store.discoveries.prefix(6).enumerated()), id: \.element.id) { index, track in
                    Button { store.player.play(store.discoveries, at: index, origin: .search) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            GeometryReader { g in Artwork(url: track.album.artwork, size: g.size.width, radius: 7) }.aspectRatio(1, contentMode: .fit)
                            Text(track.title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.text).lineLimit(2)
                            Text(track.reason ?? track.artistName).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .topLeading)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private var arrangementEntry: some View {
        Button { store.arrangementPrompt = ""; store.showArrangement = true } label: {
            HStack(spacing: 16) { Image(systemName: "slider.horizontal.3").font(.title3.weight(.light)); VStack(alignment: .leading, spacing: 6) { Text("换一种听法").font(.headline); Text("说说此刻想听什么").font(.subheadline).foregroundStyle(Palette.secondary) }; Spacer(); Image(systemName: "arrow.up.right").font(.subheadline) }.padding(.vertical, 22).padding(.horizontal, 20).background(Palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).accessibilityIdentifier("arrangeEntry")
    }
}
