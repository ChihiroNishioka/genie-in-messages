import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GenieCore

final class NotionReplyTests: XCTestCase {
    private let dataSource = "11111111-1111-4111-8111-111111111111"
    private let minute = "2023-11-14T22:13:00.000Z"
    private let nextMinute = "2023-11-14T22:14:00.000Z"

    func testSameMinuteRowsAreNotMissed() async throws {
        let clock = ManualClock()
        let script = ScriptedNotion(responses: [
            ok([
                row("a", at: minute, guid: "g-a", text: "one"),
                row("b", at: minute, guid: "g-b", text: "two"),
            ]),
            ok([
                row("a", at: minute, guid: "g-a", text: "one"),
                row("b", at: minute, guid: "g-b", text: "two"),
                row("c", at: minute, guid: "g-c", text: "three"),
            ]),
        ])
        let source = makeSource(script, clock: clock)
        let first = try await source.fetch(cursor: nil)
        XCTAssertEqual(first.replies.map(\.id), ["a", "b"])
        let second = try await source.fetch(cursor: first.nextCursor)
        XCTAssertEqual(second.replies.map(\.id), ["c"])
        let filter = try JSONSerialization.jsonObject(with: script.bodies[1]) as? [String: Any]
        let created = ((filter?["filter"] as? [String: Any])?["created_time"] as? [String: Any])?["on_or_after"] as? String
        XCTAssertEqual(created, minute)
        XCTAssertFalse(script.bodies.contains { String(data: $0, encoding: .utf8)?.contains("notion-token-value") == true })
    }

    func testLaterMinuteDoesNotHideASameMinuteRow() async throws {
        let script = ScriptedNotion(responses: [
            ok([
                row("a", at: minute, guid: "g-a", text: "one"),
                row("c", at: nextMinute, guid: "g-c", text: "three"),
            ]),
            ok([
                row("a", at: minute, guid: "g-a", text: "one"),
                row("b", at: minute, guid: "g-b", text: "two"),
                row("c", at: nextMinute, guid: "g-c", text: "three"),
            ]),
        ])
        let source = makeSource(script, clock: ManualClock())
        let first = try await source.fetch(cursor: nil)
        XCTAssertEqual(first.replies.map(\.id), ["a", "c"])
        let second = try await source.fetch(cursor: first.nextCursor)
        XCTAssertEqual(second.replies.map(\.id), ["b"])
    }

    func testPagingFollowsTheNextCursor() async throws {
        let clock = ManualClock()
        let script = ScriptedNotion(responses: [
            ok([row("a", at: minute, guid: "g-a", text: "one")], hasMore: true, next: "page-2"),
            ok([row("b", at: minute, guid: "g-b", text: "two")]),
        ])
        let source = makeSource(script, clock: clock)
        let page = try await source.fetch(cursor: nil)
        XCTAssertEqual(page.replies.map(\.id), ["a", "b"])
        XCTAssertEqual(script.requests.count, 2)
        let second = try JSONSerialization.jsonObject(with: script.bodies[1]) as? [String: Any]
        XCTAssertEqual(second?["start_cursor"] as? String, "page-2")
        XCTAssertGreaterThanOrEqual(clock.slept.first ?? 0, 0.3)
        XCTAssertEqual(script.requests[0].value(forHTTPHeaderField: "Notion-Version"), "2026-03-11")
        XCTAssertEqual(script.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer notion-token-value")
        XCTAssertTrue(script.requests[0].url?.absoluteString.contains(dataSource) == true)
    }

    func testRetryAfterIsHonored() async throws {
        let clock = ManualClock()
        let script = ScriptedNotion(responses: [
            NotionHTTPResponse(status: 429, headers: ["retry-after": "2"], body: Data("{}".utf8)),
            ok([row("a", at: minute, guid: "g-a", text: "one")]),
        ])
        let source = makeSource(script, clock: clock)
        let page = try await source.fetch(cursor: nil)
        XCTAssertEqual(page.replies.map(\.id), ["a"])
        XCTAssertEqual(clock.slept, [2])
        XCTAssertEqual(script.requests.count, 2)
    }

    func testMissingRequiredFieldIsNotDelivered() async throws {
        let script = ScriptedNotion(responses: [
            ok([row("a", at: minute, guid: nil, text: "SECRET_REPLY")]),
            ok([row("a", at: minute, guid: nil, text: "SECRET_REPLY")]),
        ])
        let source = makeSource(script, clock: ManualClock())
        let first = try await source.fetch(cursor: nil)
        XCTAssertTrue(first.replies.isEmpty)
        XCTAssertGreaterThan(first.skipped, 0)
        let second = try await source.fetch(cursor: first.nextCursor)
        XCTAssertTrue(second.replies.isEmpty)
        XCTAssertEqual(second.skipped, 0)
    }

    func testUnroutedGuidIsNotSentAndTheSameReplyIsNotSentTwice() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.notionDataSourceID = dataSource
        harness.config.replyFetchURL = ""
        harness.secrets = StaticSecret(webhook: "hook-secret", reply: nil, notion: "notion-token-value")
        seedRoute(harness, guid: "origin", chat: 1)
        let created = "2023-11-14T22:13:20Z"
        let script = ScriptedNotion(responses: [
            ok([row("r1", at: created, guid: "missing", text: "SECRET_REPLY", chat: 1)]),
            ok([row("r1", at: created, guid: "missing", text: "SECRET_REPLY", chat: 1)]),
            ok([row("r2", at: created, guid: "origin", text: "SECRET_REPLY", chat: 1)]),
            ok([row("r2", at: created, guid: "origin", text: "SECRET_REPLY", chat: 1)]),
            ok([row("r3", at: created, guid: "origin", text: "SECRET_REPLY", chat: 9)]),
        ])
        let source = makeSource(script, clock: harness.clock)
        let engine = try GenieEngine(
            configProvider: StaticConfig(config: harness.config),
            initialConfig: harness.config,
            stateStore: harness.state,
            allowlistStore: harness.allow,
            replySource: source,
            sender: harness.sender,
            webhook: harness.webhook,
            secrets: harness.secrets,
            lock: harness.lock,
            clock: harness.clock,
            log: harness.log
        )
        await engine.pollReplies()
        XCTAssertTrue(harness.sender.sent.isEmpty)
        XCTAssertTrue(harness.log.records.contains { $0.code == "reply_unrouted" })
        await engine.pollReplies()
        XCTAssertTrue(harness.sender.sent.isEmpty)

        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 1)
        XCTAssertEqual(harness.sender.sent[0].chatID, 1)
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 1)

        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 1)
        XCTAssertTrue(harness.log.records.contains { $0.code == "reply_chat_mismatch" })
        assertNoBody(harness, "SECRET_REPLY")
        let rendered = harness.log.records.map(\.code).joined(separator: " ")
        XCTAssertFalse(rendered.contains("notion-token-value"))
    }

    func testNotionTokenFileIsMode600AndNotShown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = ConfigPaths(root: root, logFile: root.appendingPathComponent("genie.log"))
        try NotionToken.save("  notion-token-value \n", to: paths.notionTokenFile)
        XCTAssertEqual(try FilePermissions.mode(of: paths.root), 0o700)
        XCTAssertEqual(try FilePermissions.mode(of: paths.notionTokenFile), 0o600)
        XCTAssertEqual(try FileSecretProvider(paths: paths).notionToken(), "notion-token-value")
        XCTAssertEqual(NotionToken.status(at: paths.notionTokenFile), .configured)
        XCTAssertEqual(NotionToken.statusLabel(.configured), "設定済み")
        XCTAssertFalse(NotionToken.statusLabel(.configured).contains("notion-token-value"))
        try FilePermissions.set(paths.notionTokenFile, mode: 0o640)
        XCTAssertEqual(NotionToken.status(at: paths.notionTokenFile), .insecure)
        XCTAssertThrowsError(try FileSecretProvider(paths: paths).notionToken()) { error in
            XCTAssertEqual(error as? SecretReadError, .insecureMode)
        }
    }

    func testRealDatabaseIDsAreNotInSource() throws {
        let root = repoRoot().appendingPathComponent("Sources")
        let banned = [
            "875a3b9a-fa64-4631-88cf-1328c2bef05f",
            "1a7710fa-96a4-4fb3-9fa7-8c7eb2337513",
        ]
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        for file in files where file.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for id in banned {
                XCTAssertFalse(text.contains(id), file)
            }
        }
    }

    private func makeSource(_ script: ScriptedNotion, clock: ManualClock) -> NotionReplySource {
        NotionReplySource(
            dataSourceID: dataSource,
            secrets: StaticSecret(webhook: "hook-secret", reply: nil, notion: "notion-token-value"),
            clock: clock,
            pageLimit: 100,
            transport: script
        )
    }

    private func ok(_ rows: [[String: Any]], hasMore: Bool = false, next: String? = nil) -> NotionHTTPResponse {
        var object: [String: Any] = [
            "object": "list",
            "results": rows,
            "has_more": hasMore,
        ]
        if let next {
            object["next_cursor"] = next
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return NotionHTTPResponse(status: 200, headers: [:], body: data)
    }

    private func row(
        _ id: String,
        at created: String,
        guid: String?,
        text: String?,
        chat: Int? = 1
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "reply_id": ["type": "title", "title": [["plain_text": id]]],
            "created_at": ["type": "created_time", "created_time": created],
        ]
        if let chat {
            properties["chat_id"] = ["type": "number", "number": chat]
        }
        if let guid {
            properties["in_reply_to_guid"] = ["type": "rich_text", "rich_text": [["plain_text": guid]]]
        }
        if let text {
            properties["text"] = ["type": "rich_text", "rich_text": [["plain_text": text]]]
        }
        return [
            "object": "page",
            "id": "page-\(id)",
            "created_time": created,
            "properties": properties,
        ]
    }
}

final class ScriptedNotion: NotionTransport, @unchecked Sendable {
    var responses: [NotionHTTPResponse]
    var requests: [URLRequest] = []
    var bodies: [Data] { requests.compactMap(\.httpBody) }

    init(responses: [NotionHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> NotionHTTPResponse {
        requests.append(request)
        if responses.isEmpty { throw ReplyFetchError.transport }
        return responses.removeFirst()
    }
}
