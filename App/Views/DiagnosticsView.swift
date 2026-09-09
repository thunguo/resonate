import SwiftUI
import UniformTypeIdentifiers
import MusicCore

private struct DiagnosticExport: Codable {
    var version: String
    var system: String
    var environment: String
    var records: [DiagnosticRecord]
}
private struct DiagnosticDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct DiagnosticsView: View {
    @State private var document = DiagnosticDocument(data: Data())
    @State private var preview = ""
    @State private var count = 0
    @State private var exporting = false
    @State private var error: String?
    private var version: String {
        "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))"
    }
    private var environment: String {
        #if targetEnvironment(simulator)
        "模拟器"
        #else
        "iPhone"
        #endif
    }
    var body: some View {
        Form {
            Section("运行环境") {
                LabeledContent("版本", value: version)
                LabeledContent("系统", value: UIDevice.current.systemVersion)
                LabeledContent("设备环境", value: environment)
            }
            Section {
                LabeledContent("记录", value: "\(count) 条")
                DisclosureGroup("预览导出内容") {
                    Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Button("导出诊断", systemImage: "square.and.arrow.up") { exporting = true }.disabled(count == 0)
                Button("清除诊断", role: .destructive) {
                    Task { do { try await DiagnosticRecorder.shared.clear(); await refresh() } catch { self.error = "暂时无法清除，请重试。" } }
                }
            } header: { Text("仅保存在本机") } footer: {
                Text("最多保留 7 天或 5 MB。只记录操作类别、耗时和结果，不含账号、密钥、Cookie、搜索词、歌曲列表或请求正文。不会自动上传；导出前可以查看全部内容。")
            }
            Section { Link("提交问题与建议", destination: URL(string: "https://github.com/thunguo/resonate/issues/new/choose")!) }
            if let error { Section { InlineError(message: error) } }
        }.scrollContentBackground(.hidden).cabinetBackground().navigationTitle("诊断与反馈").navigationBarTitleDisplayMode(.inline)
            .task { await refresh() }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "余音诊断") { result in
                if case .failure = result { error = "未能导出诊断，请重试。" }
            }
    }
    private func refresh() async {
        let records = await DiagnosticRecorder.shared.snapshot()
        let export = DiagnosticExport(version: version, system: UIDevice.current.systemVersion, environment: environment, records: records)
        let data = await Task.detached { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; return (try? encoder.encode(export)) ?? Data() }.value
        count = records.count; document = .init(data: data); preview = String(decoding: data, as: UTF8.self)
    }
}
