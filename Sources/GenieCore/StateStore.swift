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

struct MessageRoute: Codable, Equatable {
    var guid: String
    var chatID: Int64
    var at: Date
    var addressee: String? = nil

    enum CodingKeys: String, CodingKey {
        case guid
        case chatID = "chat_id"
        case at
        case addressee
    }
}

enum SendPart: String, Codable {
    case marker
    case body
}

struct PartialReply: Codable, Equatable {
    var replyID: String
    var chatID: Int64
    var markerGUID: String
    var at: Date
    var bodyResends: Int

    enum CodingKeys: String, CodingKey {
        case replyID = "reply_id"
        case chatID = "chat_id"
        case markerGUID = "marker_guid"
        case at
        case bodyResends = "body_resends"
    }

    init(replyID: String, chatID: Int64, markerGUID: String, at: Date, bodyResends: Int = 0) {
        self.replyID = replyID
        self.chatID = chatID
        self.markerGUID = markerGUID
        self.at = at
        self.bodyResends = bodyResends
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        replyID = try container.decode(String.self, forKey: .replyID)
        chatID = try container.decode(Int64.self, forKey: .chatID)
        markerGUID = try container.decode(String.self, forKey: .markerGUID)
        at = try container.decode(Date.self, forKey: .at)
        bodyResends = try container.decodeIfPresent(Int.self, forKey: .bodyResends) ?? 0
    }
}

struct PendingSend: Codable, Equatable {
    var replyID: String
    var chatID: Int64
    var hash: String
    var at: Date
    /// 結果不明の送信を、すでにレートへ数えたあとに残すとき true。再起動時に二重に数えない。
    var rateCounted: Bool
    var part: SendPart?

    enum CodingKeys: String, CodingKey {
        case replyID = "reply_id"
        case chatID = "chat_id"
        case hash
        case at
        case rateCounted = "rate_counted"
        case part
    }

    init(replyID: String, chatID: Int64, hash: String, at: Date, rateCounted: Bool = false, part: SendPart? = nil) {
        self.replyID = replyID
        self.chatID = chatID
        self.hash = hash
        self.at = at
        self.rateCounted = rateCounted
        self.part = part
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        replyID = try container.decode(String.self, forKey: .replyID)
        chatID = try container.decode(Int64.self, forKey: .chatID)
        hash = try container.decode(String.self, forKey: .hash)
        at = try container.decode(Date.self, forKey: .at)
        rateCounted = try container.decodeIfPresent(Bool.self, forKey: .rateCounted) ?? false
        part = try container.decodeIfPresent(SendPart.self, forKey: .part)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(replyID, forKey: .replyID)
        try container.encode(chatID, forKey: .chatID)
        try container.encode(hash, forKey: .hash)
        try container.encode(at, forKey: .at)
        try container.encode(rateCounted, forKey: .rateCounted)
        try container.encodeIfPresent(part, forKey: .part)
    }
}

struct ChatIdentity: Codable, Equatable {
    var id: Int64
    var guid: String
}

package struct PersistedState: Codable, Equatable {
    var v: Int
    var cursorRowID: Int64
    var seenGUIDs: [String]
    var sentGUIDs: [String]
    var fingerprints: [SentFingerprint]
    var handledReplyIDs: [String]
    var httpReplyCursor: String? = nil
    var replyCursor: String?
    var haltedChatIDs: [Int64]
    var rateEvents: [RateEvent]
    var routes: [MessageRoute]
    var pendingSends: [PendingSend]
    var partialReplies: [PartialReply]
    var knownChats: [ChatIdentity]

    static let empty = PersistedState(
        v: 1,
        cursorRowID: 0,
        seenGUIDs: [],
        sentGUIDs: [],
        fingerprints: [],
        handledReplyIDs: [],
        replyCursor: nil,
        haltedChatIDs: [],
        rateEvents: [],
        routes: [],
        pendingSends: [],
        partialReplies: [],
        knownChats: []
    )

    enum CodingKeys: String, CodingKey {
        case v
        case cursorRowID = "cursor_rowid"
        case seenGUIDs = "seen_guids"
        case sentGUIDs = "sent_guids"
        case fingerprints
        case handledReplyIDs = "handled_reply_ids"
        case replyCursor = "reply_cursor"
        case httpReplyCursor = "http_reply_cursor"
        case haltedChatIDs = "halted_chat_ids"
        case rateEvents = "rate_events"
        case routes
        case pendingSends = "pending_sends"
        case partialReplies = "partial_replies"
        case knownChats = "known_chats"
    }

    init(
        v: Int,
        cursorRowID: Int64,
        seenGUIDs: [String],
        sentGUIDs: [String],
        fingerprints: [SentFingerprint],
        handledReplyIDs: [String],
        replyCursor: String?,
        haltedChatIDs: [Int64],
        rateEvents: [RateEvent],
        routes: [MessageRoute],
        pendingSends: [PendingSend],
        partialReplies: [PartialReply] = [],
        knownChats: [ChatIdentity],
        httpReplyCursor: String? = nil
    ) {
        self.v = v
        self.cursorRowID = cursorRowID
        self.seenGUIDs = seenGUIDs
        self.sentGUIDs = sentGUIDs
        self.fingerprints = fingerprints
        self.handledReplyIDs = handledReplyIDs
        self.replyCursor = replyCursor
        self.httpReplyCursor = httpReplyCursor
        self.haltedChatIDs = haltedChatIDs
        self.rateEvents = rateEvents
        self.routes = routes
        self.pendingSends = pendingSends
        self.partialReplies = partialReplies
        self.knownChats = knownChats
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decodeIfPresent(Int.self, forKey: .v) ?? 1
        cursorRowID = try container.decodeIfPresent(Int64.self, forKey: .cursorRowID) ?? 0
        seenGUIDs = try container.decodeIfPresent([String].self, forKey: .seenGUIDs) ?? []
        sentGUIDs = try container.decodeIfPresent([String].self, forKey: .sentGUIDs) ?? []
        fingerprints = try container.decodeIfPresent([SentFingerprint].self, forKey: .fingerprints) ?? []
        handledReplyIDs = try container.decodeIfPresent([String].self, forKey: .handledReplyIDs) ?? []
        replyCursor = try container.decodeIfPresent(String.self, forKey: .replyCursor)
        httpReplyCursor = try container.decodeIfPresent(String.self, forKey: .httpReplyCursor)
        haltedChatIDs = try container.decodeIfPresent([Int64].self, forKey: .haltedChatIDs) ?? []
        rateEvents = try container.decodeIfPresent([RateEvent].self, forKey: .rateEvents) ?? []
        routes = try container.decodeIfPresent([MessageRoute].self, forKey: .routes) ?? []
        pendingSends = try container.decodeIfPresent([PendingSend].self, forKey: .pendingSends) ?? []
        partialReplies = try container.decodeIfPresent([PartialReply].self, forKey: .partialReplies) ?? []
        knownChats = try container.decodeIfPresent([ChatIdentity].self, forKey: .knownChats) ?? []
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
    var shouldFailDeadLetter = false

    init(state: PersistedState = .empty) {
        self.state = state
    }

    func load() throws -> PersistedState { state }

    func save(_ state: PersistedState) throws {
        if shouldFailSave { throw StateError.corrupt }
        self.state = state
    }

    func appendDeadLetter(_ entry: DeadLetterEntry) throws {
        if shouldFailDeadLetter { throw StateError.corrupt }
        deadLetters.append(entry)
    }
}
