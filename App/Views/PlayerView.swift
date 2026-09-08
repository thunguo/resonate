import SwiftUI
import AVKit
import MusicCore

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.tintColor = UIColor(Palette.text); view.activeTintColor = UIColor(Palette.accent); view.prioritizesVideoDevices = false; return view }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { uiView.tintColor = UIColor(Palette.text) }
}
struct PlayerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var showExplanation = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var downloadMessage: String?
    @State private var artworkTint: UIColor?
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    if let track = store.player.current {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack { IconButton(symbol: "chevron.down", label: "收起播放器") { dismiss() }.accessibilityIdentifier("closePlayer"); Spacer(); Eyebrow(text: store.player.isPreview ? "正在试听" : "正在播放"); Spacer(); moreMenu(track) }
                            Artwork(url: track.album.artwork, size: min(geometry.size.width - 48, min(340, max(200, geometry.size.height * 0.37))), radius: 9).frame(maxWidth: .infinity).padding(.top, 4).shadow(color: .black.opacity(0.08), radius: 20, x: 0, y: 12)
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(track.title).accessibilityIdentifier("playerTrackTitle").font(.title.weight(.medium)).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                                    IconButton(symbol: store.likedIDs.contains(track.id) ? "heart.fill" : "heart", label: store.likedIDs.contains(track.id) ? "取消喜欢" : "喜欢", size: 23) { Task { await store.toggleLike(track) } }
                                }
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 10) { artistLink(track); Text("·").foregroundStyle(Palette.secondary).accessibilityHidden(true); albumLink(track) }
                                    VStack(alignment: .leading, spacing: 4) { artistLink(track); albumLink(track) }
                                }
                            }
                            timeline
                            controls
                            HStack {
                                IconButton(symbol: "quote.bubble", label: "歌词", size: 23) { showLyrics = true }.accessibilityIdentifier("lyricsButton")
                                Spacer(); AirPlayButton().frame(width: 48, height: 44).accessibilityLabel("选择音频输出设备"); Spacer()
                                IconButton(symbol: "text.line.first.and.arrowtriangle.forward", label: "播放队列", size: 23) { showQueue = true }.accessibilityIdentifier("queueButton")
                            }.padding(.horizontal, 16)
                            if let error = store.player.error { InlineError(message: error) { store.player.resume() } }
                            if let downloadMessage { Text(downloadMessage).font(.footnote).foregroundStyle(Palette.secondary) }
                            Button { showExplanation = true } label: { HStack { VStack(alignment: .leading, spacing: 6) { Text("关于这首歌").font(.subheadline.weight(.medium)); Text("听见更多，也了解更多").font(.caption).foregroundStyle(Palette.secondary) }; Spacer(); Image(systemName: "arrow.up.right").font(.subheadline) }.padding(.vertical, 18).padding(.horizontal, 18).background(Palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain)
                        }.padding(.horizontal, 24).padding(.bottom, 32).frame(width: geometry.size.width)
                    }
                }.scrollIndicators(.hidden).background {
                    Palette.background
                    if let artworkTint, contrast != .increased { LinearGradient(colors: [Color(artworkTint).opacity(0.05), .clear], startPoint: .top, endPoint: .bottom).allowsHitTesting(false) }
                }
                .task(id: store.player.current?.album.artwork) {
                    artworkTint = nil
                    if let url = store.player.current?.album.artwork { let tint = await ArtworkStore.shared.tint(url); if !Task.isCancelled { artworkTint = tint } }
                }
            }.cabinetBackground().toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showLyrics) { LyricsView() }
                .sheet(isPresented: $showQueue) { QueueView() }
                .sheet(isPresented: $showExplanation) { if let track = store.player.current { ExplanationView(track: track) } }
                .sheet(isPresented: Binding(get: { store.showLogin && !showLyrics && !showQueue && !showExplanation }, set: { store.showLogin = $0 })) { LoginView() }
        }
    }
    @ViewBuilder private func artistLink(_ track: Track) -> some View {
        if let artist = track.artists.first { NavigationLink { CollectionDetailView(artist: artist) } label: { Text(track.artistName).font(.title3).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain) }
    }
    private func albumLink(_ track: Track) -> some View {
        NavigationLink { CollectionDetailView(album: track.album) } label: { Text(track.album.name).font(.subheadline).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
    private var timeline: some View {
        VStack(spacing: 5) {
            Slider(value: Binding(get: { scrubbing ? scrubValue : min(store.player.position, max(1, store.player.duration)) }, set: { scrubValue = $0 }), in: 0...max(1, store.player.duration), onEditingChanged: { editing in
                if editing { scrubValue = store.player.position }; scrubbing = editing
                if !editing { store.player.seek(scrubValue) }
            }).tint(Palette.accent).accessibilityLabel("播放进度")
            HStack { Text(timeLabel(scrubbing ? scrubValue : store.player.position)); Spacer();
                if store.player.isBuffering { Text("缓冲中…") }
                else if store.player.isPreview { Text("试听片段") }
                else if let quality = store.player.resource?.quality { Text(quality.isEmpty ? "音质信息暂不可用" : AudioQuality(rawValue: quality)?.label ?? quality) }
                Spacer(); Text("−" + timeLabel(max(0, store.player.duration - (scrubbing ? scrubValue : store.player.position))))
                    .accessibilityIdentifier("remainingTime")
                    .accessibilityLabel("剩余 " + timeLabel(max(0, store.player.duration - (scrubbing ? scrubValue : store.player.position))))
            }.font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(Palette.text)
        }
    }
    private var controls: some View {
        HStack(spacing: 0) {
            Button { store.player.queue.shuffle.toggle(); store.player.save() } label: { Image(systemName: "shuffle").font(.system(size: 18)).foregroundStyle(store.player.queue.shuffle ? Palette.accent : Palette.secondary).frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityIdentifier("shuffleButton").accessibilityLabel(store.player.queue.shuffle ? "关闭随机播放" : "开启随机播放")
            Spacer(minLength: 8)
            IconButton(symbol: "backward.end.fill", label: "上一首", size: 27) { store.player.previous() }
            Spacer(minLength: 8)
            Button { store.player.toggle() } label: { Image(systemName: store.player.isPlaying || store.player.isBuffering ? "pause.fill" : "play.fill").font(.system(size: 31)).frame(width: 72, height: 72).foregroundStyle(Palette.background).background(Palette.accent, in: Circle()) }.buttonStyle(.plain).accessibilityLabel(store.player.isPlaying ? "暂停" : "播放").accessibilityIdentifier("mainPlayPause").accessibilityValue(store.player.isPlaying ? "播放中" : store.player.isBuffering ? "缓冲中" : "已暂停")
            Spacer(minLength: 8)
            IconButton(symbol: "forward.end.fill", label: "下一首", size: 27) { store.player.next() }
            Spacer(minLength: 8)
            Button { let modes = RepeatMode.allCases; let i = modes.firstIndex(of: store.player.queue.repeatMode)!; store.player.queue.repeatMode = modes[(i + 1) % modes.count]; store.player.save() } label: { Image(systemName: store.player.queue.repeatMode == .one ? "repeat.1" : "repeat").font(.system(size: 18)).foregroundStyle(store.player.queue.repeatMode == .off ? Palette.secondary : Palette.accent).frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityIdentifier("repeatButton").accessibilityLabel(store.player.queue.repeatMode.label)
        }
    }
    private func moreMenu(_ track: Track) -> some View {
        Menu {
            Menu("播放音质") { ForEach(AudioQuality.allCases, id: \.self) { quality in Button(quality.label) { store.preferences.quality = quality; store.savePreferences() } } }
            Button("下载歌曲", systemImage: "arrow.down.circle") { do { try store.downloads.enqueue(track); downloadMessage = "已加入下载队列" } catch { downloadMessage = error.localizedDescription } }
            Menu("定时停止") { ForEach([15, 30, 45, 60], id: \.self) { minutes in Button("\(minutes) 分钟后") { store.player.setSleepTimer(minutes: minutes) } }; Button("关闭定时停止") { store.player.setSleepTimer(minutes: nil) } }
            if let date = store.player.sleepDate { Text("将在 \(date.formatted(date: .omitted, time: .shortened)) 停止") }
            ShareLink(item: track.webURL) { Label("分享歌曲", systemImage: "square.and.arrow.up") }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("播放器更多操作")
    }
}
struct LyricsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lines: [LyricLine] = []
    @State private var loading = true
    @State private var following = true
    @State private var error: String?
    @State private var loadToken = UUID()
    private var lyricTime: Double { store.player.position + (store.player.resource?.previewStart ?? 0) }
    private var active: Int? { LyricsParser.activeIndex(lines, time: lyricTime) }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if loading { ProgressView().frame(maxWidth: .infinity).padding(40) }
                        if let error { InlineError(message: error) { Task { await load() } } }
                        if !loading && lines.isEmpty && error == nil { EmptyState(symbol: "quote.bubble", title: "让旋律说话", detail: "这首歌暂时没有可用歌词。") }
                        ForEach(lines) { line in
                            Button {
                                if let start = line.start { store.player.seek(max(0, start - (store.player.resource?.previewStart ?? 0))); following = true }
                            } label: { lyricText(line).font(.title2.weight(line.id == active ? .semibold : .regular)).multilineTextAlignment(.leading).lineSpacing(8).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).frame(minHeight: 44).contentShape(Rectangle()) }
                                .buttonStyle(.plain).disabled(line.start == nil).id(line.id)
                        }
                    }.padding(.horizontal, 28).padding(.vertical, 70)
                }.simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in following = false })
                    .onChange(of: active) { _, value in guard following, let value else { return }; withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { proxy.scrollTo(value, anchor: .center) } }
                    .safeAreaInset(edge: .bottom) {
                        if !following { Button("回到当前") { following = true; if let active { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { proxy.scrollTo(active, anchor: .center) } } }.padding(.horizontal, 20).frame(minHeight: 44).background(.regularMaterial, in: Capsule()).padding() }
                    }
            }.cabinetBackground().navigationTitle("歌词").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task(id: store.player.current?.id) { following = true; await load() }
        }
    }
    private func lyricText(_ line: LyricLine) -> Text {
        guard line.id == active, !line.words.isEmpty else { return Text(line.text).foregroundColor(line.id == active ? Palette.text : Palette.secondary) }
        return line.words.reduce(Text("")) { text, word in text + Text(word.text).foregroundColor(lyricTime >= word.start ? Palette.text : Palette.secondary) }
    }
    private func load() async {
        guard let id = store.player.current?.id else { return }; loading = true; error = nil; lines = []
        let token = UUID(); loadToken = token
        defer { if loadToken == token { loading = false } }
        do { let result = try await store.lyricLines(id); try Task.checkCancellation(); guard id == store.player.current?.id, loadToken == token else { return }; lines = result } catch is CancellationError { } catch { if loadToken == token { self.error = error.localizedDescription } }
    }
}
struct QueueView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var arrangement = false
    var body: some View {
        @Bindable var player = store.player
        NavigationStack {
            List {
                if let track = player.current { Section("正在播放") { HStack(spacing: 14) { Artwork(url: track.album.artwork, size: 48); VStack(alignment: .leading, spacing: 6) { Text(track.title); Text(track.artistName).font(.caption).foregroundStyle(Palette.secondary) }; Spacer(); Image(systemName: "waveform").foregroundStyle(Palette.accent) }.listRowBackground(Palette.surface) } }
                Section {
                    ForEach(player.queue.upcoming) { entry in
                        HStack(spacing: 12) {
                            Button { player.jump(entry.id) } label: { VStack(alignment: .leading, spacing: 6) { Text(entry.track.title).foregroundStyle(Palette.text); Text(entry.track.artistName).font(.caption).foregroundStyle(Palette.secondary) }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 48) }.buttonStyle(.plain)
                            if entry.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Palette.accent).accessibilityLabel("已固定") }
                        }.listRowBackground(Palette.background)
                    }.onDelete { offsets in let upcoming = player.queue.upcoming; for i in offsets { player.queue.remove(upcoming[i].id) }; player.save() }
                        .onMove { from, to in player.queue.moveUpcoming(from: from, to: to); player.save() }
                } header: { Text("接下来 · \(player.queue.upcoming.count) 首") } footer: { Text("手动加入或移动的歌曲会固定，AI 调整时保留这些位置。") }
                Section {
                    Toggle("队列结束后自动续播", isOn: $player.queue.autoplay).onChange(of: player.queue.autoplay) { _, _ in player.save() }
                    Button("调整接下来想听的音乐", systemImage: "slider.horizontal.3") { arrangement = true }
                    if player.previousQueue != nil { Button("撤销上次队列更改", systemImage: "arrow.uturn.backward") { player.undo() } }
                }.listRowBackground(Palette.background)
            }.cabinetList().navigationTitle("播放队列").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { EditButton() }; ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: $arrangement) { ArrangementView(initialPrompt: "保持正在播放的歌，调整接下来的音乐", adjustingQueue: true) }
                .sheet(isPresented: Binding(get: { store.showLogin && !arrangement }, set: { store.showLogin = $0 })) { LoginView() }
        }
    }
}
