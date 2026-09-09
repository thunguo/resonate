import SwiftUI
import MusicCore

struct ArrangementView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let initialPrompt: String
    var adjustingQueue = false
    @State private var prompt = ""
    @State private var editingPrompt = false
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
    @State private var resultAccountID: UUID?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if arrangement == nil || editingPrompt {
                        VStack(alignment: .leading, spacing: 10) { Text("换一种听法").font(.title.weight(.semibold)); Text("从收藏里，为此刻选一段音乐。").font(.subheadline).foregroundStyle(Palette.secondary) }
                        TextField("例如：收藏里适合夜晚散步的歌，四十分钟", text: $prompt, axis: .vertical).lineLimit(3...6).padding(18).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("arrangementPrompt")
                        if store.activeProviderName == nil {
                            Button("连接模型服务") { settings = true }.frame(minHeight: 44)
                        } else {
                            FilledButton(title: progress == nil ? "编排一段音乐" : "取消本次生成", symbol: progress == nil ? "slider.horizontal.3" : "xmark") { if progress == nil { generate() } else { cancel() } }.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Text("使用 \(store.activeProviderName ?? "") · 生成前会检查歌曲播放资格").font(.caption).foregroundStyle(Palette.secondary)
                        }
                    }
                    if progress != nil && arrangement != nil && !editingPrompt { Button("取消本次生成") { cancel() }.frame(minHeight: 44) }
                    if let progress { HStack(spacing: 12) { ProgressView(); Text(progress).font(.subheadline).foregroundStyle(Palette.secondary) }.padding(.vertical, 12) }
                    if let error { InlineError(message: error) }
                    if let arrangement { result(arrangement) }
                    else if progress == nil { suggestions }
                }.padding(24)
            }.cabinetBackground()
                .safeAreaInset(edge: .bottom) {
                    if store.player.isAuditioning {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) { Text("试听中").font(.caption).foregroundStyle(Palette.secondary); Text(store.player.current?.title ?? "").font(.subheadline).lineLimit(1) }
                            Spacer()
                            Button("结束试听") { store.player.endAudition() }.frame(minHeight: 44).accessibilityIdentifier("endAudition")
                        }.padding(.horizontal, 24).padding(.vertical, 8).background(.regularMaterial)
                    }
                }.navigationTitle(arrangement == nil ? "" : "音乐编排").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { if arrangement != nil { Button(editingPrompt ? "收起需求" : "修改需求") { editingPrompt.toggle() } } }; ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: $creationSheet, onDismiss: { createUncertain = store.pendingCreation != nil }) {
                    PlaylistCreationView { playlist in createdPlaylist = playlist; createUncertain = false; persistResultSave() }
                }
                .sheet(isPresented: $settings) { NavigationStack { AISettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } } } }
                .sheet(isPresented: Binding(get: { store.showLogin && !settings }, set: { store.showLogin = $0 })) { LoginView() }
        }.onAppear {
            guard !restored else { return }; restored = true; prompt = initialPrompt; resultAccountID = store.accountGeneration
            if let saved = store.recentArrangements.first(where: { adjustingQueue ? $0.queueSignature == store.player.queue.arrangementSignature : $0.queueSignature == nil }) {
                arrangement = saved; self.saved = saved.saveConfirmed == true; createdPlaylist = saved.savedPlaylist; createUncertain = saved.creationUncertain == true
                if prompt.isEmpty { prompt = saved.intent.constraints }
            }
        }.onChange(of: store.accountGeneration) { _, _ in cancel(); arrangement = nil; saved = false; createdPlaylist = nil; dismiss() }
        .onDisappear { cancel(); store.player.endAudition() }.interactiveDismissDisabled(saving)
    }
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "从一个小念头开始")
            ForEach(["重听旧收藏，穿插几首新的", "想听四十分钟轻松的纯音乐", "用熟悉的歌，陪我慢慢走回家"], id: \.self) { text in Button { prompt = text } label: { HStack { Text(text).font(.subheadline); Spacer(); Image(systemName: "arrow.up.left").font(.caption) }.padding(.vertical, 12) }.buttonStyle(.plain) }
        }.padding(.top, 12)
    }
    private func result(_ result: Arrangement) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) { ForEach(Array(result.displayedTracks.prefix(4).enumerated()), id: \.offset) { _, track in Artwork(url: track.album.artwork, size: 112, radius: 10) } }
            }.padding(.vertical, 8)
            SectionHeading(title: result.title, subtitle: "\(result.displayedTracks.count) 首 · \(timeLabel(result.remainingDuration)) · \(result.displayedTracks.filter { result.likedIDs.contains($0.id) }.count) 首收藏")
            Text("本次需求：" + result.intent.constraints).font(.footnote).foregroundStyle(Palette.secondary)
            Text(result.intent.allowDiscovery ? "以收藏为主，新歌最多 \(Int(result.intent.discoveryFraction * 100))%" : "只听收藏").font(.footnote).foregroundStyle(Palette.secondary)
            if result.queueSignature != nil { Text("预计时长包含正在播放的剩余部分和手动固定的歌曲。").font(.caption).foregroundStyle(Palette.secondary) }
            ForEach(result.notes ?? [], id: \.self) { Text($0).font(.footnote).foregroundStyle(Palette.secondary) }
            Text(result.explanation).font(.subheadline).foregroundStyle(Palette.secondary).lineSpacing(4)
            HStack(spacing: 14) {
                FilledButton(title: adjustingQueue ? "应用到接下来" : "播放整组", symbol: "play.fill") { if adjustingQueue { guard store.player.apply(result) else { error = store.player.operationError; return } } else { store.player.play(result.tracks, origin: .ai) }; store.recordAIApplication(); if adjustingQueue { store.notify("队列已更新，可撤销") } }
                IconButton(symbol: "text.append", label: "加入队列") { store.player.enqueue(result.tracks); store.notify("已加入队列") }
            }
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { ForEach(["少些人声", "更熟悉", "换几首"], id: \.self) { adjustment in Button { if adjustment == "换几首" { excludedIDs.formUnion(result.tracks.suffix(min(3, result.tracks.count)).map(\.id)) }; prompt = String(prompt.prefix(1200)) + "；" + adjustment; generate() } label: { Text(adjustment).font(.subheadline).padding(.horizontal, 14).frame(minHeight: 44).background(Palette.surface, in: Capsule()) }.buttonStyle(.plain).disabled(progress != nil) } } }
            ForEach(Array(result.displayedTracks.enumerated()), id: \.offset) { index, track in
                TrackRow(track: track, subtitle: "试听 · " + rowLabel(result, index: index, track: track), play: { _ = store.player.beginAudition(track) }, audition: true)
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
        cancel(); error = nil
        let token = UUID(); generation = token
        let request = prompt; let accountID = store.accountGeneration
        let queue = store.player.restorableQueue
        let context = ArrangementContext(previous: arrangement, queue: adjustingQueue ? queue : nil, excludedIDs: excludedIDs)
        task = Task {
            do {
                let intelligence = try MusicIntelligence(music: store.music, provider: store.provider())
                progress = "开始编排…"
                let result = try await intelligence.arrange(request: request, library: store.library.likedTracks, discoveries: store.discoveries, preferences: store.preferences.musicTaste, context: context) { message in await MainActor.run { if generation == token && accountID == store.accountGeneration { progress = message } } }
                try Task.checkCancellation(); guard token == generation, accountID == store.accountGeneration else { return }; arrangement = result; saved = false; saveMessage = nil; createdPlaylist = nil; createUncertain = false; editingPrompt = false; store.saveArrangement(result, for: accountID); store.recordAIGeneration()
            } catch is CancellationError { } catch { if token == generation && accountID == store.accountGeneration { self.error = error.localizedDescription } }
            if token == generation { progress = nil }
        }
    }
    private func persistResultSave() {
        guard var result = arrangement, let resultAccountID, resultAccountID == store.accountGeneration else { return }
        result.savedPlaylist = createdPlaylist; result.saveConfirmed = saved; result.creationUncertain = createUncertain
        arrangement = result; store.saveArrangement(result, for: resultAccountID)
    }
    private func save(_ result: Arrangement) {
        guard store.requireLogin() else { return }; saving = true; let accountID = store.accountGeneration
        Task { defer { if store.accountGeneration == accountID { saving = false } }
            do {
                if createdPlaylist == nil { let playlist = try await store.createPlaylistNamed(result.title); guard store.accountGeneration == accountID else { return }; createdPlaylist = playlist; persistResultSave() }
                guard let playlist = createdPlaylist, store.accountGeneration == accountID else { return }
                try await store.music.editPlaylist(playlist.id, tracks: result.displayedTracks.map(\.id), adding: true)
                guard store.accountGeneration == accountID else { return }
                saved = true; persistResultSave(); store.recordAISave(); saveMessage = "已保存为私人歌单。"; await store.syncLibrary()
            } catch {
                guard store.accountGeneration == accountID else { return }
                createUncertain = createdPlaylist == nil; persistResultSave()
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
    @State private var draftResponse = ""
    @State private var draftQuestion = ""
    @State private var question = ""
    @State private var history: [ChatMessage] = []
    @State private var loadingSources = true
    @State private var related: [Track] = []
    @State private var explanationGeneration = UUID()
    @State private var explanationAccountID: UUID?
    @State private var generating = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var settings = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 16) { Artwork(url: track.album.artwork, size: 76); VStack(alignment: .leading, spacing: 8) { Text(track.title).font(.title3.weight(.medium)); Text(track.artistName).font(.subheadline).foregroundStyle(Palette.secondary) } }
                    if let error { InlineError(message: error) }
                    SectionHeading(title: "欣赏角度", subtitle: "AI 导读，资料与来源可展开查看；推断会单独标注")
                    if !response.isEmpty { Text(CitationValidator.attributedText(response, sources: sources)).font(.body).textSelection(.enabled).lineSpacing(7).frame(maxWidth: .infinity, alignment: .leading) }
                    if !draftResponse.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(generating ? "新的回答" : "未完成的回答").font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary)
                            if !draftQuestion.isEmpty { Text(draftQuestion).font(.subheadline).foregroundStyle(Palette.secondary) }
                            Text(CitationValidator.attributedText(draftResponse, sources: sources)).lineSpacing(7).textSelection(.enabled)
                        }.padding(18).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if !generating && !draftQuestion.isEmpty { Button("重试这个问题") { explain(draftQuestion) }.frame(minHeight: 44) }
                    if generating { HStack { ProgressView(); Text("正在写一段导读…").font(.subheadline).foregroundStyle(Palette.secondary); Spacer(); Button("取消") { task?.cancel(); error = "导读未完成，已保留收到的内容。"; generating = false; saveCurrentExplanation() } }.frame(minHeight: 44) }
                    else if response.isEmpty {
                        FilledButton(title: "读一段音乐导读", symbol: "text.alignleft") { explain("请介绍这首歌。事实仅限资料；资料不足时说明，并给出不依赖音频分析的欣赏角度。") }.disabled(loadingSources)
                    }
                    if !response.isEmpty {
                        HStack { TextField("围绕这首歌继续问", text: $question, axis: .vertical).lineLimit(1...4); IconButton(symbol: "arrow.up.circle", label: "发送问题", size: 24) { explain(question) }.disabled(question.isEmpty || generating) }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if (try? store.provider(explanation: true)) == nil { Button("连接模型服务") { settings = true }.frame(minHeight: 44) }
                    DisclosureGroup("资料与来源") {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("\(track.album.name) · \(timeLabel(track.duration))").font(.subheadline).foregroundStyle(Palette.secondary)
                            if loadingSources { DelayedProgress(title: "读取来源…") }
                            ForEach(sources) { source in DisclosureGroup(source.title) { VStack(alignment: .leading, spacing: 12) { Text(source.text).font(.subheadline).lineSpacing(5); Link("查看来源", destination: source.url) }.padding(.vertical, 12) } }
                        }.padding(.vertical, 12)
                    }
                    SectionHeading(title: "继续探索")
                    ForEach(related.prefix(4)) { item in TrackRow(track: item, subtitle: "网易云相似歌曲 · " + item.artistName) }
                    NavigationLink { CollectionDetailView(album: track.album) } label: { Label(track.album.name, systemImage: "square.stack").frame(minHeight: 44) }
                    ForEach(track.artists) { artist in NavigationLink { CollectionDetailView(artist: artist) } label: { Label(artist.name, systemImage: "person.crop.circle").frame(minHeight: 44) } }
                }.padding(24)
            }.cabinetBackground().navigationTitle("关于这首歌").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: $settings) { NavigationStack { AISettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } } } }
                .task {
                    explanationAccountID = store.accountGeneration
                    if let saved = store.explanationRecord(track.id) { response = saved.text; sources = saved.sources; history = saved.history; error = saved.validationMessage; draftResponse = saved.draftText ?? ""; draftQuestion = saved.draftQuestion ?? ""; question = draftQuestion }
                    else { do { for try await value in store.sourceUpdates(track) { sources = value; loadingSources = false } } catch { self.error = error.localizedDescription } }
                    loadingSources = false
                    do { for try await items in store.repository.updates([Track].self, key: store.accountKey("cache.similar.\(track.id)"), lifetime: Freshness.metadata, fetch: { [music = store.music, track] in try await music.similarTracks(track.id) }) { related = items } } catch { }
                }
                .sheet(isPresented: Binding(get: { store.showLogin && !settings }, set: { store.showLogin = $0 })) { LoginView() }
        }.onChange(of: store.accountGeneration) { _, _ in task?.cancel(); explanationGeneration = UUID(); generating = false; response = ""; draftResponse = ""; sources = []; related = []; dismiss() }
        .onDisappear { if generating { error = "导读未完成，已保留收到的内容。" }; task?.cancel(); saveCurrentExplanation() }
    }
    private func saveCurrentExplanation() {
        guard (!response.isEmpty || !draftResponse.isEmpty || !draftQuestion.isEmpty), explanationAccountID == store.accountGeneration else { return }
        store.saveExplanation(.init(trackID: track.id, text: response, sources: sources, history: Array(history.suffix(12)), validationMessage: error, draftText: draftResponse.isEmpty ? nil : draftResponse, draftQuestion: draftQuestion.isEmpty ? nil : draftQuestion))
    }
    private func explain(_ prompt: String) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        task?.cancel(); error = nil; draftResponse = ""; draftQuestion = prompt; generating = true
        let oldResponse = response
        let token = UUID(); explanationGeneration = token; let accountID = store.accountGeneration
        task = Task {
            defer { if explanationGeneration == token { generating = false } }
            do {
                let intelligence = try MusicIntelligence(music: store.music, provider: store.provider(explanation: true))
                let text = try await intelligence.explain(track: track, question: prompt, sources: sources, previous: history) { text in await MainActor.run { if explanationGeneration == token && store.accountGeneration == accountID { draftResponse = text } } }
                try Task.checkCancellation(); guard explanationGeneration == token, store.accountGeneration == accountID else { return }; response = text; draftResponse = ""; draftQuestion = ""; history += [.init("user", prompt), .init("assistant", text)]; question = ""; saveCurrentExplanation()
            } catch is CancellationError { if explanationGeneration == token { response = oldResponse; saveCurrentExplanation() } }
            catch { guard explanationGeneration == token, store.accountGeneration == accountID else { return }; self.error = error.localizedDescription; if response.isEmpty { response = oldResponse }; saveCurrentExplanation() }
        }
    }
}
