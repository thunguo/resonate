import XCTest
import AVFoundation
import MusicCore
@testable import Yuyin

@MainActor final class PlaybackReliabilityTests: XCTestCase {
    private var audioURL: URL!
    override func setUpWithError() throws {
        audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80000)!
        buffer.frameLength = 80000
        memset(buffer.floatChannelData![0], 0, 80000 * MemoryLayout<Float>.size)
        try AVAudioFile(forWriting: audioURL, settings: format.settings).write(from: buffer)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: audioURL) }
    private func controller() -> PlaybackController {
        let controller = PlaybackController(music: MusicService())
        let url = audioURL!; controller.offlineURL = { _ in url }; return controller
    }
    private func track(_ id: Int64) -> Track { .init(id: id, title: "音频测试", artists: [], album: .init(id: 0, name: ""), duration: 10) }
    private func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<200 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(25)) }; return predicate()
    }
    func testRapidSkipThenPauseKeepsLastIntent() async {
        let p = controller(); defer { p.clear() }
        p.play([track(1), track(2), track(3), track(4)])
        p.next(); p.next(); p.previous(); p.next(); p.pause()
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(p.current?.id, 3); XCTAssertEqual(p.snapshot.phase, .paused); XCTAssertFalse(p.isPlaying)
    }
    func testPreparationInterruptedDoesNotStartUntilInterruptionEnds() async {
        let p = controller(); defer { p.clear() }
        p.play([track(1)])
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(p.snapshot.phase, .interrupted); XCTAssertFalse(p.isPlaying)
        p.pause()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue, AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(p.snapshot.phase, .paused); XCTAssertFalse(p.isPlaying)
    }
    func testSeekDuringPreparationPreservesLatestTargetAndPause() async {
        let p = controller(); defer { p.clear() }
        p.play([track(1)]); p.seek(2); p.seek(6); p.pause()
        let reached = await wait { abs(p.position - 6) < 0.15 && p.snapshot.phase == .paused }
        XCTAssertTrue(reached)
        p.resume()
        let started = await wait { p.isPlaying && p.position >= 5.9 }
        XCTAssertTrue(started)
    }
    func testEmptyResumeDoesNotShowPreparingAndResetDoesNotResumePause() async {
        let p = controller(); defer { p.clear() }
        p.resume(); XCTAssertEqual(p.snapshot.phase, .idle)
        p.play([track(1)]); p.pause()
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(p.snapshot.phase, .paused); XCTAssertEqual(p.current?.id, 1)
    }
}

extension PlaybackReliabilityTests {
    func testAuditionRestoresPausedQueueAndDoesNotPersistAudition() async {
        let p = controller(); defer { p.clear() }
        var original = QueueState(); original.replace([track(1), track(2)], origin: .album); original.position = 4
        p.restore(original)
        var saved: [QueueState] = []; p.onSave = { saved.append($0) }
        XCTAssertTrue(p.beginAudition(track(3)))
        let playing = await wait { p.isPlaying }; XCTAssertTrue(playing)
        p.endAudition()
        XCTAssertEqual(p.queue, original); XCTAssertEqual(p.position, 4); XCTAssertFalse(p.isPlaying)
        XCTAssertFalse(p.isAuditioning); XCTAssertTrue(saved.allSatisfy { !$0.entries.contains { $0.track.id == 3 } })
    }
    func testAuditionEndResumesOriginalPlayingIntentAndExplicitPlayDiscardsReturn() async {
        let p = controller(); defer { p.clear() }
        p.play([track(1), track(2)])
        let playing = await wait { p.isPlaying }; XCTAssertTrue(playing)
        p.seek(3); let sought = await wait { p.position >= 3 }; XCTAssertTrue(sought)
        let originalIDs = p.queue.entries.map(\.id)
        p.beginAudition(track(3)); p.seek(9.8)
        let restored = await wait { !p.isAuditioning && p.current?.id == 1 && p.isPlaying }; XCTAssertTrue(restored)
        XCTAssertEqual(p.queue.entries.map(\.id), originalIDs); XCTAssertGreaterThanOrEqual(p.position, 3)
        p.beginAudition(track(3)); p.play([track(4)])
        p.endAudition(); XCTAssertEqual(p.current?.id, 4); XCTAssertFalse(p.isAuditioning)
    }
    func testClearDuringAuditionCannotRestoreFormerAccountQueue() {
        let p = controller(); p.play([track(1)]); p.beginAudition(track(2)); p.clear(); p.endAudition()
        XCTAssertNil(p.current); XCTAssertFalse(p.isAuditioning); XCTAssertTrue(p.restorableQueue.entries.isEmpty)
    }
}

extension PlaybackReliabilityTests {
    func testStaleArrangementDoesNotStopAuditionOrChangePlaybackState() async throws {
        let p = controller(); defer { p.clear() }
        p.play([track(1), track(2)])
        let playing = await wait { p.isPlaying }; XCTAssertTrue(playing)
        var candidate = track(3); candidate.availability = .full
        var arrangement = try ArrangementValidator.build(.init(title: "测试", explanation: "", trackIDs: [3]), candidates: [candidate], likedIDs: [3], intent: .init(allowDiscovery: false))
        arrangement.queueSignature = "expired"
        p.beginAudition(track(4))
        let audition = await wait { p.isPlaying }; XCTAssertTrue(audition)
        XCTAssertFalse(p.apply(arrangement)); XCTAssertNotNil(p.operationError)
        XCTAssertTrue(p.isAuditioning); XCTAssertEqual(p.current?.id, 4); XCTAssertEqual(p.snapshot.phase, .playing)
        p.endAudition(); XCTAssertEqual(p.current?.id, 1)
    }
}
