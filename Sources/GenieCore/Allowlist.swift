import Foundation

package protocol AllowlistPersisting: Sendable {
    func load() throws -> Set<Int64>
    func save(_ ids: Set<Int64>) throws
}

package enum AllowlistError: Error {
    case corrupt
}

struct AllowlistDocument: Codable, Equatable {
    var enabledChatIDs: [Int64]

    enum CodingKeys: String, CodingKey {
        case enabledChatIDs = "enabled_chat_ids"
    }
}

package struct FileAllowlistStore: AllowlistPersisting {
    package var file: URL

    package init(file: URL) {
        self.file = file
    }

    package func load() throws -> Set<Int64> {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return []
        }
        let data = try Data(contentsOf: file)
        do {
            let document = try JSONDecoder().decode(AllowlistDocument.self, from: data)
            return Set(document.enabledChatIDs)
        } catch {
            throw AllowlistError.corrupt
        }
    }

    package func save(_ ids: Set<Int64>) throws {
        let document = AllowlistDocument(enabledChatIDs: ids.sorted())
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
    init(ids: Set<Int64> = []) { self.ids = ids }
    func load() throws -> Set<Int64> { ids }
    func save(_ ids: Set<Int64>) throws { self.ids = ids }
}
