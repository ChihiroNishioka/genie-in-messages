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
    func sleep(seconds: Double) async throws {
        slept.append(seconds)
        current = current.addingTimeInterval(seconds)
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
    func send(chatID: Int64, text: String) async throws -> SendReceipt {
        sent.append((chatID, text))
        if script.isEmpty {
            return SendReceipt(id: Int64(sent.count), guid: "sent-\(sent.count)", status: "sent")
        }
        return try script.removeFirst().get()
    }
}

final class FakeLock: ScreenLockChecking, @unchecked Sendable {
    var locked = false
    func isLocked() async -> Bool { locked }
}

final class ScriptedReplies: ReplySource, @unchecked Sendable {
    var pages: [ReplyPage] = []
    func fetch(cursor: String?) async throws -> ReplyPage {
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
            cfg.webhookURL = "http://127.0.0.1/webhook"
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
    reaction: Bool = false
) -> String {
    var object: [String: Any] = [
        "id": id,
        "guid": guid,
        "chat_id": chat,
        "is_from_me": fromMe,
        "text": text,
        "created_at": created,
    ]
    if let type { object["type"] = type }
    if reaction { object["is_reaction"] = true }
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

func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
