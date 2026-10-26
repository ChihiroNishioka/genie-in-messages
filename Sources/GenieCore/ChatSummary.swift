import Foundation

package struct ChatSummary: Equatable, Identifiable {
    package var id: Int64
    package var title: String
    package var isGroup: Bool
}

package enum ChatListParser {
    /// `imsg chats --json` の NDJSON。識別子は `id`（chat.ROWID）だけを残す。
    /// ハンドルはタイトルに使わない。
    package static func parse(ndjson: String) -> [ChatSummary] {
        ndjson.split(whereSeparator: \.isNewline).compactMap { line in
            parseLine(String(line))
        }
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
        return ChatSummary(id: raw.id, title: title, isGroup: raw.isGroup ?? false)
    }
}

private struct RawChat: Decodable {
    var id: Int64
    var name: String?
    var displayName: String?
    var contactName: String?
    var isGroup: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case displayName = "display_name"
        case contactName = "contact_name"
        case isGroup = "is_group"
    }
}
