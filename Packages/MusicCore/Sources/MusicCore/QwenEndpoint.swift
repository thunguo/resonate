import Foundation

public struct QwenEndpoint: Equatable, Sendable {
    public var region: String
    public var workspace: String
    public init(region: String = "cn-beijing", workspace: String = "") { self.region = region; self.workspace = workspace }
    public init?(url: String) {
        guard let parsed = URL(string: url), parsed.scheme == "https", let host = parsed.host else { return nil }
        if host == "dashscope.aliyuncs.com" { self.init() }
        else if host == "dashscope-intl.aliyuncs.com" { self.init(region: "ap-southeast-1") }
        else {
            let parts = host.split(separator: ".").map(String.init)
            guard parts.count == 5, parts.suffix(3) == ["maas", "aliyuncs", "com"], ["cn-beijing", "ap-southeast-1"].contains(parts[1]) else { return nil }
            self.init(region: parts[1], workspace: parts[0])
        }
    }
    public var baseURL: String {
        let host = workspace.isEmpty ? (region == "cn-beijing" ? "dashscope.aliyuncs.com" : "dashscope-intl.aliyuncs.com") : "\(workspace).\(region).maas.aliyuncs.com"
        return "https://\(host)/compatible-mode/v1"
    }
    public var validWorkspace: Bool { workspace.isEmpty || (workspace.count <= 63 && workspace.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } && workspace.first != "-" && workspace.last != "-") }
}
