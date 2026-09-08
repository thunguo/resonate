import AppIntents
struct ListeningShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueListeningIntent(), phrases: ["用\(.applicationName)继续听歌", "继续播放\(.applicationName)"], shortTitle: "继续听", systemImageName: "play.fill")
        AppShortcut(intent: PlayFavoritePlaylistIntent(), phrases: ["用\(.applicationName)播放歌单"], shortTitle: "播放歌单", systemImageName: "music.note.list")
    }
}
