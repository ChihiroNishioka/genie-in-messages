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
        await engine.showChats(harness.verifiedChatList())
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

    func testFreshStateReadsFromNowAndSkipsALongBacklog() async throws {
        let clock = ManualClock()
        let start = NotionCursor.freshStart(now: clock.now())
        var rows: [[String: Any]] = []
        for index in 0..<150 {
            let at = ISO8601.string(from: clock.now().addingTimeInterval(Double(-150 + index) * 60))
            rows.append(row("old-\(index)", at: at, guid: "g", text: "old"))
        }
        rows.append(row("new", at: ISO8601.string(from: clock.now()), guid: "g", text: "new"))
        let script = ScriptedNotion(responses: [ok(rows), ok(rows), ok(rows), ok(rows)])
        let source = makeSource(script, clock: clock)
        var seen: [String] = []
        var cursor: String?
        for _ in 0..<4 {
            let page = try await source.fetch(cursor: cursor)
            seen.append(contentsOf: page.replies.map(\.id))
            cursor = page.nextCursor
        }
        XCTAssertEqual(seen, ["new"])
        XCTAssertFalse(seen.contains("old-0"))
        let filter = try JSONSerialization.jsonObject(with: script.bodies[0]) as? [String: Any]
        let created = ((filter?["filter"] as? [String: Any])?["created_time"] as? [String: Any])?["on_or_after"] as? String
        XCTAssertEqual(created, start)
    }

    func testManyRowsInTheSameMinutesDoNotStall() async throws {
        let clock = ManualClock()
        let origin = ISO8601.date(from: NotionCursor.freshStart(now: clock.now())) ?? clock.now()
        var rows: [[String: Any]] = []
        for minuteIndex in 0..<50 {
            let at = ISO8601.string(from: origin.addingTimeInterval(Double(minuteIndex) * 60))
            for copy in 0..<3 {
                rows.append(row(String(format: "m%02d-%d", minuteIndex, copy), at: at, guid: "g", text: "x"))
            }
        }
        let script = ScriptedNotion(responses: [ok(rows), ok(rows), ok(rows), ok(rows)])
        let source = makeSource(script, clock: clock)
        var seen: [String] = []
        var cursor: String?
        for _ in 0..<4 {
            let page = try await source.fetch(cursor: cursor)
            seen.append(contentsOf: page.replies.map(\.id))
            cursor = page.nextCursor
        }
        XCTAssertTrue(seen.contains("m49-2"))
        XCTAssertEqual(seen.count, 150)
    }

    func testLateRowInAnEarlierMinuteIsStillRead() async throws {
        let t0 = "2023-11-14T22:13:00.000Z"
        let t1 = "2023-11-14T22:13:40.000Z"
        let t2 = "2023-11-14T22:14:20.000Z"
        let script = ScriptedNotion(responses: [
            ok([
                row("a", at: t0, guid: "ga", text: "one"),
                row("b", at: t1, guid: "gb", text: "two"),
            ]),
            ok([
                row("a", at: t0, guid: "ga", text: "one"),
                row("b", at: t1, guid: "gb", text: "two"),
                row("c", at: t2, guid: "gc", text: "three"),
            ]),
            ok([
                row("a", at: t0, guid: "ga", text: "one"),
                row("b", at: t1, guid: "gb", text: "two"),
                row("d", at: t1, guid: "gd", text: "late"),
                row("c", at: t2, guid: "gc", text: "three"),
            ]),
        ])
        let source = makeSource(script, clock: ManualClock())
        let first = try await source.fetch(cursor: nil)
        XCTAssertEqual(first.replies.map(\.id), ["a", "b"])
        let second = try await source.fetch(cursor: first.nextCursor)
        XCTAssertEqual(second.replies.map(\.id), ["c"])
        let third = try await source.fetch(cursor: second.nextCursor)
        XCTAssertEqual(third.replies.map(\.id), ["d"])
    }

    func testHandledRowsDoNotConsumeThePage() async throws {
        var rows: [[String: Any]] = []
        for index in 0..<100 {
            rows.append(row("h\(index)", at: minute, guid: "g", text: "x"))
        }
        rows.append(row("fresh", at: minute, guid: "g", text: "x"))
        let script = ScriptedNotion(responses: [ok(rows)])
        let source = makeSource(script, clock: ManualClock())
        let page = try await source.fetch(cursor: nil, skipping: Set((0..<100).map { "h\($0)" }))
        XCTAssertEqual(page.replies.map(\.id), ["fresh"])
    }

    func testRestartRereadsALateRowAndDoesNotResend() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.notionDataSourceID = dataSource
        harness.config.replyFetchURL = ""
        for guid in ["ga", "gb", "gc", "gd"] {
            seedRoute(harness, guid: guid, chat: 1)
        }
        let t0 = "2023-11-14T22:13:00.000Z"
        let t1 = "2023-11-14T22:13:40.000Z"
        let t2 = "2023-11-14T22:14:20.000Z"
        let dataset = DatasetNotion(rows: [
            row("a", at: t0, guid: "ga", text: "one"),
            row("b", at: t1, guid: "gb", text: "two"),
        ])
        let source = makeSource(dataset, clock: harness.clock)
        let engine = try await makeEngine(harness, source: source)
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 2)
        dataset.rows.append(row("c", at: t2, guid: "gc", text: "three"))
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 3)
        dataset.rows.append(row("d", at: t1, guid: "gd", text: "late"))
        let restarted = try await makeEngine(harness, source: source)
        await restarted.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 4)
        XCTAssertEqual(harness.sender.sent.filter { $0.text.contains("late") }.count, 1)
        await restarted.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 4)
        XCTAssertEqual(harness.sender.sent.filter { $0.text.contains("one") }.count, 1)
    }

    func testFifthRateLimitStillWaitsAndOverloadIsRetried() async throws {
        let clock = ManualClock()
        let limited = NotionHTTPResponse(status: 429, headers: ["retry-after": "2"], body: Data("{}".utf8))
        let script = ScriptedNotion(responses: Array(repeating: limited, count: 5))
        let source = makeSource(script, clock: clock)
        do {
            _ = try await source.fetch(cursor: nil)
            XCTFail("expected transport")
        } catch ReplyFetchError.transport {
        }
        XCTAssertEqual(script.requests.count, 5)
        XCTAssertEqual(clock.slept, [2, 2, 2, 2, 2])

        let again = ManualClock()
        let overload = ScriptedNotion(responses: [
            NotionHTTPResponse(status: 529, headers: ["retry-after": "1"], body: Data()),
            NotionHTTPResponse(status: 503, headers: [:], body: Data()),
            ok([row("a", at: minute, guid: "g-a", text: "one")]),
        ])
        let retried = makeSource(overload, clock: again)
        let page = try await retried.fetch(cursor: nil)
        XCTAssertEqual(page.replies.map(\.id), ["a"])
        XCTAssertEqual(overload.requests.count, 3)
        XCTAssertEqual(again.slept.first, 1)
    }

    func testChatIDKeepsIntegersPastTheFloatMantissa() async throws {
        let raw = """
        {"object":"list","results":[{"object":"page","id":"page-big","created_time":"2023-11-14T22:13:00.000Z","properties":{"reply_id":{"title":[{"plain_text":"big"}]},"created_at":{"created_time":"2023-11-14T22:13:00.000Z"},"chat_id":{"number":9007199254740993},"in_reply_to_guid":{"rich_text":[{"plain_text":"g"}]},"text":{"rich_text":[{"plain_text":"hi"}]}}},{"object":"page","id":"page-frac","created_time":"2023-11-14T22:13:00.000Z","properties":{"reply_id":{"title":[{"plain_text":"frac"}]},"created_at":{"created_time":"2023-11-14T22:13:00.000Z"},"chat_id":{"number":1.5},"in_reply_to_guid":{"rich_text":[{"plain_text":"g"}]},"text":{"rich_text":[{"plain_text":"hi"}]}}}],"has_more":false}
        """
        let script = ScriptedNotion(responses: [
            NotionHTTPResponse(status: 200, headers: [:], body: Data(raw.utf8)),
        ])
        let page = try await makeSource(script, clock: ManualClock()).fetch(cursor: nil)
        XCTAssertEqual(page.replies.map(\.id), ["big"])
        XCTAssertEqual(page.replies.first?.chatID, 9_007_199_254_740_993)
        XCTAssertGreaterThan(page.skipped, 0)
    }

    func testHeldRepliesDoNotBlockAnotherChat() async throws {
        let harness = Harness()
        harness.allow.ids = [1, 2]
        harness.config.notionDataSourceID = dataSource
        harness.config.replyFetchURL = ""
        harness.config.rateLimitCount = 1
        harness.config.rateLimitWindowSeconds = 3600
        let origin = ISO8601.date(from: NotionCursor.freshStart(now: harness.clock.now())) ?? harness.clock.now()
        var rows: [[String: Any]] = []
        for index in 0..<101 {
            let id = String(format: "h%03d", index)
            let guid = String(format: "g%03d", index)
            let at = ISO8601.string(from: origin.addingTimeInterval(Double(index)))
            seedRoute(harness, guid: guid, chat: 1)
            rows.append(row(id, at: at, guid: guid, text: "held", chat: 1))
        }
        let otherAt = ISO8601.string(from: origin.addingTimeInterval(300))
        seedRoute(harness, guid: "g-other", chat: 2)
        rows.append(row("other", at: otherAt, guid: "g-other", text: "other-chat", chat: 2))
        let dataset = DatasetNotion(rows: rows)
        let engine = try await makeEngine(harness, source: makeSource(dataset, clock: harness.clock))
        await engine.pollReplies()
        await engine.pollReplies()
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.filter { $0.chatID == 2 }.count, 1)
        XCTAssertEqual(harness.sender.sent.filter { $0.chatID == 1 }.count, 1)
        XCTAssertTrue(harness.sender.sent.contains { $0.chatID == 2 && $0.text.contains("other-chat") })
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.heldCount, 100)
    }

    func testTwoHundredOneHoldsDoNotBlockAnotherChat() async throws {
        let (harness, dataset, engine, origin) = try await makeRateLimitedHolds(count: 202)
        for _ in 0..<3 {
            await engine.pollReplies()
        }
        var snap = await engine.snapshot()
        XCTAssertEqual(snap.heldCount, 201)
        XCTAssertEqual(harness.sender.sent.filter { $0.chatID == 1 }.count, 1)
        XCTAssertTrue(harness.sender.sent.filter { $0.chatID == 2 }.isEmpty)

        let otherAt = ISO8601.string(from: origin.addingTimeInterval(400))
        dataset.rows.append(row("other", at: otherAt, guid: "g-other", text: "other-chat", chat: 2))
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.filter { $0.chatID == 2 }.count, 1)
        XCTAssertEqual(harness.sender.sent.filter { $0.chatID == 1 }.count, 1)
        XCTAssertEqual(harness.sender.sent.filter { $0.text.contains("other-chat") }.count, 1)
        snap = await engine.snapshot()
        XCTAssertEqual(snap.heldCount, 201)
    }

    func testRestartRebuildsHoldsWithoutResending() async throws {
        let (harness, dataset, engine, origin) = try await makeRateLimitedHolds(count: 202)
        for _ in 0..<3 {
            await engine.pollReplies()
        }
        let otherAt = ISO8601.string(from: origin.addingTimeInterval(400))
        dataset.rows.append(row("other", at: otherAt, guid: "g-other", text: "other-chat", chat: 2))
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.filter { $0.chatID == 2 }.count, 1)
        XCTAssertEqual(harness.sender.sent.filter { $0.chatID == 1 }.count, 1)
        // チャット1の停止は残り、チャット2の回数だけ窓の外に出す。
        harness.clock.current = harness.clock.now().addingTimeInterval(harness.config.rateLimitWindowSeconds + 1)

        let againAt = ISO8601.string(from: origin.addingTimeInterval(500))
        dataset.rows.append(row("again", at: againAt, guid: "g-again", text: "other-again", chat: 2))
        let restarted = try await makeEngine(harness, source: makeSource(dataset, clock: harness.clock))
        await restarted.pollReplies()
        XCTAssertEqual(harness.sender.sent.filter { $0.chatID == 2 }.count, 1)
        XCTAssertEqual(harness.sender.sent.filter { $0.chatID == 1 }.count, 1)
        var snap = await restarted.snapshot()
        XCTAssertEqual(snap.heldCount, 100)

        await restarted.pollReplies()
        await restarted.pollReplies()
        XCTAssertEqual(harness.sender.sent.filter { $0.chatID == 1 }.count, 1)
        XCTAssertEqual(harness.sender.sent.filter { $0.text.contains("other-chat") }.count, 1)
        XCTAssertEqual(harness.sender.sent.filter { $0.text.contains("other-again") }.count, 1)
        snap = await restarted.snapshot()
        XCTAssertEqual(snap.heldCount, 201)
    }

    func testFetchKeepsTheMinuteItStartedIn() async throws {
        let clock = ManualClock(ISO8601.date(from: "2023-11-14T22:13:50.000Z") ?? Date(timeIntervalSince1970: 1_700_000_030))
        let script = ScriptedNotion(responses: [
            ok([row("edge", at: minute, guid: "g", text: "kept")]),
        ])
        script.onSend = { clock.current = clock.current.addingTimeInterval(30) }
        let page = try await makeSource(script, clock: clock).fetch(cursor: nil)
        XCTAssertEqual(page.replies.map(\.id), ["edge"])
        XCTAssertEqual(NotionCursor.decode(page.nextCursor)?.notBefore, minute)
    }

    func testPagingUsesTheNextCursorAndStopsAtTwentyPages() async throws {
        var rows: [[String: Any]] = []
        for index in 0..<100 {
            rows.append(row(String(format: "p%03d", index), at: minute, guid: "g", text: "x"))
        }
        rows.append(row("tail", at: minute, guid: "g", text: "x"))
        let dataset = DatasetNotion(rows: rows)
        let page = try await makeSource(dataset, clock: ManualClock()).fetch(
            cursor: nil,
            skipping: Set((0..<100).map { String(format: "p%03d", $0) })
        )
        XCTAssertEqual(page.replies.map(\.id), ["tail"])
        XCTAssertEqual(dataset.requests.count, 2)
        let second = try JSONSerialization.jsonObject(with: dataset.requests[1].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(second?["start_cursor"] as? String, "100")

        var many: [[String: Any]] = []
        for index in 0..<2000 {
            many.append(row(String(format: "q%04d", index), at: minute, guid: "g", text: "x"))
        }
        many.append(row("beyond", at: minute, guid: "g", text: "x"))
        let wide = DatasetNotion(rows: many)
        let stopped = try await makeSource(wide, clock: ManualClock()).fetch(
            cursor: nil,
            skipping: Set((0..<2000).map { String(format: "q%04d", $0) })
        )
        XCTAssertFalse(stopped.replies.map(\.id).contains("beyond"))
        XCTAssertEqual(wide.requests.count, NotionAPI.maxPages)
    }

    func testLegacyCursorKeepsTheLookback() async throws {
        let legacy = #"{"created_at":"2023-11-14T22:13:00.000Z","reply_ids":["seen"]}"#
        var rows: [[String: Any]] = [
            row("early", at: "2023-11-14T22:11:30.000Z", guid: "g", text: "x"),
            row("seen", at: minute, guid: "g", text: "x"),
        ]
        for index in 0..<100 {
            rows.append(row(String(format: "n%03d", index), at: minute, guid: "g", text: "x"))
        }
        let page = try await makeSource(
            ScriptedNotion(responses: [ok(rows)]),
            clock: ManualClock()
        ).fetch(cursor: legacy)
        XCTAssertTrue(page.replies.map(\.id).contains("early"))
        XCTAssertNil(NotionCursor.decode(page.nextCursor)?.notBefore)
    }

    func testChatIDDoesNotBorrowTheNextRowsNumber() async throws {
        let raw = """
        {"object":"list","results":[{"object":"page","id":"page-text","created_time":"2023-11-14T22:13:00.000Z","properties":{"reply_id":{"title":[{"plain_text":"texty"}]},"created_at":{"created_time":"2023-11-14T22:13:00.000Z"},"chat_id":{"type":"rich_text","rich_text":[{"plain_text":"nope"}]},"in_reply_to_guid":{"rich_text":[{"plain_text":"g"}]},"text":{"rich_text":[{"plain_text":"hi"}]}}},{"object":"page","id":"page-big","created_time":"2023-11-14T22:13:00.000Z","properties":{"reply_id":{"title":[{"plain_text":"big"}]},"created_at":{"created_time":"2023-11-14T22:13:00.000Z"},"chat_id":{"number":9007199254740993},"in_reply_to_guid":{"rich_text":[{"plain_text":"g"}]},"text":{"rich_text":[{"plain_text":"hi"}]}}}],"has_more":false}
        """
        let script = ScriptedNotion(responses: [
            NotionHTTPResponse(status: 200, headers: [:], body: Data(raw.utf8)),
        ])
        let page = try await makeSource(script, clock: ManualClock()).fetch(cursor: nil)
        XCTAssertEqual(page.replies.map(\.id), ["big"])
        XCTAssertEqual(page.replies.first?.chatID, 9_007_199_254_740_993)
        XCTAssertGreaterThan(page.skipped, 0)
    }

    func testPersonalIdentifiersStayOutOfDocsAndTests() throws {
        let script = repoRoot().appendingPathComponent("scripts/check-tracked-text.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        process.currentDirectoryURL = repoRoot()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
    }

    private func makeRateLimitedHolds(
        count: Int
    ) async throws -> (Harness, DatasetNotion, GenieEngine, Date) {
        let harness = Harness()
        harness.allow.ids = [1, 2]
        harness.config.notionDataSourceID = dataSource
        harness.config.replyFetchURL = ""
        harness.config.rateLimitCount = 1
        harness.config.rateLimitWindowSeconds = 3600
        let origin = ISO8601.date(from: NotionCursor.freshStart(now: harness.clock.now())) ?? harness.clock.now()
        // 経路は起動時に読み込む。あとから足すと、エンジンが保存した状態で上書きされる。
        seedRoute(harness, guid: "g-other", chat: 2)
        seedRoute(harness, guid: "g-again", chat: 2)
        var rows: [[String: Any]] = []
        for index in 0..<count {
            let id = String(format: "h%03d", index)
            let guid = String(format: "g%03d", index)
            let at = ISO8601.string(from: origin.addingTimeInterval(Double(index)))
            seedRoute(harness, guid: guid, chat: 1)
            rows.append(row(id, at: at, guid: guid, text: "held", chat: 1))
        }
        let dataset = DatasetNotion(rows: rows)
        let engine = try await makeEngine(harness, source: makeSource(dataset, clock: harness.clock))
        return (harness, dataset, engine, origin)
    }

    private func makeEngine(_ harness: Harness, source: NotionReplySource) async throws -> GenieEngine {
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
        await engine.showChats(harness.verifiedChatList())
        return engine
    }

    private func makeSource(_ transport: any NotionTransport, clock: ManualClock) -> NotionReplySource {
        NotionReplySource(
            dataSourceID: dataSource,
            secrets: StaticSecret(webhook: "hook-secret", reply: nil, notion: "notion-token-value"),
            clock: clock,
            pageLimit: 100,
            transport: transport
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

final class DatasetNotion: NotionTransport, @unchecked Sendable {
    var rows: [[String: Any]]
    var requests: [URLRequest] = []

    init(rows: [[String: Any]]) {
        self.rows = rows
    }

    func send(_ request: URLRequest) async throws -> NotionHTTPResponse {
        requests.append(request)
        let object = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        let onOrAfter = ((object?["filter"] as? [String: Any])?["created_time"] as? [String: Any])?["on_or_after"] as? String
        let start = Int(object?["start_cursor"] as? String ?? "0") ?? 0
        let filtered = rows.filter { row in
            guard let onOrAfter else { return true }
            return ((row["created_time"] as? String) ?? "") >= onOrAfter
        }
        let slice = Array(filtered.dropFirst(start).prefix(100))
        let next = start + slice.count
        var payload: [String: Any] = [
            "object": "list",
            "results": slice,
            "has_more": next < filtered.count,
        ]
        if next < filtered.count {
            payload["next_cursor"] = String(next)
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return NotionHTTPResponse(status: 200, headers: [:], body: data)
    }
}

final class ScriptedNotion: NotionTransport, @unchecked Sendable {
    var responses: [NotionHTTPResponse]
    var requests: [URLRequest] = []
    var bodies: [Data] { requests.compactMap(\.httpBody) }
    var onSend: (() -> Void)?

    init(responses: [NotionHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> NotionHTTPResponse {
        onSend?()
        requests.append(request)
        if responses.isEmpty { throw ReplyFetchError.transport }
        return responses.removeFirst()
    }
}
