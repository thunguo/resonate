import SwiftUI
import MusicCore

struct PlaylistCreationView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var allowRetry = false
    var onCreated: ((Playlist) -> Void)?
    var body: some View {
        NavigationStack {
            Form {
                Section("私人歌单") { TextField("歌单名称", text: $name).disabled(store.pendingCreation != nil).accessibilityIdentifier("playlistName") }
                if store.pendingCreation != nil {
                    Section {
                        Text("上次创建的结果尚未确认，先刷新核对，避免生成重复歌单。").font(.subheadline)
                        Button("已在网易云确认未创建，允许重试") { allowRetry = true }.disabled(store.isCreatingPlaylist)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(Palette.secondary) } }
                Section {
                    Button(store.isCreatingPlaylist ? "正在处理…" : store.pendingCreation == nil ? "创建私人歌单" : "刷新并核对创建结果") {
                        Task { do { let playlist = try await store.createPlaylistNamed(name); onCreated?(playlist); store.notify("歌单已保存到网易云"); dismiss() } catch { self.error = error.localizedDescription } }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isCreatingPlaylist)
                }
            }.scrollContentBackground(.hidden).cabinetBackground().navigationTitle("新建歌单")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }.onAppear { name = store.pendingCreation?.name ?? "" }.interactiveDismissDisabled(store.isCreatingPlaylist)
        .confirmationDialog("确认网易云中没有创建这张歌单？", isPresented: $allowRetry, titleVisibility: .visible) {
            Button("确认未创建，重新尝试") { store.clearPendingCreation(); error = nil }
        }
    }
}
