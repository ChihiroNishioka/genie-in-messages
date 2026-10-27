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
    func state() async -> ScreenLockState {
        if let forced { return forced }
        return locked ? .locked : .unlocked
    }
}

final class ScriptedReplies: ReplySource, @unchecked Sendable {
    var pages: [ReplyPage] = []
    func fetch(
        cursor: String?,
        skipping handledReplyIDs: Set<String> = [],
        holding replyIDs: Set<String> = []
    ) async throws -> ReplyPage {
        _ = handledReplyIDs
        _ = replyIDs
        if pages.isEmpty {
            return ReplyPage(replies: [], nextCursor: cursor)
        }
        return pages.removeFirst()
    }
}

final class Harness {
    let clock = ManualClock()
    let webhook = FakeWebhook()
    let sender = FakeSender()
    let lock = FakeLock()
    let log = MemoryLog()
    let state = MemoryStateStore()
    let allow = MemoryAllowlist()
    let replies = ScriptedReplies()
    var secrets: any SecretProviding = StaticSecret(webhook: "hook-secret", reply: nil)
    var config = GenieConfig.productDefaults

    func engine() throws -> GenieEngine {
        var cfg = config
        if cfg.webhookURL.isEmpty {
            cfg.webhookURL = "https://127.0.0.1/webhook"
        }
        return try GenieEngine(
            configProvider: StaticConfig(config: cfg),
            initialConfig: cfg,
            stateStore: state,
            allowlistStore: allow,
            replySource: replies,
            sender: sender,
            webhook: webhook,
            secrets: secrets,
            lock: lock,
            clock: clock,
            log: log
        )
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
    let codes = harness.log.records.map(\.code).joined(separator: "\n")
    let letters = harness.state.deadLetters.map { "\($0.error) \($0.guid ?? "") \($0.kind)" }.joined(separator: "\n")
    XCTAssertFalse(codes.contains(body), file: file, line: line)
    XCTAssertFalse(letters.contains(body), file: file, line: line)
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

func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
