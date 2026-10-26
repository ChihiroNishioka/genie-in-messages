import Foundation

struct WatchEvent: Equatable {
    var id: Int64
    var guid: String
    var chatID: Int64?
    var text: String
    var isFromMe: Bool
    var createdAt: String?
    /// `edited` / `unsent` など。新規行では nil。
    var type: String?
    var isReaction: Bool

    var isMutation: Bool { type != nil }

    static func decode(_ line: String) -> WatchEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        guard let raw = try? decoder.decode(Raw.self, from: data) else { return nil }
        return WatchEvent(
            id: raw.id,
            guid: raw.guid ?? "",
            chatID: raw.chatID,
            text: raw.text ?? "",
            isFromMe: raw.isFromMe ?? false,
            createdAt: raw.createdAt,
            type: raw.type,
            isReaction: raw.isReaction ?? false
        )
    }
}

private struct Raw: Decodable {
    var id: Int64
    var guid: String?
    var chatID: Int64?
    var text: String?
    var isFromMe: Bool?
    var createdAt: String?
    var type: String?
    var isReaction: Bool?

    enum CodingKeys: String, CodingKey {
        case id, guid, text, type
        case chatID = "chat_id"
        case isFromMe = "is_from_me"
        case createdAt = "created_at"
        case isReaction = "is_reaction"
    }
}
