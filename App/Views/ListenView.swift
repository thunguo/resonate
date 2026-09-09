import SwiftUI
import MusicCore

struct ListenView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let current = store.player.current { continueCard(current) }
                else if store.isLoggedIn { libraryStartCard }
                else { welcomeCard }
                if store.sessionExpired {
                    Button("登录已失效，重新连接") { store.showLogin = true }.font(.subheadline).frame(minHeight: 44)
                }
                collectionSection
                discoverySection
                arrangementEntry
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
        }.cabinetBackground().toolbar(.hidden, for: .navigationBar).refreshable { async let library: Void = store.syncLibrary(); async let discovery: Void = store.refreshDiscoveries(); _ = await (library, discovery) }
    }
    private var header: some View {
        HStack(alignment: .center) {
            Text("听听").font(.largeTitle.weight(.semibold)).accessibilityIdentifier("listenTitle")
            Spacer()
            Text(Date.now.formatted(.dateTime.month().day())).font(.subheadline).foregroundStyle(Palette.secondary)
        }.padding(.bottom, 2)
    }
    private func continueCard(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(playbackTitle).font(.subheadline.weight(.medium)); Spacer(); Image(systemName: "arrow.up.right").font(.caption) }.foregroundStyle(Palette.secondary)
            Button { store.showPlayer = true } label: {
                GeometryReader { geometry in Artwork(url: track.album.artwork, size: geometry.size.width, radius: 12) }.aspectRatio(1, contentMode: .fit)
            }.buttonStyle(MusicPressStyle()).accessibilityLabel("打开播放器，\(track.title)")
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(track.title).font(.title2.weight(.semibold)).lineLimit(2)
                    Text(track.artistName).font(.subheadline).foregroundStyle(Palette.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { store.player.toggle() } label: { Image(systemName: store.player.snapshot.offersPause ? "pause.fill" : "play.fill").font(.title3).frame(width: 56, height: 56).foregroundStyle(Palette.background).background(Palette.accent, in: Circle()) }
                    .buttonStyle(MusicPressStyle()).accessibilityLabel(store.player.snapshot.offersPause ? "暂停" : "继续播放").accessibilityValue(store.player.snapshot.phase.label).accessibilityIdentifier("continuePlayback")
            }
        }.padding(18).background { ArtworkAtmosphere(url: track.album.artwork).clipShape(RoundedRectangle(cornerRadius: 24)) }
    }
    private var playbackTitle: String {
        switch store.player.snapshot.phase {
        case .playing: "正在听"
        case .preparing, .restoring, .interrupted, .failed: store.player.snapshot.phase.label
        default: "继续听"
        }
    }
    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow(text: "余音")
            Text("收藏值得反复听。").font(.title.weight(.medium)).lineSpacing(6)
            Text("带上网易云里的收藏，从喜欢的音乐开始。").font(.subheadline).foregroundStyle(Palette.secondary).lineSpacing(4)
            Button { store.showLogin = true } label: { Label("连接网易云音乐", systemImage: "arrow.up.right").frame(minHeight: 44) }.buttonStyle(MusicPressStyle()).foregroundStyle(Palette.accent).accessibilityIdentifier("connectMusic")
        }.frame(maxWidth: .infinity, alignment: .leading).padding(24).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }
    private var libraryStartCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow(text: "余音")
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
        }.buttonStyle(MusicPressStyle()).tint(Palette.accent).frame(maxWidth: .infinity, alignment: .leading).padding(24).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }
    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                SectionHeading(title: "从收藏里听起", subtitle: "那些值得再听一次的喜欢")
                if store.canRefreshRediscoveries {
                    Button("换一组", systemImage: "arrow.clockwise") { store.refreshRediscoverySelection() }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44).buttonStyle(MusicPressStyle())
                        .disabled(store.isRefreshingRediscoveries).accessibilityIdentifier("refreshRediscoveries")
                }
            }
            if store.rediscoveries.isEmpty {
                HStack(spacing: 16) { Image(systemName: "heart").font(.title2.weight(.ultraLight)); Text(store.isSyncing ? "正在找回你的收藏…" : store.syncError != nil && store.isLoggedIn ? "同步后，你的收藏会出现在这里。" : store.isLoggedIn ? "收藏几首歌，这里会慢慢长成你的样子。" : "登录后，让旧收藏重新响起。").font(.subheadline).foregroundStyle(Palette.secondary); Spacer() }.padding(.vertical, 12)
            } else {
                let tracks = Array(store.rediscoveries.prefix(3))
                ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in TrackRow(track: track, subtitle: track.artistName + " · " + (track.reason ?? "来自你的收藏")) { store.player.play(store.rediscoveries, at: i) } }
                HStack {
                    Button { store.recordCollectionReplay(); store.player.play(store.rediscoveries) } label: { Label("重听这 \(store.rediscoveries.count) 首", systemImage: "play.fill").font(.subheadline).frame(minHeight: 44).contentShape(Rectangle()) }.buttonStyle(MusicPressStyle()).foregroundStyle(Palette.accent)
                    Spacer()
                    NavigationLink { RediscoveryView() } label: { Text("查看全部").font(.subheadline).frame(minHeight: 44) }.accessibilityIdentifier("viewRediscoveries")
                }
                Text("约 \(Int(store.rediscoveries.reduce(0) { $0 + $1.duration } / 60)) 分钟").font(.footnote).foregroundStyle(Palette.secondary)
            }
        }.animation(.easeOut(duration: reduceMotion ? Motion.reduced : Motion.state), value: store.rediscoveries.map(\.id))
    }
    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeading(title: "今天的新发现", subtitle: store.isLoggedIn ? "来自网易云每日推荐" : "从新的旋律开始探索")
            if store.isLoading && store.discoveries.isEmpty { DelayedProgress(title: "正在寻找音乐…") }
            if let error = store.discoveryError, store.discoveries.isEmpty { InlineError(message: error) { Task { await store.refreshDiscoveries() } } }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 230 : 150), spacing: 20)], alignment: .leading, spacing: 24) {
                ForEach(Array(store.discoveries.prefix(6).enumerated()), id: \.element.id) { index, track in
                    Button { store.player.play(store.discoveries, at: index, origin: .search) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            GeometryReader { g in Artwork(url: track.album.artwork, size: g.size.width, radius: 7) }.aspectRatio(1, contentMode: .fit)
                            Text(track.title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.text).lineLimit(2)
                            Text(track.reason ?? track.artistName).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .topLeading)
                    }.buttonStyle(MusicPressStyle())
                }
            }
        }
    }
    private var arrangementEntry: some View {
        Button { store.arrangementPrompt = ""; store.showArrangement = true } label: {
            HStack(spacing: 16) { Image(systemName: "slider.horizontal.3").font(.title3.weight(.light)); VStack(alignment: .leading, spacing: 6) { Text("换一种听法").font(.headline); Text("说说此刻想听什么").font(.subheadline).foregroundStyle(Palette.secondary) }; Spacer(); Image(systemName: "arrow.up.right").font(.subheadline) }.padding(.vertical, 22).padding(.horizontal, 20).background(Palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(MusicPressStyle()).accessibilityIdentifier("arrangeEntry")
    }
}
