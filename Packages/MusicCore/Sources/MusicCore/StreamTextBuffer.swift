import Foundation

actor StreamTextBuffer {
    private let receive: @Sendable (String) async -> Void
    private var latest = ""
    private var delivered = ""
    private var timer: Task<Void, Never>?
    private var closed = false
    init(receive: @escaping @Sendable (String) async -> Void) { self.receive = receive }
    func submit(_ text: String) {
        guard !closed, text != latest else { return }; latest = text
        guard timer == nil else { return }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)); await self?.flush() } catch { }
        }
    }
    func finish() async { closed = true; timer?.cancel(); timer = nil; await flush() }
    private func flush() async {
        timer = nil
        guard latest != delivered else { return }
        delivered = latest; await receive(delivered)
    }
}
