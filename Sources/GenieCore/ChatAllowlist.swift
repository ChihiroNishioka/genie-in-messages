import Foundation

package struct AllowlistRow: Equatable, Identifiable {
    package var id: Int64
    package var title: String
    package var guid: String
    package var isGroup: Bool
    package var enabled: Bool

    package var kindLabel: String { isGroup ? "グループ" : "1対1" }
}

package enum AllowlistOrdering {
    /// オンを上、その中では1対1をグループより上。検索は名前と id。
    package static func rows(chats: [ChatSummary], enabledIDs: Set<Int64>, query: String) -> [AllowlistRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = chats.filter { chat in
            guard !needle.isEmpty else { return true }
            if String(chat.id).contains(needle) { return true }
            return chat.title.lowercased().contains(needle)
        }
        let rows = filtered.map { chat in
            AllowlistRow(
                id: chat.id,
                title: chat.title,
                guid: chat.guid,
                isGroup: chat.isGroup,
                enabled: enabledIDs.contains(chat.id)
            )
        }
        return rows.sorted { lhs, rhs in
            if lhs.enabled != rhs.enabled { return lhs.enabled && !rhs.enabled }
            if lhs.isGroup != rhs.isGroup { return !lhs.isGroup && rhs.isGroup }
            let title = lhs.title.localizedStandardCompare(rhs.title)
            if title != .orderedSame { return title == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}
