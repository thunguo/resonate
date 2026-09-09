import SwiftUI
import UIKit
import MusicCore

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionID, let store = AppStore.shared else { completionHandler(); return }
        store.downloads.backgroundCompletion = completionHandler
    }
}
@main struct YuyinApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: AppStore?
    @State private var startupError: String?
    @Environment(\.scenePhase) private var phase
    init() {
        let measurement = PerformanceInterval(.startup)
        defer { measurement.end() }
        #if DEBUG
        let preview = ProcessInfo.processInfo.arguments.contains("--preview")
        #else
        let preview = false
        #endif
        if !preview { AppDiagnostics.shared.start() }
        do { _store = State(initialValue: AppStore(persistence: try LocalPersistence(inMemory: preview), preview: preview)) }
        catch { _startupError = State(initialValue: "无法打开本地音乐资料。请检查设备可用空间后重新打开。") }
        let navigation = UINavigationBarAppearance(); navigation.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance = navigation; UINavigationBar.appearance().scrollEdgeAppearance = navigation
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if let store { RootView().environment(store).preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--dark") ? .dark : store.colorScheme).task { await store.start() }.onOpenURL { store.handleURL($0) } }
                else { ContentUnavailableView("暂时无法打开余音", systemImage: "externaldrive.badge.exclamationmark", description: Text(startupError ?? "请重试。")) }
            }
            .onChange(of: phase) { _, value in if value != .active { store?.preheater.stop(); store?.player.save(); Task { await DiagnosticRecorder.shared.flush() } } else { Task { await store?.becameActive() } } }
        }
    }
}
