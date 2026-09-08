#if DEBUG
import Foundation
import AVFoundation
import MusicCore

extension AppStore {
    func loadAdditionalPreviewFixtures() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--long-title"), !player.queue.entries.isEmpty {
            player.queue.entries[0].track.title = "在一个很长很长的夜晚，我们仍然想把这首歌慢慢听完"
        }
        if args.contains("--ai-result") {
            let tracks = library.likedTracks.map { track in var track = track; track.availability = .full; return track }
            if let result = try? ArrangementValidator.build(.init(title: "留一点时间，慢慢走", explanation: "这是用于界面验收的示例编排，未调用模型。", trackIDs: tracks.map(\.id)), candidates: tracks, likedIDs: Set(tracks.map(\.id)), intent: .init(durationMinutes: 30, allowDiscovery: false, constraints: "重听收藏，三十分钟")) { recentArrangements = [result] }
            showArrangement = true
        }
        guard args.contains("--audio-test") else { return }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("yuyin-ui-test.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
            buffer.frameLength = 24000; memset(buffer.floatChannelData![0], 0, 24000 * MemoryLayout<Float>.size)
            let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer)
            let tracks = (1...2).map { Track(id: Int64($0), title: "测试音频 \($0)", artists: [.init(id: 0, name: "本地无声测试")], album: .init(id: 0, name: "播放回归"), duration: 3, availability: .full) }
            player.offlineURL = { _ in url }
            var queue = QueueState(); queue.replace(tracks, origin: .album); player.restore(queue)
            if args.contains("--audio-paused") { player.play(tracks); player.pause() }
        } catch { report(error) }
    }
}
#endif
