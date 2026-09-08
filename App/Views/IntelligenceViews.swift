import SwiftUI
import MusicCore

struct ArrangementView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let initialPrompt: String
    var adjustingQueue = false
    @State private var prompt = ""
    @State private var arrangement: Arrangement?
    @State private var progress: String?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var createdPlaylist: Playlist?
    @State private var saving = false
    @State private var saved = false
    @State private var saveMessage: String?
    @State private var createUncertain = false
    @State private var creationSheet = false
    @State private var settings = false
    @State private var generation = UUID()
    @State private var excludedIDs = Set<Int64>()
    @State private var restored = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) { Eyebrow(text: "音乐，贴近此刻"); Text("换一种听法").font(.largeTitle.weight(.medium)); Text("说说想听什么，剩下的交给音乐。").font(.subheadline).foregroundStyle(Palette.secondary) }
                    TextField("例如：收藏里适合夜晚散步的歌，四十分钟", text: $prompt, axis: .vertical).lineLimit(3...6).padding(18).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("arrangementPrompt")
                    if store.activeProviderName == nil {
                        VStack(alignment: .leading, spacing: 10) { Text("连接你选择的模型服务，开始编排。").font(.subheadline).foregroundStyle(Palette.secondary); Button("连接模型服务") { settings = true }.frame(minHeight: 44) }
                    } else {
                        FilledButton(title: progress == nil ? "编排一段音乐" : "取消本次生成", symbol: progress == nil ? "slider.horizontal.3" : "xmark") { if progress == nil { generate() } else { cancel() } }.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("使用 \(store.activeProviderName ?? "") · 生成前会检查歌曲播放资格").font(.caption).foregroundStyle(Palette.secondary)
                    }
                    if let progress { HStack(spacing: 12) { ProgressView(); Text(progress).font(.subheadline).foregroundStyle(Palette.secondary) }.padding(.vertical, 12) }
                    if let error { InlineError(message: error) }
                    if let arrangement { result(arrangement) }
                    else if progress == nil { suggestions }
                }.padding(24)
            }.cabinetBackground().navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: $creationSheet, onDismiss: { createUncertain = store.pendingCreation != nil }) {
                    PlaylistCreationView { playlist in createdPlaylist = playlist; createUncertain = false }
                }
                .sheet(isPresented: $settings) { NavigationStack { AISettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } } } }
                .sheet(isPresented: Binding(get: { store.showLogin && !settings }, set: { store.showLogin = $0 })) { LoginView() }
        }.onAppear {
            guard !restored else { return }; restored = true; prompt = initialPrompt
            if let saved = store.recentArrangements.first(where: { adjustingQueue ? $0.queueSignature == store.player.queue.arrangementSignature : $0.queueSignature == nil }) {
                arrangement = saved
                if prompt.isEmpty { prompt = saved.intent.constraints }
            }
        }.onDisappear { cancel() }.interactiveDismissDisabled(saving)
    }
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "从一个小念头开始")
            ForEach(["重听旧收藏，穿插几首新的", "想听四十分钟轻松的纯音乐", "用熟悉的歌，陪我慢慢走回家"], id: \.self) { text in Button { prompt = text } label: { HStack { Text(text).font(.subheadline); Spacer(); Image(systemName: "arrow.up.left").font(.caption) }.padding(.vertical, 12) }.buttonStyle(.plain) }
        }.padding(.top, 12)
    }
    private func result(_ result: Arrangement) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider().overlay(Palette.line)
            SectionHeading(title: result.title, subtitle: "\(result.displayedTracks.count) 首 · 约 \(Int(result.remainingDuration / 60)) 分钟 · \(result.displayedTracks.filter { result.likedIDs.contains($0.id) }.count) 首收藏")
            if result.queueSignature != nil { Text("预计时长包含正在播放的剩余部分和手动固定的歌曲。").font(.caption).foregroundStyle(Palette.secondary) }
            ForEach(result.notes ?? [], id: \.self) { Text($0).font(.footnote).foregroundStyle(Palette.secondary) }
            Text(result.explanation).font(.subheadline).foregroundStyle(Palette.secondary).lineSpacing(4)
            HStack(spacing: 14) {
                FilledButton(title: adjustingQueue ? "应用到接下来" : "播放", symbol: "play.fill") { if adjustingQueue { guard store.player.apply(result) else { error = store.player.error; return } } else { store.player.play(result.tracks, origin: .ai) }; store.recordAIApplication(); store.notify(adjustingQueue ? "队列已更新，可撤销" : "开始播放") }
                IconButton(symbol: "text.append", label: "加入队列") { store.player.enqueue(result.tracks); store.notify("已加入队列") }
            }
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { ForEach(["少些人声", "更熟悉", "换几首"], id: \.self) { adjustment in Button { if adjustment == "换几首" { excludedIDs.formUnion(result.tracks.suffix(min(3, result.tracks.count)).map(\.id)) }; prompt = String(prompt.prefix(1200)) + "；" + adjustment; generate() } label: { Text(adjustment).font(.subheadline).padding(.horizontal, 14).frame(minHeight: 44).background(Palette.surface, in: Capsule()) }.buttonStyle(.plain).disabled(progress != nil) } } }
            ForEach(Array(result.displayedTracks.enumerated()), id: \.offset) { index, track in
                TrackRow(track: track, subtitle: rowLabel(result, index: index, track: track)) { store.player.play([track], origin: .ai) }
            }
            Button(saved ? "已保存到网易云" : createdPlaylist != nil ? "重试添加到已创建的歌单" : "保存为私人歌单", systemImage: saved ? "checkmark" : "plus") { save(result) }.frame(minHeight: 44).disabled(saving || saved || progress != nil || createUncertain)
            if createUncertain { Button("核对歌单创建结果") { creationSheet = true }.frame(minHeight: 44) }
            if let saveMessage { Text(saveMessage).font(.footnote).foregroundStyle(Palette.secondary) }
            if store.player.previousQueue != nil { Button("撤销上次队列更改") { store.player.undo() }.font(.subheadline).frame(minHeight: 44) }
        }
    }
    private func rowLabel(_ result: Arrangement, index: Int, track: Track) -> String {
        if let entries = result.previewEntries, entries.indices.contains(index) {
            if index == 0 { return "保留当前 · " + track.artistName }
            if entries[index].pinned { return "手动固定 · " + track.artistName }
        }
        return (result.likedIDs.contains(track.id) ? "收藏 · " : "新发现 · ") + track.artistName
    }
    private func cancel() { generation = UUID(); task?.cancel(); progress = nil }
    private func generate() {
        guard !saving else { return }
        cancel(); error = nil; saved = false; saveMessage = nil; createdPlaylist = nil; createUncertain = false
        let token = UUID(); generation = token
        let request = prompt; let accountID = store.profile?.id
        var queue = store.player.queue; queue.position = store.player.position
        let context = ArrangementContext(previous: arrangement, queue: adjustingQueue ? queue : nil, excludedIDs: excludedIDs)
        task = Task {
            do {
                let intelligence = try MusicIntelligence(music: store.music, provider: store.provider())
                progress = "开始编排…"
                let result = try await intelligence.arrange(request: request, library: store.library.likedTracks, discoveries: store.discoveries, preferences: store.preferences.musicTaste, context: context) { message in await MainActor.run { if generation == token { progress = message } } }
                try Task.checkCancellation(); guard token == generation, accountID == store.profile?.id else { return }; arrangement = result; store.saveArrangement(result); store.recordAIGeneration()
            } catch is CancellationError { } catch { if token == generation { self.error = error.localizedDescription } }
            if token == generation { progress = nil }
        }
    }
    private func save(_ result: Arrangement) {
        guard store.requireLogin() else { return }; saving = true; let accountID = store.profile?.id
        Task { defer { saving = false }
            do {
                if createdPlaylist == nil { createdPlaylist = try await store.createPlaylistNamed(result.title) }
                guard let playlist = createdPlaylist, store.profile?.id == accountID else { return }
                try await store.music.editPlaylist(playlist.id, tracks: result.displayedTracks.map(\.id), adding: true)
                guard store.profile?.id == accountID else { return }
                saved = true; store.recordAISave(); saveMessage = "已保存为私人歌单。"; await store.syncLibrary()
            } catch {
                createUncertain = createdPlaylist == nil
                saveMessage = createdPlaylist == nil ? "创建结果未确认。请在音乐库核对上次创建的歌单，再重试保存。" : "歌单已创建，但歌曲添加未完成。重试会核对已有曲目。"
                self.error = error.localizedDescription
            }
        }
    }
}
struct ExplanationView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var sources: [MusicSource] = []
    @State private var response = ""
    @State private var question = ""
    @State private var history: [ChatMessage] = []
    @State private var loadingSources = true
    @State private var related: [Track] = []
    @State private var explanationGeneration = UUID()
    @State private var explanationAccountID: Int64?
    @State private var generating = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var settings = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 16) { Artwork(url: track.album.artwork, size: 76); VStack(alignment: .leading, spacing: 8) { Text(track.title).font(.title3.weight(.medium)); Text(track.artistName).font(.subheadline).foregroundStyle(Palette.secondary) } }
                    SectionHeading(title: "音乐资料")
                    Text("\(track.album.name) · \(timeLabel(track.duration))").font(.subheadline).foregroundStyle(Palette.secondary)
                    if loadingSources { ProgressView("读取来源…") }
                    ForEach(sources) { source in DisclosureGroup(source.title) { VStack(alignment: .leading, spacing: 12) { Text(source.text).font(.subheadline).lineSpacing(5); Link("查看来源", destination: source.url).font(.subheadline) }.padding(.vertical, 12) } }
                    if let error { InlineError(message: error) }
                    SectionHeading(title: "欣赏角度", subtitle: "AI 导读，基于上方资料；推断会单独标注")
                    if !response.isEmpty { Text(CitationValidator.attributedText(response, sources: sources)).font(.body).textSelection(.enabled).lineSpacing(7).frame(maxWidth: .infinity, alignment: .leading) }
                    if generating { HStack { ProgressView(); Text("正在写一段导读…").font(.subheadline).foregroundStyle(Palette.secondary); Spacer(); Button("取消") { explanationGeneration = UUID(); task?.cancel(); error = "导读未完成，已保留收到的内容。"; generating = false; saveCurrentExplanation() } }.frame(minHeight: 44) }
                    else if response.isEmpty {
                        FilledButton(title: "读一段音乐导读", symbol: "text.alignleft") { explain("请介绍这首歌。事实仅限资料；资料不足时说明，并给出不依赖音频分析的欣赏角度。") }.disabled(loadingSources)
                    }
                    if !response.isEmpty {
                        HStack { TextField("围绕这首歌继续问", text: $question, axis: .vertical).lineLimit(1...4); IconButton(symbol: "arrow.up.circle", label: "发送问题", size: 24) { explain(question) }.disabled(question.isEmpty || generating) }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if (try? store.provider(explanation: true)) == nil { Button("连接模型服务") { settings = true }.frame(minHeight: 44) }
                    SectionHeading(title: "继续探索")
                    ForEach(related.prefix(4)) { item in TrackRow(track: item, subtitle: "网易云相似歌曲 · " + item.artistName) }
                    NavigationLink { CollectionDetailView(album: track.album) } label: { Label(track.album.name, systemImage: "square.stack").frame(minHeight: 44) }
                    ForEach(track.artists) { artist in NavigationLink { CollectionDetailView(artist: artist) } label: { Label(artist.name, systemImage: "person.crop.circle").frame(minHeight: 44) } }
                }.padding(24)
            }.cabinetBackground().navigationTitle("关于这首歌").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: $settings) { NavigationStack { AISettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } } } }
                .task {
                    explanationAccountID = store.profile?.id
                    if let saved = store.explanationRecord(track.id) { response = saved.text; sources = saved.sources; history = saved.history; error = saved.validationMessage }
                    else { do { sources = try await store.musicSources(track) } catch { self.error = error.localizedDescription } }
                    loadingSources = false
                    related = (try? await store.music.similarTracks(track.id)) ?? []
                }
                .sheet(isPresented: Binding(get: { store.showLogin && !settings }, set: { store.showLogin = $0 })) { LoginView() }
        }.onDisappear { if generating { error = "导读未完成，已保留收到的内容。" }; explanationGeneration = UUID(); task?.cancel(); saveCurrentExplanation() }
    }
    private func saveCurrentExplanation() {
        guard !response.isEmpty, explanationAccountID == store.profile?.id else { return }
        store.saveExplanation(.init(trackID: track.id, text: response, sources: sources, history: Array(history.suffix(12)), validationMessage: error))
    }
    private func explain(_ prompt: String) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        task?.cancel(); error = nil; generating = true
        let oldResponse = response
        let token = UUID(); explanationGeneration = token; let accountID = store.profile?.id
        task = Task {
            defer { if explanationGeneration == token { generating = false } }
            do {
                let intelligence = try MusicIntelligence(music: store.music, provider: store.provider(explanation: true))
                let text = try await intelligence.explain(track: track, question: prompt, sources: sources, previous: history) { text in await MainActor.run { if explanationGeneration == token && store.profile?.id == accountID { response = text } } }
                try Task.checkCancellation(); guard explanationGeneration == token, store.profile?.id == accountID else { return }; history += [.init("user", prompt), .init("assistant", text)]; question = ""; saveCurrentExplanation()
            } catch is CancellationError { if explanationGeneration == token && response.isEmpty { response = oldResponse } }
            catch { guard explanationGeneration == token, store.profile?.id == accountID else { return }; self.error = error.localizedDescription; if response.isEmpty { response = oldResponse }; saveCurrentExplanation() }
        }
    }
}
