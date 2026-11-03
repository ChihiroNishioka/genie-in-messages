import Foundation
import XCTest
@testable import GenieCore

final class ManualClock: GenieClock, @unchecked Sendable {
    var current: Date
    var slept: [Double] = []
    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = date
    }
    func now() -> Date { current }
    var onSleep: (() async -> Void)?
    func sleep(seconds: Double) async throws {
        slept.append(seconds)
        current = current.addingTimeInterval(seconds)
        await onSleep?()
        try Task.checkCancellation()
    }
}

final class FakeWebhook: WebhookPosting, @unchecked Sendable {
    var results: [Result<WebhookHTTPResult, Error>] = []
    var secrets: [String] = []
    var bodies: [Data] = []
    func post(url: URL, secret: String, body: Data, idempotencyKey: String) async throws -> WebhookHTTPResult {
        secrets.append(secret)
        bodies.append(body)
        if results.isEmpty {
            return WebhookHTTPResult(statusCode: 200)
        }
        return try results.removeFirst().get()
    }
}

final class FakeSender: MessageSending, @unchecked Sendable {
    var script: [Result<SendReceipt, SendFailure>] = []
    var sent: [(chatID: Int64, text: String)] = []
    var onSend: (() async -> Void)?
    func send(chatID: Int64, text: String) async throws -> SendReceipt {
        sent.append((chatID, text))
        await onSend?()
        if script.isEmpty {
            return SendReceipt(id: Int64(sent.count), guid: "sent-\(sent.count)", status: "sent")
        }
        return try script.removeFirst().get()
    }
}

final class FakeLock: ScreenLockChecking, @unchecked Sendable {
    var locked = false
    var forced: ScreenLockState?
    var onState: (() async -> Void)?
    func state() async -> ScreenLockState {
        await onState?()
        if let forced { return forced }
        return locked ? .locked : .unlocked
    }
}

struct ScriptedFetchFailure: Error {}

final class ScriptedReplies: ReplySource, @unchecked Sendable {
    var pages: [ReplyPage] = []
    var onFetch: (() async -> Void)?
    var failNext = false
    func fetch(
        cursor: String?,
        skipping handledReplyIDs: Set<String> = [],
        holding replyIDs: Set<String> = []
    ) async throws -> ReplyPage {
        _ = handledReplyIDs
        _ = replyIDs
        await onFetch?()
        if failNext {
            failNext = false
            throw ScriptedFetchFailure()
        }
        if pages.isEmpty {
            return ReplyPage(replies: [], nextCursor: cursor)
        }
        return pages.removeFirst()
    }
}

final class Harness {
    let clock = ManualClock()
    let stop = StopSignal()
    let webhook = FakeWebhook()
    let sender = FakeSender()
    let lock = FakeLock()
    let log = MemoryLog()
    let state = MemoryStateStore()
    var store: (any StatePersisting)?
    let allow = MemoryAllowlist()
    let replies = ScriptedReplies()
    var secrets: any SecretProviding = StaticSecret(webhook: "hook-secret", reply: nil)
    var config = GenieConfig.productDefaults

    func engine() throws -> GenieEngine {
        try engine(stop: stop)
    }

    func engine(stop signal: StopSignal) throws -> GenieEngine {
        var cfg = config
        if cfg.webhookURL.isEmpty {
            cfg.webhookURL = "https://127.0.0.1/webhook"
        }
        return try makeEngine(config: cfg, stop: signal)
    }

    /// 許可中の各トークを、保存してある guid で照合済みにしたエンジン。
    /// 送信を試す既存テストはこちらを使う。
    func opened() async throws -> GenieEngine {
        let created = try engine()
        await created.showChats(verifiedChatList())
        return created
    }

    func verifiedChatList() -> [ChatSummary] {
        allow.ids.sorted().map { id in
            let stored = allow.guids[id] ?? ""
            return ChatSummary(
                id: id,
                title: "room",
                isGroup: false,
                guid: stored.isEmpty ? "verified-\(id)" : stored
            )
        }
    }

    private func makeEngine(config cfg: GenieConfig, stop signal: StopSignal) throws -> GenieEngine {
        try GenieEngine(
            configProvider: StaticConfig(config: cfg),
            initialConfig: cfg,
            stateStore: store ?? state,
            allowlistStore: allow,
            replySource: replies,
            sender: sender,
            webhook: webhook,
            secrets: secrets,
            lock: lock,
            clock: clock,
            log: log,
            stop: signal
        )
    }
}

final class RecordingStateStore: StatePersisting, @unchecked Sendable {
    let memory: MemoryStateStore
    private(set) var saves: [PersistedState] = []

    init(state: PersistedState = .empty) {
        memory = MemoryStateStore(state: state)
    }

    func load() throws -> PersistedState { try memory.load() }

    func save(_ state: PersistedState) throws {
        try memory.save(state)
        saves.append(state)
    }

    func appendDeadLetter(_ entry: DeadLetterEntry) throws {
        try memory.appendDeadLetter(entry)
    }
}

func watchLine(
    id: Int,
    guid: String,
    chat: Int,
    fromMe: Bool,
    text: String,
    created: String = "2026-10-26T01:00:00Z",
    type: String? = nil,
    reaction: Bool = false,
    chatGUID: String? = nil,
    sender: String? = nil,
    isGroup: Bool? = nil,
    participants: [String]? = nil,
    attachments: Bool = false,
    contactName: String? = nil,
    chatIdentifier: String? = nil,
    destinationCallerID: String? = nil
) -> String {
    var object: [String: Any] = [
        "id": id,
        "guid": guid,
        "chat_id": chat,
        "is_from_me": fromMe,
        "text": text,
        "created_at": created,
    ]
    if let chatGUID { object["chat_guid"] = chatGUID }
    if let type { object["type"] = type }
    if reaction { object["is_reaction"] = true }
    if let sender { object["sender"] = sender }
    if let isGroup { object["is_group"] = isGroup }
    if let participants { object["participants"] = participants }
    if let contactName { object["sender_name"] = contactName }
    if let chatIdentifier { object["chat_identifier"] = chatIdentifier }
    if let destinationCallerID { object["destination_caller_id"] = destinationCallerID }
    if attachments {
        object["attachments"] = [["filename": "photo.jpg", "mime_type": "image/jpeg"]]
    }
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

func decodedWebhookText(_ data: Data) throws -> String {
    struct Body: Decodable {
        var text: String
        enum CodingKeys: String, CodingKey { case text }
    }
    return try JSONDecoder().decode(Body.self, from: data).text
}

func assertNoBody(_ harness: Harness, _ body: String, file: StaticString = #filePath, line: UInt = #line) {
    let logs = harness.log.records.map {
        "\($0.ts) \($0.level) \($0.code) \($0.chatID.map(String.init) ?? "") \($0.guid ?? "") \($0.rowid.map(String.init) ?? "") \($0.detail ?? "")"
    }.joined(separator: "\n")
    let letters = harness.state.deadLetters.map {
        "\($0.ts) \($0.kind) \($0.chatID.map(String.init) ?? "") \($0.guid ?? "") \($0.rowid.map(String.init) ?? "") \($0.attempts) \($0.error)"
    }.joined(separator: "\n")
    XCTAssertFalse(logs.contains(body), file: file, line: line)
    XCTAssertFalse(letters.contains(body), file: file, line: line)
    do {
        let data = try StateCoding.encoder().encode(harness.state.state)
        let stateJSON = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(stateJSON.contains(body), file: file, line: line)
    } catch {
        XCTFail("state JSON encode failed: \(error)", file: file, line: line)
    }
}

func reloaded(_ state: PersistedState) throws -> (PersistedState, String) {
    let data = try StateCoding.encoder().encode(state)
    let decoded = try StateCoding.decoder().decode(PersistedState.self, from: data)
    let json = String(data: data, encoding: .utf8) ?? ""
    return (decoded, json)
}

func seedRoute(_ harness: Harness, guid: String, chat: Int64) {
    harness.state.state.routes.append(MessageRoute(guid: guid, chatID: chat, at: harness.clock.current))
}

func routedReply(
    _ id: String,
    chat: Int64,
    text: String,
    guid: String,
    created: String = "2023-11-14T22:13:20Z"
) -> FetchedReply {
    FetchedReply(id: id, chatID: chat, text: text, inReplyToGUID: guid, createdAt: created)
}

extension GenieEngine {
    func showChats(_ chats: [ChatSummary]) async {
        _ = await applyChatList(.parsed(ChatListParse(chats: chats, failedLineCount: 0)))
    }
}

final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let pending: [CheckedContinuation<Void, Never>]
        lock.lock()
        opened = true
        pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        lock.lock()
        if opened {
            lock.unlock()
            return
        }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            waiters.append(waiter)
            lock.unlock()
        }
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ name: String) {
        lock.lock()
        events.append(name)
        lock.unlock()
    }
    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

final class MutableConfig: ConfigProviding, @unchecked Sendable {
    var config: GenieConfig
    var onLoad: (() -> Void)?
    init(_ config: GenieConfig) { self.config = config }
    func load() throws -> GenieConfig {
        onLoad?()
        return config.sanitized()
    }
}

final class RecordingProbe: PollerProbe, @unchecked Sendable {
    let log: EventLog
    var gates: [String: Gate] = [:]
    var arrived: [String: Gate] = [:]
    init(log: EventLog) { self.log = log }
    func chatsReadReturned() async {
        log.append("chatsReadReturned")
        arrived["chatsReadReturned"]?.open()
        if let gate = gates["chatsReadReturned"] { await gate.wait() }
    }
    func chatsApplied() async {
        log.append("chatsApplied")
        arrived["chatsApplied"]?.open()
        if let gate = gates["chatsApplied"] { await gate.wait() }
    }
    func initialWaitRegistered() async {
        log.append("initialWaitRegistered")
        arrived["initialWaitRegistered"]?.open()
        if let gate = gates["initialWaitRegistered"] { await gate.wait() }
    }
}

/// 複数のタスクから読み書きする印。ロックで守る。
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool = false) { stored = value }
    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// 複数のタスクから読み書きする Task。ロックで守る。
final class TaskSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<Void, Never>?
    var task: Task<Void, Never>? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
