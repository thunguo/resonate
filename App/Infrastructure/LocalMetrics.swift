import Foundation

struct LocalMetrics: Codable {
    var playbackAttempts = 0
    var playbackStarts = 0
    var playbackStartSeconds: Double = 0
    var aiGenerations = 0
    var aiApplications = 0
    var aiSaves = 0
    var collectionReplays = 0
}
extension AppStore {
    func recordPlaybackAttempt() { metrics.playbackAttempts += 1; saveMetrics() }
    func recordPlaybackStart(seconds: Double) { metrics.playbackStarts += 1; metrics.playbackStartSeconds += seconds; saveMetrics() }
    func recordAIGeneration() { metrics.aiGenerations += 1; saveMetrics() }
    func recordAIApplication() { metrics.aiApplications += 1; saveMetrics() }
    func recordAISave() { metrics.aiSaves += 1; saveMetrics() }
    func recordCollectionReplay() { metrics.collectionReplays += 1; saveMetrics() }
    func clearMetrics() { metrics = .init(); saveMetrics() }
    private func saveMetrics() { do { try persistence.save(metrics, key: accountKey("metrics")) } catch { report(error) } }
}
