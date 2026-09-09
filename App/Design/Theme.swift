import SwiftUI
import MusicCore

enum Motion {
    static let press = 0.12
    static let state = 0.18
    static let lyrics = 0.22
    static let player = 0.28
    static let atmosphere = 0.5
    static let reduced = 0.1
}
enum Layout {
    static let page: CGFloat = 20
    static let panelRadius: CGFloat = 14
    static let touch: CGFloat = 44
}
enum Palette {
    static let background = adaptive(0xF5F5F2, 0x111213)
    static let text = adaptive(0x20211F, 0xF4F4EF)
    static let secondary = adaptive(0x62655E, 0xA8ABA4)
    static let accent = adaptive(0x4C5943, 0xCAD1BE)
    static let surface = adaptive(0xE9EBE5, 0x20221F)
    static let line = adaptive(0xD9DCD4, 0x343730)
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
    var radius: CGFloat = 8
    @Environment(\.displayScale) private var scale
    @State private var loaded: UIImage?
    @State private var loadedURL: URL?
    private var pixels: Int { ArtworkMemory.size(Int(max(1, size) * scale)) }
    private var image: UIImage? {
        guard let url else { return nil }
        return ArtworkMemory.shared.image(url, pixels: pixels) ?? (loadedURL == url ? loaded : nil) ?? ArtworkMemory.shared.image(url, pixels: 160)
    }
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Rectangle().fill(Palette.surface).overlay { Image(systemName: "music.note").font(.system(size: max(14, size * 0.19), weight: .ultraLight)).foregroundStyle(Palette.secondary.opacity(0.5)) } }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: radius)).accessibilityHidden(true)
            .onDisappear { loaded = nil; loadedURL = nil }
            .task(id: "\(url?.absoluteString ?? "")-\(pixels)") {
                guard let url else { return }
                do {
                    let image = try await ArtworkStore.shared.image(url, pixels: pixels)
                    try Task.checkCancellation(); loadedURL = url; loaded = image
                } catch { }
            }
    }
}
struct ArtworkAtmosphere: View {
    let url: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    @State private var tint: UIColor?
    var body: some View {
        Palette.background.overlay {
            if let tint, !reduceTransparency, contrast != .increased {
                LinearGradient(colors: [Color(tint).opacity(scheme == .dark ? 0.14 : 0.06), Color(tint).opacity(0.025), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.allowsHitTesting(false).task(id: url) {
            guard let url else { tint = nil; return }
            let color = await ArtworkStore.shared.tint(url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: reduceMotion ? Motion.reduced : Motion.atmosphere)) { tint = color }
        }
    }
}
struct MusicPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(!isEnabled ? 0.42 : configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .animation(.easeOut(duration: Motion.press), value: configuration.isPressed)
    }
}
struct DelayedProgress: View {
    var title = "正在读取…"
    @State private var visible = false
    @State private var slow = false
    var body: some View {
        Group {
            if visible { VStack(spacing: 12) { ProgressView(title); if slow { Text("比平时慢一些，可以稍后再试。").font(.footnote).foregroundStyle(Palette.secondary) } }.frame(maxWidth: .infinity).padding(.vertical, 20) }
        }.task {
            do { try await Task.sleep(for: .milliseconds(300)); visible = true; try await Task.sleep(for: .seconds(8)); slow = true } catch { }
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
    var feedback = false
    var action: () -> Void
    var body: some View { Button { if feedback { UISelectionFeedbackGenerator().selectionChanged() }; action() } label: { Image(systemName: symbol).font(.system(size: size, weight: .regular)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.buttonStyle(MusicPressStyle()).foregroundStyle(Palette.text).accessibilityLabel(label) }
}
struct FilledButton: View {
    let title: String
    var symbol: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) { HStack(spacing: 8) { if let symbol { Image(systemName: symbol) }; Text(title).fontWeight(.medium) }.frame(maxWidth: .infinity).frame(minHeight: 50).foregroundStyle(Palette.background).background(Palette.accent, in: RoundedRectangle(cornerRadius: Layout.panelRadius)) }
            .buttonStyle(MusicPressStyle())
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
    var audition = false
    @State private var addToPlaylist = false
    var body: some View {
        HStack(spacing: 12) {
            Button { if let play { play() } else { store.player.play([track], origin: .search) } } label: {
                HStack(spacing: 12) {
                    if let index { Text(String(index)).font(.subheadline.monospacedDigit()).foregroundStyle(Palette.secondary).frame(width: 24) }
                    Artwork(url: track.album.artwork, size: 50)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) { Text(track.title).foregroundStyle(Palette.text).lineLimit(2); if store.player.currentTrackID == track.id { Image(systemName: "waveform").font(.caption).foregroundStyle(Palette.accent) } }
                        Text(subtitle ?? track.artistName).font(.subheadline).foregroundStyle(Palette.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if track.availability == .preview { Text("试听").font(.caption2).foregroundStyle(Palette.secondary) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(audition ? "试听" : "播放") \(track.title)，\(track.artistName)")
            Menu {
                Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") { store.player.enqueue([track], next: true); store.notify("已设为下一首") }
                Button("加入队列", systemImage: "text.append") { store.player.enqueue([track]); store.notify("已加入队列") }
                Button(store.likedIDs.contains(track.id) ? "取消喜欢" : "喜欢", systemImage: store.likedIDs.contains(track.id) ? "heart.slash" : "heart") { Task { await store.toggleLike(track) } }
                Button("加入歌单", systemImage: "plus") { if store.requireLogin() { addToPlaylist = true } }
                if store.downloads.isAuthorized { Button("下载", systemImage: "arrow.down.circle") { do { try store.downloads.enqueue(track); store.notify("已加入下载") } catch { store.report(error) } } }
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
