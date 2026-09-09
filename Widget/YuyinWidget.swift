import SwiftUI
import WidgetKit
import AppIntents

struct ListeningEntry: TimelineEntry { let date: Date; let snapshot: WidgetSnapshot }
struct ListeningTimeline: TimelineProvider {
    func placeholder(in context: Context) -> ListeningEntry { .init(date: .now, snapshot: .init()) }
    func getSnapshot(in context: Context, completion: @escaping (ListeningEntry) -> Void) { completion(.init(date: .now, snapshot: SharedListening.read())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ListeningEntry>) -> Void) { completion(Timeline(entries: [.init(date: .now, snapshot: SharedListening.read())], policy: .after(Date().addingTimeInterval(900)))) }
}
struct ListeningWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ListeningEntry
    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("余音").font(.caption.weight(.medium)); Spacer(); Image(systemName: "waveform").font(.caption) }.foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(SharedListening.canSharePlayback ? entry.snapshot.title : "音乐在余音里等你").font(.headline).lineLimit(1)
                Text(SharedListening.canSharePlayback ? entry.snapshot.artist : "打开应用，从上次继续").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button(intent: ContinueListeningIntent()) { Label(SharedListening.canSharePlayback ? "继续听" : "打开应用继续听", systemImage: "play.fill").font(.subheadline.weight(.medium)).frame(minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.plain)
            }
            if SharedListening.canSharePlayback && family == .systemMedium && !entry.snapshot.playlists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("常听歌单").font(.caption).foregroundStyle(.secondary)
                    ForEach(entry.snapshot.playlists.prefix(2)) { playlist in Link(destination: URL(string: "yuyin://playlist?id=\(playlist.id)")!) { Text(playlist.name).font(.subheadline).lineLimit(2).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) } }
                }.frame(maxWidth: .infinity)
            }
        }.foregroundStyle(Color.primary).containerBackground(for: .widget) { Color(.systemBackground) }.widgetURL(URL(string: "yuyin://resume"))
    }
}
@main struct YuyinWidget: Widget {
    let kind = "YuyinListening"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ListeningTimeline()) { ListeningWidgetView(entry: $0) }
            .configurationDisplayName("继续听").description("一触继续播放，也能打开常听的歌单。").supportedFamilies([.systemSmall, .systemMedium])
    }
}
