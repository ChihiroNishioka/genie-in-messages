import Foundation

/// 設定の意思と最後の成功一覧の照合を分ける。ファイルには保存しない。
struct ConfigGroupAuthorization {
    private var chats: [ChatSummary]?
    private var lastIDs: [String: Int64] = [:]
    private var intendedIDs: [String: Int64] = [:]

    var intentChatIDs: Set<Int64> { Set(intendedIDs.values) }

    mutating func resetVerification() {
        chats = nil
        lastIDs = [:]
        resolved = [:]
        notFound = 0
        notGroup = 0
    }
    private(set) var resolved: [Int64: String] = [:]
    private(set) var notFound = 0
    private(set) var notGroup = 0

    mutating func observe(_ chats: [ChatSummary], guids: [String]) {
        self.chats = chats
        refresh(guids: guids)
    }

    mutating func refresh(guids: [String]) {
        let intended = Set(guids)
        lastIDs = lastIDs.filter { intended.contains($0.key) }
        intendedIDs = intendedIDs.filter { intended.contains($0.key) }
        resolved = [:]
        notFound = 0
        notGroup = 0
        guard let chats else { return }
        for guid in guids {
            guard let chat = chats.first(where: { $0.guid == guid }) else {
                notFound += 1
                continue
            }
            guard SelfChat.resolveGroup(flag: chat.isGroup, chatGUID: chat.guid, chatIdentifier: chat.identifier) else {
                notGroup += 1
                continue
            }
            intendedIDs[guid] = chat.id
            lastIDs[guid] = chat.id
            resolved[chat.id] = guid
        }
    }

    func permitsReceive(_ id: Int64, guid: String?) -> Bool {
        guard let expected = resolved[id] else { return false }
        return guid == nil || guid == expected
    }

    func expectedGUIDs(for id: Int64) -> [String] {
        lastIDs.compactMap { $0.value == id ? $0.key : nil }
    }

    func permitsSend(_ id: Int64) -> Bool { lastIDs.values.contains(id) }
}
