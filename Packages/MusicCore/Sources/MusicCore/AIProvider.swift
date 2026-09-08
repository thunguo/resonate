import Foundation

public enum ProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case deepseek, qwen, kimi, glm, custom
    public var id: String { rawValue }
    public var label: String { switch self { case .deepseek: return "DeepSeek"; case .qwen: return "阿里百炼"; case .kimi: return "Kimi"; case .glm: return "智谱"; case .custom: return "自定义服务" } }
    public var baseURL: String { switch self { case .deepseek: return "https://api.deepseek.com"; case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"; case .kimi: return "https://api.moonshot.cn/v1"; case .glm: return "https://open.bigmodel.cn/api/paas/v4"; case .custom: return "" } }
    public var models: [String] { switch self { case .deepseek: return ["deepseek-v4-flash", "deepseek-v4-pro"]; case .qwen: return ["qwen3.7-plus", "qwen-plus"]; case .kimi: return ["kimi-k3"]; case .glm: return ["glm-4.7-flash", "glm-5.2"]; case .custom: return [] } }
    public var consoleURL: URL { URL(string: { switch self { case .deepseek: return "https://platform.deepseek.com/api_keys"; case .qwen: return "https://bailian.console.aliyun.com/"; case .kimi: return "https://platform.kimi.com/"; case .glm: return "https://open.bigmodel.cn/"; case .custom: return "https://platform.deepseek.com/" } }())! }
}
public struct AIProviderConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: ProviderKind
    public var name: String
    public var baseURL: String
    public var model: String
    public var secretID: String
    public var consentDate: Date?
    public init(id: UUID = UUID(), kind: ProviderKind = .deepseek, name: String? = nil, baseURL: String? = nil, model: String? = nil, secretID: String? = nil, consentDate: Date? = nil) {
        self.id = id; self.kind = kind; self.name = name ?? kind.label; self.baseURL = baseURL ?? kind.baseURL; self.model = model ?? kind.models.first ?? ""; self.secretID = secretID ?? "ai.\(id.uuidString)"; self.consentDate = consentDate
    }
    public func endpoint(_ path: String) throws -> URL {
        guard let c = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), c.scheme == "https", c.host != nil, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, let url = c.url else { throw MusicError.invalidConfiguration("请输入有效的 HTTPS Base URL，地址中不要包含密钥或查询参数。") }
        if url.path.hasSuffix("/chat/completions") { throw MusicError.invalidConfiguration("请填写 Base URL，去掉末尾的 /chat/completions。") }
        return url.appendingPathComponent(path)
    }
}
public struct AISecrets: Codable, Sendable {
    public var apiKey: String
    public var headers: [String: String]
    public init(apiKey: String, headers: [String: String] = [:]) { self.apiKey = apiKey; self.headers = headers }
}
public struct ChatMessage: Codable, Sendable { public var role: String; public var content: String; public init(_ role: String, _ content: String) { self.role = role; self.content = content } }
public struct AIProvider: Sendable {
    public let config: AIProviderConfig
    private let secrets: AISecrets
    private let transport: any HTTPTransport
    public init(config: AIProviderConfig, secrets: AISecrets, transport: any HTTPTransport = PrivateTransport()) { self.config = config; self.secrets = secrets; self.transport = transport }
    public func makeRequest(messages: [ChatMessage], stream: Bool = false, maxTokens: Int = 1800) throws -> URLRequest {
        guard !config.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw MusicError.invalidConfiguration("请填写模型 ID。") }
        guard !secrets.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MusicError.invalidConfiguration("请填写 API Key。") }
        var r = URLRequest(url: try config.endpoint("chat/completions"))
        r.httpMethod = "POST"; r.timeoutInterval = 60
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(secrets.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        for (key, value) in secrets.headers {
            guard !["authorization", "cookie", "host", "content-type", "content-length"].contains(key.lowercased()), !key.contains(where: \.isNewline), !value.contains(where: \.isNewline) else { throw MusicError.invalidConfiguration("自定义请求头不能覆盖认证、Cookie 或连接信息。") }
            r.setValue(value, forHTTPHeaderField: key)
        }
        var body: [String: JSONValue] = ["model": .string(config.model), "messages": .array(messages.map { .object(["role": .string($0.role), "content": .string($0.content)]) }), "stream": .bool(stream), "max_tokens": .number(Double(maxTokens))]
        switch config.kind {
        case .deepseek, .kimi, .glm: body["thinking"] = .object(["type": .string("disabled")])
        case .qwen: body["enable_thinking"] = .bool(false)
        case .custom: break
        }
        r.httpBody = try JSONEncoder().encode(body)
        return r
    }
    public static func checkStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401: throw MusicError.message("API Key 无效，或密钥与服务地域不匹配。")
        case 402: throw MusicError.message("模型账户额度不足，请前往厂商控制台查看。")
        case 403: throw MusicError.message("当前密钥没有访问此模型的权限。")
        case 404: throw MusicError.message("未找到模型或接口，请检查模型 ID 和 Base URL。")
        case 429: throw MusicError.message("请求频率或账户额度达到限制，请查看厂商控制台。")
        default: throw MusicError.message("模型服务暂时不可用（\(status)），请稍后重试。")
        }
    }
    public func complete(_ messages: [ChatMessage], maxTokens: Int = 1800) async throws -> String {
        let (data, response) = try await transport.data(for: makeRequest(messages: messages, maxTokens: maxTokens))
        try Task.checkCancellation(); try Self.checkStatus(response.statusCode)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let choice = json["choices"].array.first else { throw MusicError.invalidResponse }
        guard choice["finish_reason"].string != "length" else { throw MusicError.message("模型回复超出长度限制，请缩短需求后重试。") }
        let text = choice["message"]["content"].string
        guard !text.isEmpty else { throw MusicError.message("模型没有返回正文，请更换兼容的对话模型。") }
        return text
    }
    public func testConnection() async throws { _ = try await complete([.init("user", "请只回复：连接成功")], maxTokens: 32) }
    public func models() async throws -> [String] {
        // Reuse header validation so discovery has the same privacy boundary as chat.
        _ = try makeRequest(messages: [])
        var r = URLRequest(url: try config.endpoint("models"))
        r.setValue("Bearer \(secrets.apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in secrets.headers where !["cookie", "host", "authorization"].contains(key.lowercased()) { r.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await transport.data(for: r)
        try Task.checkCancellation()
        try Self.checkStatus(response.statusCode)
        let j = try JSONDecoder().decode(JSONValue.self, from: data)
        return j["data"].array.map { $0["id"].string }.filter { !$0.isEmpty }.sorted()
    }
    public func stream(_ messages: [ChatMessage], onText: @escaping @Sendable (String) async -> Void) async throws -> String {
        guard let streaming = transport as? any StreamingTransport else {
            let text = try await complete(messages); await onText(text); return text
        }
        let (lines, response) = try await streaming.lines(for: makeRequest(messages: messages, stream: true, maxTokens: 2200))
        try Self.checkStatus(response.statusCode)
        var text = "", nonSSE = "", wasTruncated = false, receivedSSE = false, finished = false
        for try await line in lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { if !line.hasPrefix(":") { nonSSE += line }; continue }
            receivedSSE = true
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { finished = true; break }
            guard let data = payload.data(using: .utf8), let j = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
            if !j["error"].isNull { throw MusicError.message("模型生成中断，请稍后重试。") }
            if let choice = j["choices"].array.first {
                text += choice["delta"]["content"].string
                wasTruncated = choice["finish_reason"].string == "length" || wasTruncated
                finished = !choice["finish_reason"].string.isEmpty || finished
                await onText(text)
            }
        }
        if text.isEmpty, let data = nonSSE.data(using: .utf8), let j = try? JSONDecoder().decode(JSONValue.self, from: data), let choice = j["choices"].array.first {
            text = choice["message"]["content"].string; wasTruncated = choice["finish_reason"].string == "length"; await onText(text)
        }
        guard !text.isEmpty else { throw MusicError.invalidResponse }
        if wasTruncated { throw MusicError.message("回复长度达到上限，已保留收到的内容。") }
        if receivedSSE && !finished { throw MusicError.message("模型连接提前结束，已保留收到的内容，请重试。") }
        return text
    }
}
