import Foundation

package struct AllowlistRow: Equatable, Identifiable {
    package var id: Int64
    package var title: String
    package var guid: String
    package var isGroup: Bool
    package var enabled: Bool
    package var outsideList: Bool = false

    package var kindLabel: String {
        if outsideList { return "一覧外" }
        return isGroup ? "グループ" : "1対1"
    }
}

package enum AllowlistOrdering {
    /// オンを上、その中では1対1をグループより上。検索は名前と id。
    package static func rows(chats: [ChatSummary], enabledIDs: Set<Int64>, query: String) -> [AllowlistRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let known = Set(chats.map(\.id))
        var rows: [AllowlistRow] = chats.map { chat in
            AllowlistRow(
                id: chat.id,
                title: chat.title,
                guid: chat.guid,
                isGroup: chat.isGroup,
                enabled: enabledIDs.contains(chat.id)
            )
        }
        for id in enabledIDs.sorted() where !known.contains(id) {
            rows.append(AllowlistRow(
                id: id,
                title: "id:\(id)（一覧外）",
                guid: "",
                isGroup: false,
                enabled: true,
                outsideList: true
            ))
        }
        let filtered = rows.filter { row in
            guard !needle.isEmpty else { return true }
            if String(row.id).contains(needle) { return true }
            return row.title.lowercased().contains(needle)
        }
        return filtered.sorted { lhs, rhs in
            if lhs.outsideList != rhs.outsideList { return lhs.outsideList && !rhs.outsideList }
            if lhs.enabled != rhs.enabled { return lhs.enabled && !rhs.enabled }
            if lhs.isGroup != rhs.isGroup { return !lhs.isGroup && rhs.isGroup }
            let title = lhs.title.localizedStandardCompare(rhs.title)
            if title != .orderedSame { return title == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}
