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
    /// imsg の `sender`。無いときは空。ログにも payload にも出さない。
    var sender: String
    /// 連絡先名。imsg が既に付けているときだけ。無いときは空。
    var contactName: String
    var isGroup: Bool
    /// 外部の参加者。自分は入らない。自分宛てトークでは空。
    var participants: [String]
    /// `participants` が配列として読めたか。無い・壊れているときは false。
    var participantsKnown: Bool

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
            contactName: raw.contactName ?? "",
            isGroup: SelfChat.resolveGroup(
                flag: raw.isGroup,
                chatGUID: raw.chatGUID,
                chatIdentifier: raw.chatIdentifier
            ),
            participants: raw.participants,
            participantsKnown: raw.participantsKnown
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
    var contactName: String?
    var isGroup: Bool?
    var participants: [String]
    var participantsKnown: Bool
    var chatIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case id, guid, text, type, sender, participants
        case chatID = "chat_id"
        case isFromMe = "is_from_me"
        case createdAt = "created_at"
        case isReaction = "is_reaction"
        case chatGUID = "chat_guid"
        case isGroup = "is_group"
        case contactName = "sender_name"
        case chatIdentifier = "chat_identifier"
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
        contactName = try? container.decode(String.self, forKey: .contactName)
        isGroup = try? container.decode(Bool.self, forKey: .isGroup)
        chatIdentifier = try? container.decode(String.self, forKey: .chatIdentifier)
        if container.contains(.participants),
           let list = try? container.decode([String].self, forKey: .participants) {
            participants = list
            participantsKnown = true
        } else {
            participants = []
            participantsKnown = false
        }
    }
}
