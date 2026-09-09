#if DEBUG
import Foundation
import AVFoundation
import MusicCore

extension AppStore {
    func loadAdditionalPreviewFixtures() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--reading-test"), let current = player.current {
            let lyrics = LyricsParser.parse(yrc: nil, lrc: (0..<60).map { String(format: "[%02d:00.00]测试歌词 %d", $0, $0) }.joined(separator: "\n"))
            try? persistence.save(CachedValue(lyrics), key: accountKey("cache.lyrics.\(current.id)"))
            var tracks = (0..<60).map { index in var track = current; track.id = Int64(index + 1); track.title = "队列歌曲 \(index)"; return track }
            tracks[0] = current
            var queue = QueueState(); queue.replace(tracks, origin: .album); player.restore(queue)
        }
        if args.contains("--long-title"), !player.queue.entries.isEmpty {
            player.queue.entries[0].track.title = "在一个很长很长的夜晚，我们仍然想把这首歌慢慢听完"
        }
        if args.contains("--ai-result") {
            let tracks = library.likedTracks.map { track in var track = track; track.availability = .full; return track }
            if var result = try? ArrangementValidator.build(.init(title: "留一点时间，慢慢走", explanation: "从熟悉的旋律开始，留出一段不赶时间的路。", trackIDs: tracks.map(\.id)), candidates: tracks, likedIDs: Set(tracks.map(\.id)), intent: .init(durationMinutes: 30, allowDiscovery: false, constraints: "重听收藏，三十分钟")) { if args.contains("--saved-ai-result") { result.savedPlaylist = .init(id: 9, name: result.title); result.saveConfirmed = true }; recentArrangements = [result] }
            showArrangement = true
        }
        guard args.contains("--audio-test") else { return }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("yuyin-ui-test.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let frames: AVAudioFrameCount = args.contains("--ai-result") ? 80000 : 24000
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames; memset(buffer.floatChannelData![0], 0, Int(frames) * MemoryLayout<Float>.size)
            let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer)
            let tracks = (1...2).map { Track(id: Int64($0), title: "测试音频 \($0)", artists: [.init(id: 0, name: "本地无声测试")], album: .init(id: 0, name: "播放回归"), duration: 3, availability: .full) }
            player.offlineURL = { _ in url }
            var queue = QueueState(); queue.replace(tracks, origin: .album); player.restore(queue)
            if args.contains("--audio-paused") { player.play(tracks); player.pause() }
        } catch { report(error) }
    }
}
#endif

#if DEBUG
actor SearchPreviewTransport: HTTPTransport {
    private var failedPage = false
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
        let offset = body["offset"].int, kind = body["type"].int
        if offset == 30 && !failedPage {
            failedPage = true
            return (Data(#"{"code":503}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        let entries = (offset..<offset + 30).map { index in
            JSONValue.object(["id": .number(Double(index + 100)), "name": .string((kind == 10 ? "专辑" : "曲目") + String(index)), "dt": .number(180000), "ar": .array([.object(["id": .number(1), "name": .string("测试音乐人")])])])
        }
        let json = JSONValue.object(["code": .number(200), "result": .object([kind == 10 ? "albums" : "songs": .array(entries), kind == 10 ? "albumCount" : "songCount": .number(60)])])
        return (try JSONEncoder().encode(json), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
#endif
