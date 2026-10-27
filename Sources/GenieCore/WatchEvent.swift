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
    var chatGUID: String?
    /// imsg の `sender`。無いときは空。
    var sender: String
    var isGroup: Bool
    /// 外部の参加者。自分宛てトークでは空。
    var participants: [String]

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
            isReaction: raw.isReaction ?? false,
            chatGUID: raw.chatGUID,
            sender: raw.sender ?? "",
            isGroup: raw.isGroup ?? false,
            participants: raw.participants ?? []
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
    var chatGUID: String?
    var sender: String?
    var isGroup: Bool?
    var participants: [String]?

    enum CodingKeys: String, CodingKey {
        case id, guid, text, type, sender, participants
        case chatID = "chat_id"
        case isFromMe = "is_from_me"
        case createdAt = "created_at"
        case isReaction = "is_reaction"
        case chatGUID = "chat_guid"
        case isGroup = "is_group"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        guid = try container.decodeIfPresent(String.self, forKey: .guid)
        chatID = try container.decodeIfPresent(Int64.self, forKey: .chatID)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        isFromMe = try container.decodeIfPresent(Bool.self, forKey: .isFromMe)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        isReaction = try container.decodeIfPresent(Bool.self, forKey: .isReaction)
        chatGUID = try container.decodeIfPresent(String.self, forKey: .chatGUID)
        // 新しい欄の型が違っても、行全体は捨てない。
        sender = try? container.decode(String.self, forKey: .sender)
        isGroup = try? container.decode(Bool.self, forKey: .isGroup)
        participants = try? container.decode([String].self, forKey: .participants)
    }
}
