import SwiftUI
import MusicCore

struct RecentListeningView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var tracks: [Track] = []
    @State private var dates: [Int64: Date] = [:]
    @State private var anchor: Int64?
    @State private var clearing = false
    private var matches: [Track] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tracks.filter { query.isEmpty || ($0.title + " " + $0.artistName + " " + $0.album.name).localizedCaseInsensitiveContains(query) }
    }
    private var groups: [(day: Date?, tracks: [Track])] {
        var groups: [(day: Date?, tracks: [Track])] = []
        for track in matches {
            let day = dates[track.id].map { Calendar.current.startOfDay(for: $0) }
            if let index = groups.firstIndex(where: { $0.day == day }) { groups[index].tracks.append(track) }
            else { groups.append((day, [track])) }
        }
        return groups
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                CollectionSearchField(prompt: "在听过的歌曲中查找", text: $query, identifier: "historySearch", focus: $searchFocused)
                if tracks.isEmpty && store.isRestoringHistory { DelayedProgress(title: "正在恢复聆听记录…") }
                else if tracks.isEmpty {
                    EmptyState(symbol: "clock", title: "听过的歌，留在这里", detail: "开始听音乐后，最近听过的歌曲会保存在这台设备上。")
                } else if matches.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "没有找到这首歌", detail: "试试歌名、音乐人或专辑名称。")
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        LazyVStack(spacing: 0) {
                            ForEach(group.tracks) { track in
                                TrackRow(track: track, continuePlaying: {
                                    if let index = matches.firstIndex(where: { $0.id == track.id }) { store.player.play(Array(matches.dropFirst(index)), origin: .manual) }
                                }, removeFromHistory: {
                                    if store.removeHistoryTrack(track.id) {
                                        withAnimation(.easeOut(duration: reduceMotion ? Motion.reduced : Motion.state)) { tracks.removeAll { $0.id == track.id } }
                                    }
                                }, play: {
                                    searchFocused = false
                                    if !store.player.playNow(track) { store.notify(store.player.operationError ?? "请稍后重试") }
                                }).id(track.id)
                            }
                        }.scrollTargetLayout()
                    } header: { Text(dayTitle(group.day)).font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary).padding(.top, 4) }
                }
                if !tracks.isEmpty { Text("保留最近听过的 100 首歌曲，同一首只显示最近一次。记录仅在本机保存。").font(.footnote).foregroundStyle(Palette.secondary).padding(.top, 8) }
            }.scrollTargetLayout().padding(Layout.page)
        }.scrollPosition(id: $anchor, anchor: .top).scrollDismissesKeyboard(.interactively).cabinetBackground()
            .navigationTitle("最近听过").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Menu("聆听记录操作", systemImage: "ellipsis") { Button("清空聆听记录", systemImage: "trash", role: .destructive) { clearing = true }.disabled(store.history.recent.isEmpty || store.isRestoringHistory) } } }
            .confirmationDialog("清空这台设备上的聆听记录？", isPresented: $clearing, titleVisibility: .visible) {
                Button("清空聆听记录", role: .destructive) { if store.clearListeningHistory() { reload() } }
            } message: { Text("收藏、歌单和正在播放的队列会保留。") }
            .onAppear { reload() }
            .onChange(of: store.isRestoringHistory) { _, restoring in if !restoring { reload() } }
            .onChange(of: store.accountGeneration) { _, _ in tracks = []; dates = [:]; query = ""; anchor = nil }
            .refreshable { reload() }
    }
    private func reload() { tracks = store.history.recent; dates = store.history.lastPlayed }
    private func dayTitle(_ day: Date?) -> String {
        guard let day else { return "较早听过" }
        if Calendar.current.isDateInToday(day) { return "今天" }
        if Calendar.current.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.year().month().day())
    }
}

private struct ArrangementPresentation: Identifiable {
    let id = UUID()
    var result: Arrangement?
    var prompt: String = ""
}

struct ArrangementLibraryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var presentation: ArrangementPresentation?
    @State private var renaming: Arrangement?
    @State private var showRename = false
    @State private var name = ""
    @State private var deleting: Arrangement?
    @State private var showDelete = false
    @State private var anchor: UUID?
    private var matches: [Arrangement] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.recentArrangements.filter { query.isEmpty || ($0.title + " " + $0.intent.constraints).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                CollectionSearchField(prompt: "查找标题或听歌需求", text: $query, identifier: "arrangementSearch", focus: $searchFocused)
                if store.recentArrangements.isEmpty {
                    EmptyState(symbol: "rectangle.stack", title: "把一段好音乐留下来", detail: "编排过的音乐会出现在这里。保留喜欢的一份，下次打开就能重听。")
                    FilledButton(title: "新建编排", symbol: "plus") { presentation = .init() }
                } else if matches.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "没有找到这份编排", detail: "试试标题或当时的听歌需求。")
                }
                section("已保留", values: matches.filter { $0.isKept == true })
                section("最近编排", values: matches.filter { $0.isKept != true })
                if !store.recentArrangements.isEmpty {
                    Text("最近编排保留 10 份。选择“保留这份”后会一直留在本机；保存到网易云歌单需要单独操作。").font(.footnote).foregroundStyle(Palette.secondary)
                }
            }.scrollTargetLayout().padding(Layout.page)
        }.scrollPosition(id: $anchor, anchor: .top).scrollDismissesKeyboard(.interactively).cabinetBackground()
            .navigationTitle("我的编排").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("新建编排", systemImage: "plus") { presentation = .init() }.frame(minWidth: Layout.touch, minHeight: Layout.touch).accessibilityIdentifier("newArrangement") } }
            .sheet(item: $presentation) { item in ArrangementView(initialPrompt: item.prompt, existingArrangement: item.result) }
            .alert("修改本机编排名称", isPresented: $showRename, presenting: renaming) { item in
                TextField("编排名称", text: $name)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") { _ = store.renameArrangement(item.id, title: name); renaming = nil }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: { _ in Text("最多 40 个字。已保存的网易云歌单名称不会随之修改。") }
            .confirmationDialog("删除这份本机编排？", isPresented: $showDelete, titleVisibility: .visible, presenting: deleting) { item in
                Button("删除本机编排", role: .destructive) {
                    withAnimation(.easeOut(duration: reduceMotion ? Motion.reduced : Motion.state)) { _ = store.removeArrangement(item.id) }
                    deleting = nil
                }
            } message: { _ in Text("网易云歌单和正在播放的队列会保留。") }
            .onChange(of: store.accountGeneration) { _, _ in presentation = nil; renaming = nil; deleting = nil; showRename = false; showDelete = false; query = ""; anchor = nil }
    }
    @ViewBuilder private func section(_ title: String, values: [Arrangement]) -> some View {
        if !values.isEmpty {
            Section {
                ForEach(values) { value in
                    ArrangementLibraryRow(id: value.id, open: { presentation = .init(result: $0) }, rename: {
                        name = $0.title; renaming = $0; showRename = true
                    }, regenerate: { presentation = .init(prompt: $0.originalPrompt ?? $0.intent.constraints) }, delete: {
                        deleting = $0; showDelete = true
                    }).id(value.id)
                }
            } header: { Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary) }
        }
    }
}

private struct ArrangementLibraryRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let id: UUID
    var open: (Arrangement) -> Void
    var rename: (Arrangement) -> Void
    var regenerate: (Arrangement) -> Void
    var delete: (Arrangement) -> Void
    var body: some View {
        if let value = store.recentArrangements.first(where: { $0.id == id }) {
            HStack(spacing: 12) {
                Button { open(value) } label: {
                    Group {
                        if typeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 12) { ArrangementArtwork(tracks: value.displayedTracks); metadata(value) }
                        } else {
                            HStack(spacing: 14) { ArrangementArtwork(tracks: value.displayedTracks); metadata(value) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(MusicPressStyle()).accessibilityIdentifier("openArrangement-\(value.id)").accessibilityLabel("打开编排，\(value.title)")
                Menu {
                    Button("播放整组", systemImage: "play.fill") { store.player.play(value.displayedTracks, origin: .ai) }
                    Button("加入队列", systemImage: "text.append") { store.player.enqueue(value.displayedTracks); store.notify("已加入队列") }
                    Button(value.isKept == true ? "取消保留" : "保留这份", systemImage: value.isKept == true ? "bookmark.slash" : "bookmark") {
                        withAnimation(.easeOut(duration: reduceMotion ? Motion.reduced : Motion.state)) { _ = store.keepArrangement(value.id, kept: value.isKept != true) }
                    }
                    Button("修改名称", systemImage: "pencil") { rename(value) }
                    Button("照这个需求再选一组", systemImage: "arrow.clockwise") { regenerate(value) }
                    Button("删除本机编排", systemImage: "trash", role: .destructive) { delete(value) }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(Palette.secondary) }.accessibilityLabel("\(value.title)的编排操作").id("\(value.id)-\(value.isKept == true)-\(value.title)")
            }
        }
    }
    private func metadata(_ value: Arrangement) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value.title).font(.body.weight(.medium)).foregroundStyle(Palette.text).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            Text("\(value.displayedTracks.count) 首 · \(timeLabel(value.remainingDuration))").font(.subheadline).foregroundStyle(Palette.secondary)
            Text(value.intent.constraints).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
            if value.saveConfirmed == true { Label("已保存到网易云", systemImage: "checkmark").font(.caption).foregroundStyle(Palette.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ArrangementArtwork: View {
    let tracks: [Track]
    var body: some View {
        if tracks.count >= 4 {
            VStack(spacing: 2) {
                HStack(spacing: 2) { Artwork(url: tracks[0].album.artwork, size: 35, radius: 3); Artwork(url: tracks[1].album.artwork, size: 35, radius: 3) }
                HStack(spacing: 2) { Artwork(url: tracks[2].album.artwork, size: 35, radius: 3); Artwork(url: tracks[3].album.artwork, size: 35, radius: 3) }
            }.clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
        } else { Artwork(url: tracks.first?.album.artwork, size: 72) }
    }
}

private struct CollectionSearchField: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let prompt: String
    @Binding var text: String
    let identifier: String
    var focus: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
            TextField("", text: $text, prompt: Text(typeSize.isAccessibilitySize ? (identifier == "historySearch" ? "查找歌曲" : "查找编排") : prompt).foregroundStyle(Palette.secondary)).submitLabel(.search).focused(focus).onSubmit { focus.wrappedValue = false }.accessibilityIdentifier(identifier).frame(minHeight: 44)
            if !text.isEmpty { Button("清空搜索", systemImage: "xmark.circle.fill") { text = "" }.labelStyle(.iconOnly).frame(width: 44, height: 44) }
        }.padding(.horizontal, 12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct RediscoveryView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                Text("从久未重听的收藏中，选一小段音乐。").font(.subheadline).foregroundStyle(Palette.secondary)
                FilledButton(title: "重听这 \(store.rediscoveries.count) 首", symbol: "play.fill") { store.recordCollectionReplay(); store.player.play(store.rediscoveries) }.disabled(store.rediscoveries.isEmpty)
                ForEach(Array(store.rediscoveries.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track, subtitle: track.artistName + " · " + (track.reason ?? "来自你的收藏")) { store.player.play(store.rediscoveries, at: index) }
                }
            }.padding(Layout.page)
        }.cabinetBackground().navigationTitle("从收藏里听起").navigationBarTitleDisplayMode(.inline)
    }
}
