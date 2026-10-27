import Foundation

package struct ChatSummary: Equatable, Identifiable {
    package var id: Int64
    package var title: String
    package var isGroup: Bool
    package var guid: String
    package var identifier: String = ""
    /// 外部、または自分宛てでは自分自身。ログにもメニューのタイトルにも使わない。
    package var participants: [String] = []
    package var participantsKnown: Bool = false
    /// 自分のハンドル候補。ログに出さない。
    package var lastAddressedHandle: String = ""
}

package struct ChatListParse: Equatable {
    package var chats: [ChatSummary]
    /// 空でないのに読めなかった行の数。中身は残さない。
    package var failedLineCount: Int
}

package enum ChatListParser {
    /// `imsg chats --json` の NDJSON。識別子は `id`（chat.ROWID）だけを残す。
    /// ハンドルはタイトルに使わない。失敗した行の本文は返さない。
    package static func parse(ndjson: String) -> ChatListParse {
        var chats: [ChatSummary] = []
        var failed = 0
        for line in ndjson.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let chat = parseLine(text) {
                chats.append(chat)
            } else {
                failed += 1
            }
        }
        return ChatListParse(chats: chats, failedLineCount: failed)
    }

    static func parseLine(_ line: String) -> ChatSummary? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawChat.self, from: data) else {
            return nil
        }
        let title = [raw.name, raw.displayName, raw.contactName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "トーク \(raw.id)"
        let group = SelfChat.resolveGroup(flag: raw.isGroup, chatGUID: raw.guid, chatIdentifier: raw.identifier)
        return ChatSummary(
            id: raw.id,
            title: title,
            isGroup: group,
            guid: raw.guid ?? "",
            identifier: raw.identifier ?? "",
            participants: raw.participants,
            participantsKnown: raw.participantsKnown,
            lastAddressedHandle: raw.lastAddressedHandle ?? ""
        )
    }
}

private struct RawChat: Decodable {
    var id: Int64
    var name: String?
    var displayName: String?
    var contactName: String?
    var isGroup: Bool?
    var guid: String?
    var identifier: String?
    var participants: [String]
    var participantsKnown: Bool
    var lastAddressedHandle: String?

    enum CodingKeys: String, CodingKey {
        case id, name, guid, identifier, participants
        case displayName = "display_name"
        case contactName = "contact_name"
        case isGroup = "is_group"
        case lastAddressedHandle = "last_addressed_handle"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try? container.decode(String.self, forKey: .name)
        displayName = try? container.decode(String.self, forKey: .displayName)
        contactName = try? container.decode(String.self, forKey: .contactName)
        isGroup = try? container.decode(Bool.self, forKey: .isGroup)
        guid = try? container.decode(String.self, forKey: .guid)
        identifier = try? container.decode(String.self, forKey: .identifier)
        lastAddressedHandle = try? container.decode(String.self, forKey: .lastAddressedHandle)
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
