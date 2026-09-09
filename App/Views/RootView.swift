import SwiftUI
import MusicCore

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var playerSpace
    var body: some View {
        @Bindable var store = store
        tabs.cabinetBackground()
            .sheet(isPresented: Binding(get: { store.showLogin && !store.showPlayer && !store.showArrangement && !store.showSettings }, set: { store.showLogin = $0 })) { LoginView() }
            .sheet(isPresented: $store.showSettings) { NavigationStack { SettingsView() } }
            .sheet(isPresented: $store.showArrangement) { ArrangementView(initialPrompt: store.arrangementPrompt) }
            .fullScreenCover(isPresented: $store.showPlayer) {
                if reduceMotion { PlayerView() }
                else { PlayerView().navigationTransition(.zoom(sourceID: "nowPlaying", in: playerSpace)) }
            }
            .overlay(alignment: .top) {
                if let notice = store.notice {
                    Text(notice.message).font(.subheadline).padding(14).background(.regularMaterial, in: Capsule()).padding(20)
                        .onTapGesture { store.notice = nil }
                        .task(id: notice.id) { try? await Task.sleep(for: .seconds(4)); if store.notice?.id == notice.id { store.notice = nil } }
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in store.preheater.stop() }.onEnded { _ in store.schedulePreheat() })
            .onChange(of: store.showArrangement) { _, shown in if shown { store.preheater.stop() } else { store.schedulePreheat() } }
            .onChange(of: store.selectedTab) { _, _ in store.schedulePreheat() }
            .task {
                if ProcessInfo.processInfo.arguments.contains("--player") { store.showPlayer = true }
                if ProcessInfo.processInfo.arguments.contains("--library") { store.selectedTab = 1 }
                if ProcessInfo.processInfo.arguments.contains("--settings") { store.showSettings = true }
            }
    }
    @ViewBuilder private var tabs: some View {
        if #available(iOS 26.0, *) {
            tabContent.tabViewBottomAccessory { if store.player.current != nil { MiniPlayer(namespace: playerSpace, native: true) } }
        } else { tabContent }
    }
    private var tabContent: some View {
        @Bindable var store = store
        return TabView(selection: $store.selectedTab) {
            NavigationStack { ListenView() }.id("listen-\(store.profile?.id ?? 0)").modifier(LegacyPlayerInset(namespace: playerSpace)).tabItem { Label("听听", systemImage: "waveform") }.tag(0)
            NavigationStack { LibraryView() }.id("library-\(store.profile?.id ?? 0)").modifier(LegacyPlayerInset(namespace: playerSpace)).tabItem { Label("音乐库", systemImage: "square.stack") }.tag(1)
            NavigationStack { SearchView() }.id("search-\(store.profile?.id ?? 0)").modifier(LegacyPlayerInset(namespace: playerSpace)).tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(2)
        }
    }
}
private struct LegacyPlayerInset: ViewModifier {
    @Environment(AppStore.self) private var store
    let namespace: Namespace.ID
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content }
        else { content.safeAreaInset(edge: .bottom, spacing: 0) { if store.player.current != nil { MiniPlayer(namespace: namespace).padding(.horizontal, 12).padding(.bottom, 8) } } }
    }
}
struct MiniPlayer: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let namespace: Namespace.ID
    var native = false
    var body: some View {
        if let track = store.player.current {
            HStack(spacing: 10) {
                Button { store.showPlayer = true } label: {
                    HStack(spacing: 10) {
                        Artwork(url: track.album.artwork, size: 42, radius: 6).matchedTransitionSource(id: "nowPlaying", in: namespace)
                        VStack(alignment: .leading, spacing: 3) { Text(track.title).font(.subheadline.weight(.medium)).lineLimit(1); Text(track.artistName).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(MusicPressStyle()).accessibilityIdentifier("miniPlayer").accessibilityLabel("打开播放器，\(track.title)")
                IconButton(symbol: store.player.snapshot.offersPause ? "pause.fill" : "play.fill", label: store.player.snapshot.offersPause ? "暂停" : "继续播放") { store.player.toggle() }
                IconButton(symbol: "forward.end.fill", label: "下一首", size: 17) { store.player.next() }.disabled(store.player.restorationPending)
            }.padding(.horizontal, native ? 12 : 8).padding(.vertical, 8)
                .background {
                    if !native { RoundedRectangle(cornerRadius: 17).fill(reduceTransparency ? AnyShapeStyle(Palette.surface) : AnyShapeStyle(.regularMaterial)) }
                }
                .overlay(alignment: .bottom) { MiniProgress().padding(.horizontal, 18) }.foregroundStyle(Palette.text)
        }
    }
}
private struct MiniProgress: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        GeometryReader { g in Capsule().fill(Palette.accent.opacity(0.45)).frame(width: g.size.width * min(1, store.player.position / max(1, store.player.duration)), height: 2) }.frame(height: 2).accessibilityHidden(true)
    }
}
