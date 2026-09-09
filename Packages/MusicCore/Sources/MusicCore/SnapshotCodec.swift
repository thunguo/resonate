import Foundation

public enum SnapshotCodec {
    private struct Envelope<T: Encodable>: Encodable { let schemaVersion = 1; let payload: T }
    private struct ReadEnvelope<T: Decodable>: Decodable { let schemaVersion: Int; let payload: T }
    public static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(Envelope(payload: value)) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        if !json["schemaVersion"].isNull {
            guard json["schemaVersion"].int == 1 else { throw MusicError.message("本机资料来自更新版本，请更新余音后再打开。原有资料已保留。") }
            return try JSONDecoder().decode(ReadEnvelope<T>.self, from: data).payload
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
public struct ExplanationRecord: Codable, Sendable {
    public var trackID: Int64
    public var text: String
    public var sources: [MusicSource]
    public var history: [ChatMessage]
    public var updatedAt: Date
    public var validationMessage: String?
    public var draftText: String?
    public var draftQuestion: String?
    public init(trackID: Int64, text: String, sources: [MusicSource], history: [ChatMessage], updatedAt: Date = .now, validationMessage: String? = nil, draftText: String? = nil, draftQuestion: String? = nil) {
        self.trackID = trackID; self.text = text; self.sources = sources; self.history = history; self.updatedAt = updatedAt
        self.validationMessage = validationMessage; self.draftText = draftText; self.draftQuestion = draftQuestion
    }
}
public enum LibrarySort: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, name, artist
    public var id: String { rawValue }
    public var label: String { switch self { case .original: return "收藏顺序"; case .name: return "名称"; case .artist: return "音乐人" } }
}
