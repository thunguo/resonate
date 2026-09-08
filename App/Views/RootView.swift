import SwiftUI
import MusicCore

struct RootView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            NavigationStack { ListenView() }.id("listen-\(store.profile?.id ?? 0)").safeAreaInset(edge: .bottom, spacing: 0) { accessory }.tabItem { Label("听听", systemImage: "waveform") }.tag(0)
            NavigationStack { LibraryView() }.id("library-\(store.profile?.id ?? 0)").safeAreaInset(edge: .bottom, spacing: 0) { accessory }.tabItem { Label("音乐库", systemImage: "square.stack") }.tag(1)
            NavigationStack { SearchView() }.id("search-\(store.profile?.id ?? 0)").safeAreaInset(edge: .bottom, spacing: 0) { accessory }.tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(2)
        }
        .cabinetBackground()
        .sheet(isPresented: Binding(get: { store.showLogin && !store.showPlayer && !store.showArrangement && !store.showSettings }, set: { store.showLogin = $0 })) { LoginView() }
        .sheet(isPresented: $store.showSettings) { NavigationStack { SettingsView() } }
        .sheet(isPresented: $store.showArrangement) { ArrangementView(initialPrompt: store.arrangementPrompt) }
        .fullScreenCover(isPresented: $store.showPlayer) { PlayerView() }
        .overlay(alignment: .top) {
            if let notice = store.notice {
                Text(notice.message).font(.subheadline).padding(14).background(.regularMaterial, in: Capsule()).padding(20)
                    .onTapGesture { store.notice = nil }
                    .task(id: notice.id) { try? await Task.sleep(for: .seconds(4)); if store.notice?.id == notice.id { store.notice = nil } }
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--player") { store.showPlayer = true }
            if ProcessInfo.processInfo.arguments.contains("--library") { store.selectedTab = 1 }
            if ProcessInfo.processInfo.arguments.contains("--settings") { store.showSettings = true }
        }
    }
    @ViewBuilder private var accessory: some View { if store.player.current != nil { MiniPlayer().padding(.horizontal, 12).padding(.bottom, 8) } }
}
struct MiniPlayer: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if let track = store.player.current {
            HStack(spacing: 10) {
                Button { store.showPlayer = true } label: {
                    HStack(spacing: 10) { Artwork(url: track.album.artwork, size: 42, radius: 5); VStack(alignment: .leading, spacing: 3) { Text(track.title).font(.subheadline.weight(.medium)).lineLimit(1); Text(track.artistName).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading) }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("miniPlayer").accessibilityLabel("打开播放器，\(track.title)")
                if store.player.isBuffering { Button { store.player.pause() } label: { ProgressView().frame(width: 44, height: 44) }.accessibilityLabel("暂停加载") }
                else { IconButton(symbol: store.player.isPlaying ? "pause.fill" : "play.fill", label: store.player.isPlaying ? "暂停" : "继续播放") { store.player.toggle() } }
                IconButton(symbol: "forward.end.fill", label: "下一首", size: 17) { store.player.next() }
            }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17)).overlay(alignment: .bottomLeading) {
                GeometryReader { g in Rectangle().fill(Palette.accent.opacity(0.4)).frame(width: g.size.width * min(1, store.player.position / max(1, store.player.duration)), height: 1) }.frame(height: 1).padding(.horizontal, 16)
            }.foregroundStyle(Palette.text)
        }
    }
}
