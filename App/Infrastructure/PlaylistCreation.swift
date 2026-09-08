import Foundation
import MusicCore

struct PlaylistCreationAttempt: Codable {
    var accountID: Int64
    var name: String
    var previousIDs: Set<Int64>
    var submittedAt = Date()
}

extension AppStore {
    func createPlaylistNamed(_ proposed: String) async throws -> Playlist {
        guard let profile else { throw MusicError.loginRequired }
        guard !isCreatingPlaylist else { throw MusicError.message("正在创建歌单，请稍候。") }
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw MusicError.message("歌单名需要 1 至 40 个字。") }
        isCreatingPlaylist = true; defer { isCreatingPlaylist = false }
        let accountID = profile.id
        let playlists = try await music.userPlaylists(accountID)
        guard self.profile?.id == accountID else { throw MusicError.staleSession }
        if let attempt = pendingCreation {
            guard attempt.accountID == accountID, attempt.name == name else { throw MusicError.message("还有一张歌单的创建结果未确认，请先在音乐库核对。") }
            let matches = playlists.filter { $0.creatorID == accountID && $0.name == name && !attempt.previousIDs.contains($0.id) }
            guard matches.count == 1, let created = matches.first else { throw MusicError.message(matches.isEmpty ? "刷新后仍未找到新歌单。请在网易云核对，确认没有创建后再允许重试。" : "找到了多张同名新歌单，请在音乐库核对后再继续。") }
            clearPendingCreation(); await syncLibrary(); return created
        }
        let attempt = PlaylistCreationAttempt(accountID: accountID, name: name, previousIDs: Set(playlists.map(\.id)))
        try persistence.save(attempt, key: "account.\(accountID).pendingCreation")
        pendingCreation = attempt
        let created = try await music.createPlaylist(name: name)
        guard self.profile?.id == accountID else { throw MusicError.staleSession }
        clearPendingCreation()
        library.playlists.removeAll { $0.id == created.id }; library.playlists.insert(created, at: 0)
        do { try persistence.save(library, key: "account.\(accountID).library") } catch { report(error) }
        return created
    }
    func clearPendingCreation() {
        guard let profile else { return }
        do { try persistence.remove(prefix: "account.\(profile.id).pendingCreation"); pendingCreation = nil } catch { report(error) }
    }
}
