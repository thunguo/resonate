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
