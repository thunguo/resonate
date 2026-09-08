import SwiftUI
import MusicCore

enum Palette {
    static let background = adaptive(0xF6F3ED, 0x171816)
    static let text = adaptive(0x22211F, 0xF0EDE6)
    static let secondary = adaptive(0x5B574F, 0xAAA69D)
    static let accent = adaptive(0x625D46, 0xC9BE9D)
    static let surface = adaptive(0xEDE9E0, 0x242521)
    static let line = adaptive(0xDBD6CC, 0x373932)
    static func adaptive(_ light: UInt, _ dark: UInt) -> Color {
        Color(UIColor { trait in UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light) })
    }
}
extension UIColor {
    convenience init(hex: UInt) { self.init(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
}
struct Artwork: View {
    let url: URL?
    var size: CGFloat = 52
    var radius: CGFloat = 6
    @State private var loaded: UIImage?
    var body: some View {
        Group {
            if let loaded { Image(uiImage: loaded).resizable().scaledToFit() }
            else { ZStack { Palette.surface; Image(systemName: "music.note").font(.system(size: max(18, size * 0.22), weight: .ultraLight)).foregroundStyle(Palette.accent.opacity(0.6)) } }
        }.frame(width: size, height: size).background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius)).accessibilityHidden(true)
            .task(id: url) {
                loaded = nil
                guard let url else { return }
                do { let image = try await ArtworkStore.shared.image(url); try Task.checkCancellation(); loaded = image } catch { }
            }
    }
}
struct Eyebrow: View {
    let text: String
    var body: some View { Text(text).font(.caption).tracking(1.6).foregroundStyle(Palette.secondary) }
}
struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.title3.weight(.semibold)).foregroundStyle(Palette.text); if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Palette.secondary) } }.frame(maxWidth: .infinity, alignment: .leading) }
}
struct IconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 20
    var action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: symbol).font(.system(size: size, weight: .regular)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Palette.text).accessibilityLabel(label) }
}
struct FilledButton: View {
    let title: String
    var symbol: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) { HStack(spacing: 8) { if let symbol { Image(systemName: symbol) }; Text(title).fontWeight(.medium) }.frame(maxWidth: .infinity).frame(minHeight: 50) }
            .buttonStyle(.plain).foregroundStyle(Palette.background).background(Palette.accent, in: RoundedRectangle(cornerRadius: 14))
    }
}
struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) { Image(systemName: symbol).font(.system(size: 36, weight: .ultraLight)).foregroundStyle(Palette.accent); Text(title).font(.title3.weight(.medium)); Text(detail).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).lineSpacing(4) }.frame(maxWidth: .infinity).padding(.vertical, 36).padding(.horizontal, 24)
    }
}
struct InlineError: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { Text(message).font(.subheadline).foregroundStyle(Palette.secondary); if let retry { Button("重试", action: retry).frame(minHeight: 44) } }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
struct TrackRow: View {
    @Environment(AppStore.self) private var store
    let track: Track
    var index: Int? = nil
    var subtitle: String? = nil
    var play: (() -> Void)? = nil
    @State private var addToPlaylist = false
    var body: some View {
        HStack(spacing: 12) {
            Button { if let play { play() } else { store.player.play([track], origin: .search) } } label: {
                HStack(spacing: 12) {
                    if let index { Text(String(index)).font(.subheadline.monospacedDigit()).foregroundStyle(Palette.secondary).frame(width: 24) }
                    Artwork(url: track.album.artwork, size: 50)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) { Text(track.title).foregroundStyle(Palette.text).lineLimit(2); if store.player.current?.id == track.id { Image(systemName: "waveform").font(.caption).foregroundStyle(Palette.accent) } }
                        Text(subtitle ?? track.artistName).font(.subheadline).foregroundStyle(Palette.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if track.availability == .preview { Text("试听").font(.caption2).foregroundStyle(Palette.secondary) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("播放 \(track.title)，\(track.artistName)")
            Menu {
                Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") { store.player.enqueue([track], next: true); store.notify("已设为下一首") }
                Button("加入队列", systemImage: "text.append") { store.player.enqueue([track]); store.notify("已加入队列") }
                Button(store.likedIDs.contains(track.id) ? "取消喜欢" : "喜欢", systemImage: store.likedIDs.contains(track.id) ? "heart.slash" : "heart") { Task { await store.toggleLike(track) } }
                Button("加入歌单", systemImage: "plus") { if store.requireLogin() { addToPlaylist = true } }
                Button("下载", systemImage: "arrow.down.circle") { do { try store.downloads.enqueue(track); store.notify("已加入下载") } catch { store.report(error) } }
                ShareLink(item: track.webURL) { Label("分享歌曲", systemImage: "square.and.arrow.up") }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(Palette.secondary) }.accessibilityLabel("\(track.title)的更多操作")
        }.padding(.vertical, 7)
        .sheet(isPresented: $addToPlaylist) { PlaylistPicker(tracks: [track]) }
    }
}
extension View {
    func cabinetBackground() -> some View { self.background(Palette.background).foregroundStyle(Palette.text).tint(Palette.accent) }
    func cabinetList() -> some View { self.scrollContentBackground(.hidden).background(Palette.background).listStyle(.plain).tint(Palette.accent) }
}
