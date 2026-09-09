import Foundation
import MetricKit
import MusicCore

final class AppDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = AppDiagnostics()
    private var started = false
    func start() {
        guard !started else { return }; started = true
        let file = URL.applicationSupportDirectory.appendingPathComponent("Diagnostics/events.json")
        Task { await DiagnosticRecorder.shared.configure(file: file) }
        MXMetricManager.shared.add(self)
    }
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            if let cpu = payload.cpuMetrics?.cumulativeCPUTime {
                Task { await DiagnosticRecorder.shared.append(.init(event: .systemCPU, milliseconds: cpu.converted(to: .seconds).value * 1000)) }
            }
        }
    }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for hang in payload.hangDiagnostics ?? [] {
                Task { await DiagnosticRecorder.shared.append(.init(event: .systemHang, milliseconds: hang.hangDuration.converted(to: .seconds).value * 1000)) }
            }
            for _ in payload.crashDiagnostics ?? [] {
                Task { await DiagnosticRecorder.shared.append(.init(event: .systemCrash, outcome: .failed, milliseconds: 0)) }
            }
        }
    }
}
