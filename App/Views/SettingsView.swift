import SwiftUI
import MusicCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLogout = false
    @State private var confirmHistory = false
    @State private var confirmCache = false
    @State private var confirmAI = false
    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                if let profile = store.profile {
                    HStack(spacing: 14) { Artwork(url: profile.avatar, size: 48, radius: 24); VStack(alignment: .leading, spacing: 5) { Text(profile.name); Text("已连接网易云音乐").font(.caption).foregroundStyle(Palette.secondary) } }
                    Button("重新同步收藏") { Task { await store.syncLibrary() } }.disabled(store.isSyncing)
                    Button("退出网易云账号", role: .destructive) { confirmLogout = true }
                } else { Button("连接网易云音乐") { dismiss(); store.showLogin = true } }
            } header: { Text("音乐账号") }
            Section {
                NavigationLink { AISettingsView() } label: { HStack { Label("模型服务", systemImage: "slider.horizontal.3"); Spacer(); Text(store.activeProviderName ?? "未连接").foregroundStyle(Palette.secondary) } }
                NavigationLink { PreferenceEditor() } label: { Label("我的音乐偏好", systemImage: "heart.text.clipboard") }
            } header: { Text("智能助手") } footer: { Text("由你选择模型厂商并提供 API Key。普通播放无需连接模型。") }
            Section("聆听") {
                Picker("音质", selection: $store.preferences.quality) { ForEach(AudioQuality.allCases, id: \.self) { Text($0.label).tag($0) } }
                Toggle("仅通过 Wi-Fi 下载", isOn: $store.preferences.wifiOnly)
                Picker("外观", selection: $store.preferences.appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                NavigationLink("下载与存储") { ScrollView { DownloadListContent().padding(20) }.cabinetBackground().navigationTitle("下载与存储") }
            }
            Section("数据") {
                NavigationLink("待同步更改（\(store.pendingMutations.count)）") { PendingSyncView() }
                Button("清除本机播放与搜索记录", role: .destructive) { confirmHistory = true }
                Button("清除封面、歌词与音乐资料缓存", role: .destructive) { confirmCache = true }
                Button("清除 AI 编排与解读记录", role: .destructive) { confirmAI = true }
                NavigationLink("本机聆听统计") { ListeningStatisticsView() }
                NavigationLink("隐私与数据使用") { PrivacyView() }
            }
            Section { HStack { Text("余音"); Spacer(); Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "").foregroundStyle(Palette.secondary) }; Text("收藏值得反复听。").foregroundStyle(Palette.secondary) }
        }.scrollContentBackground(.hidden).cabinetBackground().navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onChange(of: store.preferences.quality) { _, _ in store.savePreferences() }
            .onChange(of: store.preferences.wifiOnly) { _, _ in store.savePreferences() }
            .onChange(of: store.preferences.appearance) { _, _ in store.savePreferences() }
            .confirmationDialog("退出将清除这个账号的本地收藏缓存、下载和播放记录。网易云上的收藏不受影响。", isPresented: $confirmLogout, titleVisibility: .visible) { Button("退出并清除本机数据", role: .destructive) { Task { await store.logout() } } }
            .confirmationDialog("清除本机播放与搜索记录？", isPresented: $confirmHistory, titleVisibility: .visible) { Button("清除记录", role: .destructive) { store.clearHistory() } }
            .confirmationDialog("清除封面、歌词与音乐资料缓存？需要时会重新读取，不影响收藏和下载。", isPresented: $confirmCache, titleVisibility: .visible) { Button("清除缓存", role: .destructive) { store.clearMusicCache() } }
            .confirmationDialog("清除这个账号在本机保存的 AI 编排与解读记录？网易云歌单不受影响。", isPresented: $confirmAI, titleVisibility: .visible) { Button("清除 AI 记录", role: .destructive) { store.clearAIHistory() } }
    }
}
struct PreferenceEditor: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Section { TextEditor(text: $store.preferences.musicTaste).frame(minHeight: 180).accessibilityLabel("音乐偏好") } header: { Text("长期偏好") } footer: { Text("例如：喜欢独立民谣，工作时偏好纯音乐。这些文字保存在设备上，只在请求 AI 编排时发送给所选厂商。一次性的听歌要求请写在编排面板里。") }
            Section { Button("清空偏好", role: .destructive) { store.preferences.musicTaste = ""; store.savePreferences() } }
        }.scrollContentBackground(.hidden).cabinetBackground().navigationTitle("我的音乐偏好").onDisappear { store.savePreferences() }
    }
}
struct AISettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var editor: AIProviderConfig?
    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                ForEach(store.configurations) { config in Button { editor = config } label: { VStack(alignment: .leading, spacing: 6) { Text(config.name).foregroundStyle(Palette.text); Text(config.model).font(.caption).foregroundStyle(Palette.secondary) } }.swipeActions { Button("删除", role: .destructive) { store.removeConfiguration(config) } } }
                Button("添加模型服务", systemImage: "plus") { editor = AIProviderConfig() }.accessibilityIdentifier("addProvider")
            } header: { Text("已连接的服务") }
            Section {
                Picker("选歌与编排", selection: $store.arrangementProviderID) { Text("未启用").tag(nil as UUID?); ForEach(store.configurations) { Text($0.name).tag(Optional($0.id)) } }
                Picker("音乐解读", selection: $store.explanationProviderID) { Text("与选歌编排相同").tag(nil as UUID?); ForEach(store.configurations) { Text($0.name).tag(Optional($0.id)) } }
            } header: { Text("使用哪个模型") } footer: { Text("不会在请求失败时自动切换到其他厂商。你可以随时更改或移除服务。") }
            Section { Text("API Key 和自定义请求头保存在设备钥匙串。模型请求由 iPhone 直接发往所选服务，调用费用由该服务按你的账户规则计算。").font(.footnote).foregroundStyle(Palette.secondary) }
        }.scrollContentBackground(.hidden).cabinetBackground().navigationTitle("模型服务").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editor) { config in ProviderEditor(configuration: config) }
            .onChange(of: store.arrangementProviderID) { _, _ in store.saveProviderChoices() }
            .onChange(of: store.explanationProviderID) { _, _ in store.saveProviderChoices() }
    }
}
struct ProviderEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var configuration: AIProviderConfig
    @State private var apiKey = ""
    @State private var headersText = ""
    @State private var availableModels: [String] = []
    @State private var consent = false
    @State private var testing = false
    @State private var tested = false
    @State private var message: String?
    @State private var workspace = ""
    @State private var region = "cn-beijing"
    @State private var task: Task<Void, Never>?
    init(configuration: AIProviderConfig) {
        _configuration = State(initialValue: configuration)
        let endpoint = QwenEndpoint(url: configuration.baseURL) ?? QwenEndpoint()
        _region = State(initialValue: endpoint.region); _workspace = State(initialValue: endpoint.workspace)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("厂商与模型") {
                    Picker("厂商", selection: $configuration.kind) { ForEach(ProviderKind.allCases) { Text($0.label).tag($0) } }.accessibilityIdentifier("providerPicker")
                    TextField("配置名称", text: $configuration.name)
                    if configuration.kind == .qwen {
                        Picker("地域", selection: Binding(get: { region }, set: { region = $0; updateRegion() })) { Text("北京").tag("cn-beijing"); Text("新加坡").tag("ap-southeast-1") }
                        TextField("业务空间 ID（可选）", text: Binding(get: { workspace }, set: { workspace = $0; updateRegion() })).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("密钥需与所选地域一致。未填写业务空间时使用仍兼容的公共地址。").font(.caption).foregroundStyle(Palette.secondary)
                    }
                    TextField("HTTPS Base URL", text: $configuration.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("baseURLField")
                    SecureField("API Key", text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("apiKeyField")
                    HStack { TextField("模型 ID", text: $configuration.model).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("modelIDField"); if !availableModels.isEmpty { Menu { ForEach(availableModels, id: \.self) { model in Button(model) { configuration.model = model } } } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("选择模型") } }
                    Button("获取账户可用模型") { fetchModels() }.disabled(apiKey.isEmpty || testing)
                    if configuration.kind != .custom { Link("前往厂商控制台", destination: configuration.kind.consoleURL) }
                }
                Section { TextEditor(text: $headersText).font(.system(.footnote, design: .monospaced)).frame(minHeight: 70).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("自定义请求头 JSON") } header: { Text("自定义请求头（可选）") } footer: { Text("填写 JSON 对象，例如 {\"X-Project\":\"music\"}。内容和 API Key 一起存入钥匙串。") }
                Section {
                    Toggle("允许发送本次需求和必要音乐资料", isOn: $consent)
                    Text("接收方：\(URL(string: configuration.baseURL)?.host ?? "尚未填写")\n会发送当前需求、候选歌曲名称与音乐人、必要偏好或音乐介绍。不会发送网易云 Cookie、手机号或音频文件。").font(.footnote).foregroundStyle(Palette.secondary)
                    Button(testing ? "正在测试…" : "测试连接") { test() }.disabled(testing || !consent || apiKey.isEmpty).accessibilityIdentifier("testConnection")
                    Text("测试会发送一条极短请求，可能产生少量调用费用。").font(.caption).foregroundStyle(Palette.secondary)
                    if let message { Text(message).font(.subheadline).foregroundStyle(tested ? Palette.accent : Palette.secondary) }
                }
            }.scrollContentBackground(.hidden).cabinetBackground().navigationTitle("连接模型服务").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("启用") { save() }.disabled(!tested || !consent || testing) } }
        }.onAppear {
            availableModels = configuration.kind.models; consent = configuration.consentDate != nil
            if let data = Keychain.read(configuration.secretID), let secrets = try? JSONDecoder().decode(AISecrets.self, from: data) { apiKey = secrets.apiKey; if !secrets.headers.isEmpty { headersText = String(data: (try? JSONEncoder().encode(secrets.headers)) ?? Data(), encoding: .utf8) ?? "" } }
        }
        .onChange(of: configuration.kind) { _, kind in configuration.name = kind.label; configuration.baseURL = kind.baseURL; configuration.model = kind.models.first ?? ""; availableModels = kind.models; apiKey = ""; headersText = ""; consent = false; tested = false }
        .onChange(of: configuration.baseURL) { old, new in
            if URL(string: old)?.host != URL(string: new)?.host { consent = false }
            if configuration.kind == .qwen, let endpoint = QwenEndpoint(url: new) { region = endpoint.region; workspace = endpoint.workspace }
            invalidate()
        }
        .onChange(of: configuration.model) { _, _ in invalidate() }
        .onChange(of: apiKey) { _, _ in invalidate() }
        .onChange(of: headersText) { _, _ in invalidate() }
        .onDisappear { task?.cancel() }
    }
    private func invalidate() { tested = false; message = nil; task?.cancel(); testing = false }
    private func updateRegion() {
        guard configuration.kind == .qwen else { return }
        let endpoint = QwenEndpoint(region: region, workspace: workspace.trimmingCharacters(in: .whitespacesAndNewlines))
        guard endpoint.validWorkspace else { invalidate(); message = "业务空间 ID 仅支持字母、数字和连字符。"; return }
        configuration.baseURL = endpoint.baseURL
    }
    private func secrets() throws -> AISecrets {
        if configuration.kind == .qwen, !QwenEndpoint(region: region, workspace: workspace.trimmingCharacters(in: .whitespacesAndNewlines)).validWorkspace { throw MusicError.invalidConfiguration("请检查业务空间 ID。") }
        var headers: [String: String] = [:]
        if !headersText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let data = headersText.data(using: .utf8), let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { throw MusicError.invalidConfiguration("请求头需要是键和值都为文字的 JSON 对象。") }; headers = decoded
        }
        return .init(apiKey: apiKey, headers: headers)
    }
    private func test() {
        testing = true; tested = false; message = nil
        task = Task { defer { testing = false }; do { let provider = try AIProvider(config: configuration, secrets: secrets()); try await provider.testConnection(); try Task.checkCancellation(); tested = true; message = "连接成功，可以启用。" } catch is CancellationError { } catch { message = error.localizedDescription } }
    }
    private func fetchModels() {
        guard consent else { message = "请先确认数据接收方并允许连接。"; return }
        testing = true
        task = Task { defer { testing = false }; do { let models = try await AIProvider(config: configuration, secrets: secrets()).models(); availableModels = Array(Set(configuration.kind.models + models)).sorted(); message = "已读取模型列表，也可手动填写模型 ID。" } catch is CancellationError { } catch { message = "无法获取列表，仍可使用预设或手动填写模型 ID。" } }
    }
    private func save() { do { configuration.consentDate = .now; try store.saveConfiguration(configuration, secrets: secrets()); dismiss() } catch { message = error.localizedDescription } }
}
struct PrivacyView: View {
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            SectionHeading(title: "音乐账号", subtitle: "网易云会话保存在设备钥匙串，仅交给你连接的音乐 API 服务使用。退出会清除本机账号缓存和下载。")
            SectionHeading(title: "模型请求", subtitle: "API Key 和额外请求头仅保存在设备钥匙串。请求直接发往你选择的厂商，数据处理遵循该厂商的条款。")
            SectionHeading(title: "本机记录", subtitle: "播放记录、搜索记录和音乐偏好保存在设备上。你可以在设置中清除记录或单独修改偏好。")
            SectionHeading(title: "系统扩展", subtitle: "小组件共享当前曲目信息和你固定的少量歌单摘要。账号凭据和模型密钥不放入共享区。")
            Text("本版本不包含广告或第三方行为分析 SDK。").font(.footnote).foregroundStyle(Palette.secondary)
        }.padding(24) }.cabinetBackground().navigationTitle("隐私与数据使用").navigationBarTitleDisplayMode(.inline)
    }
}
