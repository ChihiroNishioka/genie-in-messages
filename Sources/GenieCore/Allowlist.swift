import Foundation

package struct AllowedChat: Codable, Equatable {
    var id: Int64
    var guid: String
}

package struct AllowlistState: Equatable {
    var entries: [AllowedChat]

    var ids: Set<Int64> { Set(entries.map(\.id)) }
    var isEmpty: Bool { entries.isEmpty }

    func contains(_ id: Int64) -> Bool {
        entries.contains { $0.id == id }
    }

    static let empty = AllowlistState(entries: [])
}

package protocol AllowlistPersisting: Sendable {
    func load() throws -> AllowlistState
    func save(_ state: AllowlistState) throws
}

package enum AllowlistError: Error {
    case corrupt
}

struct AllowlistDocument: Codable, Equatable {
    var enabledChatIDs: [Int64]
    var enabledChats: [AllowedChat]

    enum CodingKeys: String, CodingKey {
        case enabledChatIDs = "enabled_chat_ids"
        case enabledChats = "enabled_chats"
    }

    init(enabledChatIDs: [Int64], enabledChats: [AllowedChat]) {
        self.enabledChatIDs = enabledChatIDs
        self.enabledChats = enabledChats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabledChatIDs = try container.decodeIfPresent([Int64].self, forKey: .enabledChatIDs) ?? []
        enabledChats = try container.decodeIfPresent([AllowedChat].self, forKey: .enabledChats) ?? []
    }
}

package struct FileAllowlistStore: AllowlistPersisting {
    package var file: URL

    package init(file: URL) {
        self.file = file
    }

    package func load() throws -> AllowlistState {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .empty
        }
        let data = try Data(contentsOf: file)
        do {
            let document = try JSONDecoder().decode(AllowlistDocument.self, from: data)
            if !document.enabledChats.isEmpty {
                return AllowlistState(entries: document.enabledChats.sorted { $0.id < $1.id })
            }
            return AllowlistState(entries: document.enabledChatIDs.sorted().map { AllowedChat(id: $0, guid: "") })
        } catch {
            throw AllowlistError.corrupt
        }
    }

    package func save(_ state: AllowlistState) throws {
        let entries = state.entries.sorted { $0.id < $1.id }
        let document = AllowlistDocument(
            enabledChatIDs: entries.map(\.id),
            enabledChats: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: file, options: .atomic)
        try FilePermissions.set(file, mode: 0o600)
    }

    package static func quarantine(_ url: URL) throws {
        try FileStateStore.quarantine(url)
    }
}

final class MemoryAllowlist: AllowlistPersisting, @unchecked Sendable {
    var ids: Set<Int64>
    var guids: [Int64: String]
    var failSave = false

    init(ids: Set<Int64> = [], guids: [Int64: String] = [:]) {
        self.ids = ids
        self.guids = guids
    }

    func load() throws -> AllowlistState {
        AllowlistState(entries: ids.sorted().map { AllowedChat(id: $0, guid: guids[$0] ?? "") })
    }

    func save(_ state: AllowlistState) throws {
        if failSave { throw AllowlistError.corrupt }
        ids = state.ids
        guids = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.id, $0.guid) })
    }
}
