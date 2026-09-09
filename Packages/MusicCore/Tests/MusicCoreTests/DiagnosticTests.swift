import Testing
import Foundation
@testable import MusicCore

@Test func diagnosticRecordsExpireAndRemainWithinByteBudget() async throws {
    let recorder = DiagnosticRecorder(retention: 60, maxBytes: 1024)
    await recorder.append(.init(date: .now.addingTimeInterval(-120), event: .startup, milliseconds: 10))
    for _ in 0..<20 { await recorder.append(.init(event: .imageDecode, milliseconds: 1)) }
    let records = await recorder.snapshot()
    #expect(records.count == 4)
    #expect(records.allSatisfy { $0.event == .imageDecode })
    #expect(try JSONEncoder().encode(records).count <= 1024)
    try await recorder.clear(); #expect(await recorder.snapshot().isEmpty)
}
@Test func diagnosticsRejectNonFiniteDurationAndPersistOnlyWhitelist() async throws {
    let record = DiagnosticRecord(event: .localSearch, milliseconds: .infinity)
    #expect(record.milliseconds == 0)
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    #expect(Set(object.keys) == ["date", "event", "outcome", "milliseconds"])
}
