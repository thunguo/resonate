import SwiftUI
import MusicCore

struct TrackSelectionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var title = "选择歌曲"
    let tracks: [Track]
    var allowsSearch = false
    var onSelection: ([Track]) -> Void
    @State private var query = ""
    @State private var selected = Set<Int64>()
    @State private var remote: [Track] = []
    @State private var chosen: [Int64: Track] = [:]
    @State private var error: String?
    private var candidates: [Track] {
        var seen = Set<Int64>()
        return (tracks.filter { query.isEmpty || ($0.title + $0.artistName).localizedCaseInsensitiveContains(query) } + remote).filter { seen.insert($0.id).inserted }
    }
    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).font(.footnote).foregroundStyle(Palette.secondary) }
                ForEach(candidates) { track in
                    Button {
                        if !selected.insert(track.id).inserted { selected.remove(track.id) }
                        chosen[track.id] = track
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Palette.accent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 6) { Text(track.title).foregroundStyle(Palette.text); Text(track.artistName).font(.caption).foregroundStyle(Palette.secondary) }
                            Spacer()
                        }.frame(minHeight: 44)
                    }.listRowBackground(Palette.background)
                }
            }.cabinetList().searchable(text: $query, prompt: allowsSearch ? "搜索收藏或网易云" : "查找歌曲").navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("完成（\(selected.count)）") { onSelection(selected.sorted().compactMap { chosen[$0] }); dismiss() }.disabled(selected.isEmpty) }
                }
                .task(id: query) {
                    remote = []; error = nil
                    guard allowsSearch, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    do { try await Task.sleep(for: .milliseconds(300)); let result = try await store.music.search(query); try Task.checkCancellation(); remote = result.tracks }
                    catch is CancellationError { } catch { self.error = error.localizedDescription }
                }
        }
    }
}

struct PlaylistTrackEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    let original: [Track]
    @State private var tracks: [Track] = []
    @State private var error: String?
    @State private var busy = false
    @State private var confirmSave = false
    @State private var selectingRemoval = false
    private var removed: [Track] { original.filter { originalTrack in !tracks.contains { $0.id == originalTrack.id } } }
    var body: some View {
        NavigationStack {
            List {
                Section { Text("拖动调整顺序，或移除歌曲。保存后同步到网易云。").font(.footnote).foregroundStyle(Palette.secondary) }.listRowBackground(Palette.background)
                if let error { Section { Text(error).foregroundStyle(Palette.secondary) }.listRowBackground(Palette.background) }
                Section {
                    ForEach(tracks) { track in VStack(alignment: .leading, spacing: 6) { Text(track.title); Text(track.artistName).font(.caption).foregroundStyle(Palette.secondary) }.frame(minHeight: 44).listRowBackground(Palette.background) }
                    .onMove { tracks.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { tracks.remove(atOffsets: $0) }
                }
            }.cabinetList().environment(\.editMode, .constant(.active)).navigationTitle("编辑歌单曲目")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) { Button(busy ? "同步中…" : "保存") { confirmSave = true }.disabled(busy || tracks.map(\.id) == original.map(\.id)) }
                    ToolbarItem(placement: .bottomBar) { Button("批量移除") { selectingRemoval = true }.disabled(busy || tracks.isEmpty) }
                }
                .disabled(busy)
        }.onAppear { tracks = original }
            .interactiveDismissDisabled(busy)
            .sheet(isPresented: $selectingRemoval) { TrackSelectionView(title: "选择要移除的歌曲", tracks: tracks) { selection in let ids = Set(selection.map(\.id)); tracks.removeAll { ids.contains($0.id) } } }
            .confirmationDialog("保存顺序并从歌单移除 \(removed.count) 首歌曲？", isPresented: $confirmSave, titleVisibility: .visible) { Button("同步到网易云") { save() } }
    }
    private func save() {
        guard let accountID = store.profile?.id else { store.showLogin = true; return }
        busy = true; error = nil
        let removed = removed
        Task {
            defer { busy = false }
            do {
                if !removed.isEmpty { try await store.music.editPlaylist(playlist.id, tracks: removed.map(\.id), adding: false) }
                guard store.profile?.id == accountID else { throw MusicError.staleSession }
                if !tracks.isEmpty {
                    let removedIDs = Set(removed.map(\.id))
                    try await store.music.reorderPlaylist(playlist.id, ids: tracks.map(\.id), expected: original.filter { !removedIDs.contains($0.id) }.map(\.id), userID: accountID)
                }
                guard store.profile?.id == accountID else { throw MusicError.staleSession }
                store.invalidatePlaylist(playlist.id); await store.syncLibrary(); store.notify("歌单已同步"); dismiss()
            } catch { self.error = error.localizedDescription; store.invalidatePlaylist(playlist.id) }
        }
    }
}
