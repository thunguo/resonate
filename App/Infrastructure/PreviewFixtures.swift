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
            arrangementToOpen = recentArrangements.first; showArrangement = true
        }
        if args.contains("--editing-test") {
            let config = AIProviderConfig(kind: .custom, name: "自定义服务", baseURL: "https://example.com", model: "fixture")
            configurations = [config]; arrangementProviderID = config.id
            if var result = recentArrangements.first {
                result.tracks = Array(result.tracks.prefix(4)); result.notes = nil
                recentArrangements = [result]; arrangementToOpen = result
                try? persistence.save(recentArrangements, key: accountKey("ai.arrangements"))
            }
        }
        if args.contains("--collection-test") {
            let tracks = library.likedTracks.map { track in var track = track; track.availability = .full; return track }
            history.recent = tracks
            for (index, track) in tracks.enumerated() { history.lastPlayed[track.id] = Calendar.current.startOfDay(for: .now).addingTimeInterval(index < 3 ? 3600 : index < 6 ? -3600 : -7 * 86400) }
            recentArrangements = ["夜晚，慢慢走", "安静的午后", "熟悉的旋律"].enumerated().compactMap { index, title in
                guard var result = try? ArrangementValidator.build(.init(title: title, explanation: "从熟悉的旋律开始，留一段不赶时间的音乐。", trackIDs: tracks.map(\.id)), candidates: tracks, likedIDs: Set(tracks.map(\.id)), intent: .init(durationMinutes: 30, allowDiscovery: false, constraints: index == 1 ? "午后休息，重听熟悉的音乐" : "收藏里的歌，陪我散步三十分钟")) else { return nil }
                result.createdAt = Date().addingTimeInterval(Double(-index * 86400)); result.originalPrompt = result.intent.constraints; result.isKept = index == 1
                return result
            }
            try? persistence.save(recentArrangements, key: accountKey("ai.arrangements"))
        }
        guard args.contains("--audio-test") else { return }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("yuyin-ui-test.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let frames: AVAudioFrameCount = args.contains("--collection-test") ? 240000 : args.contains("--ai-result") ? 80000 : 24000
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames; memset(buffer.floatChannelData![0], 0, Int(frames) * MemoryLayout<Float>.size)
            let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer)
            let tracks = (1...2).map { Track(id: Int64($0), title: "测试音频 \($0)", artists: [.init(id: 0, name: "本地无声测试")], album: .init(id: 0, name: "播放回归"), duration: args.contains("--collection-test") ? 30 : 3, availability: .full) }
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

#if DEBUG
actor ArrangementPreviewTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data("{}".utf8))
        var payload: JSONValue = .object(["code": .number(200)])
        var status = 200
        if request.url?.path.contains("song/url") == true {
            payload = .object(["code": .number(200), "data": .array(json["id"].string.split(separator: ",").map { .object(["id": .number(Double($0) ?? 0), "url": .string("https://example.com/audio.mp3"), "code": .number(200)]) })])
        } else if request.url?.path.contains("chat/completions") == true {
            let args = ProcessInfo.processInfo.arguments
            try await Task.sleep(for: .milliseconds(args.contains("--editing-slow") ? 10000 : 350))
            if args.contains("--editing-failure") { status = 429 }
            let system = json["messages"].array.first?["content"].string ?? ""
            let text = json["messages"].array.last?["content"].string ?? ""
            let candidates = text.components(separatedBy: "候选：").last?.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?.array ?? []
            let content: JSONValue
            if system.contains("解析器") { content = .object(["durationMinutes": .number(30), "allowDiscovery": .bool(true), "discoveryFraction": .number(0.2), "queries": .array([]), "constraints": .string("沿着这首听，三十分钟")]) }
            else if system.contains("编排编辑") {
                let slots = text.components(separatedBy: "所选：").last?.components(separatedBy: "\n候选：").first?.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?.array ?? []
                content = .object(["replacements": .array(zip(slots, candidates).map { .object(["originalID": .number(Double($0["id"].string) ?? 0), "replacementID": .number(Double($1["id"].string) ?? 0)]) })])
            } else { content = .object(["title": .string("沿着熟悉的旋律"), "explanation": .string("从收藏与歌曲之间已有的关联继续探索。"), "trackIDs": .array(candidates.map { .number(Double($0["id"].string) ?? 0) })]) }
            payload = .object(["choices": .array([.object(["message": .object(["content": .string(String(decoding: try JSONEncoder().encode(content), as: UTF8.self))]), "finish_reason": .string("stop")])])])
        }
        return (try JSONEncoder().encode(payload), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
#endif
