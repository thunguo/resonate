import SwiftUI
import MusicCore

struct ArrangementRevision: Identifiable {
    let id = UUID()
    let original: Arrangement
    let proposed: Arrangement
    let selected: Set<Int64>
}
struct ArrangementRevisionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let revision: ArrangementRevision
    let adopt: () -> String?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SectionHeading(title: "只调整你选中的部分", subtitle: "替换 \(revision.selected.count) 首 · 其余歌曲与顺序保持")
                    Text("\(timeLabel(revision.original.remainingDuration)) → \(timeLabel(revision.proposed.remainingDuration))").font(.title3.monospacedDigit())
                    ForEach(Array(revision.original.displayedTracks.enumerated()), id: \.offset) { index, track in
                        if revision.selected.contains(track.id) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("第 \(index + 1) 首").font(.caption).foregroundStyle(Palette.secondary)
                                HStack(spacing: 12) { Artwork(url: track.album.artwork, size: 44); VStack(alignment: .leading, spacing: 4) { Text(track.title); Text("将被替换 · " + track.artistName).font(.caption).foregroundStyle(Palette.secondary) } }
                                let replacement = revision.proposed.displayedTracks[index]
                                Button { _ = store.player.beginAudition(replacement) } label: {
                                    HStack(spacing: 12) { Artwork(url: replacement.album.artwork, size: 56); VStack(alignment: .leading, spacing: 4) { Text(replacement.title).font(.headline); Text(replacement.artistName).font(.subheadline).foregroundStyle(Palette.secondary) }; Spacer(minLength: 8); Image(systemName: "play.circle").font(.title2) }.frame(minHeight: 56).contentShape(Rectangle())
                                }.buttonStyle(MusicPressStyle()).accessibilityLabel("试听替代歌曲 " + replacement.title)
                            }
                            Divider()
                        }
                    }
                    ForEach(revision.proposed.notes ?? [], id: \.self) { Text($0).font(.footnote).foregroundStyle(Palette.secondary) }
                    Text("采用后会保留为一份新的编排，原编排仍在本机。播放或应用到队列需另行操作。").font(.footnote).foregroundStyle(Palette.secondary)
                    if let error { InlineError(message: error) }
                }.padding(24)
            }.cabinetBackground().navigationTitle("替换预览").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        if store.player.isAuditioning { Button("结束试听") { store.player.endAudition() }.frame(minHeight: 44) }
                        FilledButton(title: "采用这次调整", symbol: "checkmark") { if let failure = adopt() { error = failure } else { dismiss() } }.accessibilityIdentifier("adoptRevision")
                    }.padding(.horizontal, 24).padding(.vertical, 12).background(.regularMaterial)
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("放弃") { dismiss() } } }
        }.onDisappear { store.player.endAudition() }
    }
}
