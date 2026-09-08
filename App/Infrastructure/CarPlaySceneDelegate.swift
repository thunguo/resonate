import CarPlay
import MusicCore
import UIKit

@MainActor final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CPInterfaceController?
    private var libraryObserver: NSObjectProtocol?
    private var favoritesTemplate: CPListTemplate?
    private var recentTemplate: CPListTemplate?
    private var playlistsTemplate: CPListTemplate?
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        controller = interfaceController
        rebuild()
        libraryObserver = NotificationCenter.default.addObserver(forName: Notification.Name("YuyinLibraryDidChange"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshContents() }
        }
    }
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
        libraryObserver = nil; controller = nil; favoritesTemplate = nil; recentTemplate = nil; playlistsTemplate = nil
    }
    private func rebuild() {
        guard let store = AppStore.shared else { return }
        let favorites = trackList("喜欢", tracks: store.library.likedTracks)
        favorites.tabImage = UIImage(systemName: "heart")
        let recent = trackList("最近", tracks: store.history.recent)
        recent.tabImage = UIImage(systemName: "clock")
        let playlists = CPListTemplate(title: "歌单", sections: playlistSections(store))
        playlists.tabImage = UIImage(systemName: "music.note.list")
        favoritesTemplate = favorites; recentTemplate = recent; playlistsTemplate = playlists
        let tabs = CPTabBarTemplate(templates: [favorites, recent, playlists])
        controller?.setRootTemplate(tabs, animated: false, completion: nil)
    }
    private func refreshContents() {
        guard let store = AppStore.shared else { return }
        favoritesTemplate?.updateSections(trackList("喜欢", tracks: store.library.likedTracks).sections)
        recentTemplate?.updateSections(trackList("最近", tracks: store.history.recent).sections)
        playlistsTemplate?.updateSections(playlistSections(store))
    }
    private func playlistSections(_ store: AppStore) -> [CPListSection] {
        let accountID = store.profile?.id
        let items = store.library.playlists.prefix(100).map { playlist in
            let item = CPListItem(text: playlist.name, detailText: "\(playlist.count) 首")
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    defer { completion() }
                    do { let tracks = try await store.playlistTracks(playlist.id); guard let self, store.profile?.id == accountID else { return }; self.controller?.pushTemplate(self.trackList(playlist.name, tracks: tracks), animated: true, completion: nil) }
                    catch { self?.showError(error.localizedDescription) }
                }
            }
            return item
        }
        return [CPListSection(items: items)]
    }
    private func trackList(_ title: String, tracks: [Track]) -> CPListTemplate {
        let accountID = AppStore.shared?.profile?.id
        let items = tracks.prefix(100).enumerated().map { index, track in
            let item = CPListItem(text: track.title, detailText: track.artistName)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    guard AppStore.shared?.profile?.id == accountID else { completion(); return }
                    AppStore.shared?.player.play(tracks, at: index)
                    self?.controller?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                    completion()
                }
            }
            return item
        }
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        template.emptyViewTitleVariants = ["还没有音乐"]
        template.emptyViewSubtitleVariants = ["请先在 iPhone 上登录并同步收藏。"]
        return template
    }
    private func showError(_ message: String) {
        let alert = CPAlertTemplate(titleVariants: [message], actions: [CPAlertAction(title: "知道了", style: .default) { [weak self] _ in self?.controller?.dismissTemplate(animated: true, completion: nil) }])
        controller?.presentTemplate(alert, animated: true, completion: nil)
    }
}
