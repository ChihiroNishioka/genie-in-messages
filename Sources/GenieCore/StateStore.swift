import Foundation

struct SentFingerprint: Codable, Equatable {
    var hash: String
    var sentAt: Date
}

struct RateEvent: Codable, Equatable {
    var chatID: Int64
    var at: Date

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case at
    }
}

package struct PersistedState: Codable, Equatable {
    var v: Int
    var cursorRowID: Int64
    var seenGUIDs: [String]
    var sentGUIDs: [String]
    var fingerprints: [SentFingerprint]
    var handledReplyIDs: [String]
    var replyCursor: String?
    var haltedChatIDs: [Int64]
    var rateEvents: [RateEvent]

    static let empty = PersistedState(
        v: 1,
        cursorRowID: 0,
        seenGUIDs: [],
        sentGUIDs: [],
        fingerprints: [],
        handledReplyIDs: [],
        replyCursor: nil,
        haltedChatIDs: [],
        rateEvents: []
    )

    enum CodingKeys: String, CodingKey {
        case v
        case cursorRowID = "cursor_rowid"
        case seenGUIDs = "seen_guids"
        case sentGUIDs = "sent_guids"
        case fingerprints
        case handledReplyIDs = "handled_reply_ids"
        case replyCursor = "reply_cursor"
        case haltedChatIDs = "halted_chat_ids"
        case rateEvents = "rate_events"
    }
}

package struct DeadLetterEntry: Codable, Equatable {
    var ts: String
    var kind: String
    var chatID: Int64?
    var guid: String?
    var rowid: Int64?
    var attempts: Int
    var error: String

    enum CodingKeys: String, CodingKey {
        case ts, kind, guid, attempts, error
        case chatID = "chat_id"
        case rowid
    }
}

package protocol StatePersisting: Sendable {
    func load() throws -> PersistedState
    func save(_ state: PersistedState) throws
    func appendDeadLetter(_ entry: DeadLetterEntry) throws
}

package enum StateError: Error {
    case corrupt
}

package struct FileStateStore: StatePersisting {
    package var paths: ConfigPaths

    package init(paths: ConfigPaths) {
        self.paths = paths
    }

    package func load() throws -> PersistedState {
        guard FileManager.default.fileExists(atPath: paths.stateFile.path) else {
            return .empty
        }
        let data = try Data(contentsOf: paths.stateFile)
        do {
            return try StateCoding.decoder().decode(PersistedState.self, from: data)
        } catch {
            throw StateError.corrupt
        }
    }

    package func save(_ state: PersistedState) throws {
        let data = try StateCoding.encoder().encode(state)
        try data.write(to: paths.stateFile, options: .atomic)
        try FilePermissions.set(paths.stateFile, mode: 0o600)
    }

    package func appendDeadLetter(_ entry: DeadLetterEntry) throws {
        var data = try StateCoding.encoder().encode(entry)
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: paths.deadLetterFile.path) {
            FileManager.default.createFile(
                atPath: paths.deadLetterFile.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            )
        }
        let handle = try FileHandle(forWritingTo: paths.deadLetterFile)
        defer { try? handle.close() }
        _ = handle.seekToEndOfFile()
        try handle.write(contentsOf: data)
        try FilePermissions.set(paths.deadLetterFile, mode: 0o600)
    }

    package static func quarantine(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let destination = url.appendingPathExtension("broken")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        try FilePermissions.set(destination, mode: 0o600)
    }
}

enum StateCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

final class MemoryStateStore: StatePersisting, @unchecked Sendable {
    var state: PersistedState
    var deadLetters: [DeadLetterEntry] = []
    var shouldFailSave = false

    init(state: PersistedState = .empty) {
        self.state = state
    }

    func load() throws -> PersistedState { state }

    func save(_ state: PersistedState) throws {
        if shouldFailSave { throw StateError.corrupt }
        self.state = state
    }

    func appendDeadLetter(_ entry: DeadLetterEntry) throws {
        deadLetters.append(entry)
    }
}
