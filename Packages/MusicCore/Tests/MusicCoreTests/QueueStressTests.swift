import Testing
import Foundation
@testable import MusicCore

private struct SeededRandom: RandomNumberGenerator {
    var seed: UInt64 = 0x59A7F013
    mutating func next() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }
}
private func stressTrack(_ id: Int64) -> Track { .init(id: id, title: "队列验证", artists: [], album: .init(id: 0, name: ""), duration: 180, availability: .full) }
@Test func oneThousandSeededQueueOperationsPreserveInvariants() {
    var random = SeededRandom(), queue = QueueState(), previous: QueueState?
    queue.replace((1...20).map { stressTrack(Int64($0)) }, origin: .album)
    for step in 0..<1000 {
        switch random.next() % 9 {
        case 0: _ = queue.advance(manual: true, using: &random)
        case 1: queue.previous()
        case 2: previous = queue; queue.append([stressTrack(Int64(step + 100))], next: true)
        case 3: if let item = queue.upcoming.randomElement(using: &random) { previous = queue; queue.remove(item.id) }
        case 4: if queue.upcoming.count > 1 { previous = queue; queue.moveUpcoming(from: IndexSet(integer: 0), to: queue.upcoming.count) }
        case 5: queue.shuffle.toggle()
        case 6: queue.repeatMode = RepeatMode.allCases[Int(random.next() % 3)]
        case 7:
            previous = queue
            let current = queue.currentID, position = queue.position
            let fixed = queue.upcoming.enumerated().filter { $0.element.pinned }
            queue.applyArrangement([stressTrack(Int64(step + 2000)), stressTrack(Int64(step + 3000))])
            #expect(queue.currentID == current); #expect(queue.position == position)
            for (index, item) in fixed { #expect(queue.upcoming.indices.contains(index)); if queue.upcoming.indices.contains(index) { #expect(queue.upcoming[index] == item) } }
        default: if let saved = previous { queue = saved; previous = nil }
        }
        let ids = Set(queue.entries.map(\.id))
        #expect(ids.count == queue.entries.count)
        #expect(queue.currentID.map { ids.contains($0) } ?? queue.entries.isEmpty)
        #expect(queue.shuffleVisited.isSubset(of: ids))
        #expect(Set(queue.navigationHistory).isSubset(of: ids))
        #expect(queue.position >= 0)
    }
}
@Test func insertedNextTrackTakesPriorityInShuffle() {
    var queue = QueueState(), random = SeededRandom()
    queue.replace((1...10).map { stressTrack(Int64($0)) }, origin: .playlist); queue.shuffle = true
    queue.append([stressTrack(100)], next: true)
    #expect(queue.advance(manual: true, using: &random)); #expect(queue.current?.track.id == 100)
}
