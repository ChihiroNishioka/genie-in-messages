import XCTest
@testable import GenieCore

final class DeliveryTests: XCTestCase {
    func testWebhookRetriesThenDeadLettersWithoutTheBody() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.webhook.results = Array(repeating: .success(WebhookHTTPResult(statusCode: 503)), count: 5)
        let engine = try harness.engine()
        let marker = "UNIQUE_BODY_MARKER"
        let result = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g", chat: 1, fromMe: true, text: "\u{1FA94} \(marker)"
        ))
        XCTAssertEqual(result, .deadLettered("webhook_http_503"))
        XCTAssertEqual(harness.webhook.bodies.count, 5)
        XCTAssertEqual(harness.clock.slept, [1, 2, 4, 8])
        XCTAssertEqual(harness.state.deadLetters.first?.attempts, 5)
        XCTAssertEqual(harness.state.deadLetters.first?.error, "webhook_http_503")
        assertNoBody(harness, marker)
        let encoded = try JSONEncoder().encode(harness.state.deadLetters[0])
        let rendered = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(rendered.contains(marker))
        XCTAssertFalse(rendered.contains("text"))
    }

    func testClientErrorDoesNotRetry() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.webhook.results = [.success(WebhookHTTPResult(statusCode: 400))]
        let engine = try harness.engine()
        _ = await engine.ingestWatchLine(watchLine(
            id: 3, guid: "g", chat: 1, fromMe: true, text: "\u{1FA94} hi"
        ))
        XCTAssertEqual(harness.webhook.bodies.count, 1)
        XCTAssertTrue(harness.clock.slept.isEmpty)
        XCTAssertEqual(harness.state.deadLetters.first?.error, "webhook_http_400")
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.cursorRowID, 3)
    }

    func testTransportThenSuccessUsesBackoff() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.webhook.results = [
            .failure(WebhookCallError.transport),
            .success(WebhookHTTPResult(statusCode: 503)),
            .success(WebhookHTTPResult(statusCode: 200)),
        ]
        let engine = try harness.engine()
        let result = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g", chat: 1, fromMe: true, text: "\u{1FA94} hi"
        ))
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(harness.clock.slept, [1, 2])
        XCTAssertTrue(harness.state.deadLetters.isEmpty)
    }

    func testInsecureSecretIsNotSentOrLogged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let secretURL = root.appendingPathComponent("secret")
        let token = "s3cret-token"
        try Data(token.utf8).write(to: secretURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secretURL.path)
        let paths = ConfigPaths(root: root, logFile: root.appendingPathComponent("genie.log"))
        let harness = Harness()
        harness.allow.ids = [1]
        harness.secrets = FileSecretProvider(paths: paths)
        let engine = try harness.engine()
        let marker = "body-marker-xyz"
        _ = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g", chat: 1, fromMe: true, text: "\u{1FA94} \(marker)"
        ))
        XCTAssertTrue(harness.webhook.secrets.isEmpty)
        XCTAssertEqual(harness.state.deadLetters.first?.error, "secret_mode")
        assertNoBody(harness, token)
        assertNoBody(harness, marker)
    }

    func testSecretIsRereadForEachSend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let secretURL = root.appendingPathComponent("secret")
        try Data("alpha\n".utf8).write(to: secretURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretURL.path)
        let paths = ConfigPaths(root: root, logFile: root.appendingPathComponent("genie.log"))
        let harness = Harness()
        harness.allow.ids = [1]
        harness.secrets = FileSecretProvider(paths: paths)
        let engine = try harness.engine()
        _ = await engine.ingestWatchLine(watchLine(id: 1, guid: "a", chat: 1, fromMe: true, text: "\u{1FA94} a"))
        try Data("beta\n".utf8).write(to: secretURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretURL.path)
        _ = await engine.ingestWatchLine(watchLine(id: 2, guid: "b", chat: 1, fromMe: true, text: "\u{1FA94} b"))
        XCTAssertEqual(harness.webhook.secrets, ["alpha", "beta"])
    }

    func testReplyIsSanitizedHeldWhileLockedAndRetried() async throws {
        let harness = Harness()
        harness.allow.ids = [7]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        seedRoute(harness, guid: "origin", chat: 7)
        harness.lock.locked = true
        harness.replies.pages = [
            ReplyPage(
                replies: [routedReply("r1", chat: 7, text: "\u{1FA94} answer", guid: "origin")],
                nextCursor: "c1"
            ),
        ]
        let engine = try harness.engine()
        await engine.pollReplies()
        XCTAssertTrue(harness.sender.sent.isEmpty)
        var snap = await engine.snapshot()
        XCTAssertEqual(snap.heldLockCount, 1)
        XCTAssertTrue(snap.screenLocked)
        XCTAssertEqual(snap.cursorRowID, 0)
        harness.lock.locked = false
        harness.clock.current = harness.clock.current.addingTimeInterval(15)
        await engine.retryHolds()
        XCTAssertEqual(harness.sender.sent.count, 1)
        let text = harness.sender.sent[0].text
        XCTAssertFalse(Signal.matches(text))
        XCTAssertTrue(text.hasPrefix(GenieConfig.productDefaults.marker))
        XCTAssertTrue(text.contains("answer"))
        snap = await engine.snapshot()
        XCTAssertEqual(snap.heldCount, 0)
    }

    func testAppleEvent1712GoesBackToTheHoldQueue() async throws {
        let harness = Harness()
        harness.allow.ids = [7]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        seedRoute(harness, guid: "origin", chat: 7)
        harness.sender.script = [
            .failure(.notStarted),
            .success(SendReceipt(id: 4, guid: "out-guid", status: "sent")),
        ]
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r1", chat: 7, text: "hello", guid: "origin")], nextCursor: "c1"),
        ]
        let engine = try harness.engine()
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 1)
        var snap = await engine.snapshot()
        XCTAssertEqual(snap.heldLockCount, 1)
        XCTAssertEqual(snap.lastError, "apple_event_1712")
        harness.clock.current = harness.clock.current.addingTimeInterval(15)
        await engine.retryHolds()
        XCTAssertEqual(harness.sender.sent.count, 2)
        let echo = await engine.ingestWatchLine(watchLine(
            id: 20, guid: "out-guid", chat: 7, fromMe: true, text: GenieConfig.productDefaults.marker + " echo"
        ))
        XCTAssertEqual(echo, .ignoredSentGUID)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
        snap = await engine.snapshot()
        XCTAssertEqual(snap.heldCount, 0)
    }

    func testUncertainSendIsNotRetried() async throws {
        let harness = Harness()
        harness.allow.ids = [7]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        seedRoute(harness, guid: "origin", chat: 7)
        harness.sender.script = [.failure(.uncertain)]
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r1", chat: 7, text: "hello", guid: "origin")], nextCursor: "c1"),
            ReplyPage(replies: [routedReply("r1", chat: 7, text: "hello", guid: "origin")], nextCursor: "c1"),
        ]
        let engine = try harness.engine()
        await engine.pollReplies()
        harness.clock.current = harness.clock.current.addingTimeInterval(15)
        await engine.retryHolds()
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 1)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.lastError, "send_uncertain")
        XCTAssertEqual(snap.heldCount, 0)
        XCTAssertEqual(harness.state.deadLetters.first?.error, "send_uncertain")
        XCTAssertEqual(harness.state.state.rateEvents.filter { $0.chatID == 7 }.count, 1)
        assertNoBody(harness, "hello")
    }

    func testRateLimitStopsOneChatUntilResumed() async throws {
        let harness = Harness()
        harness.allow.ids = [1, 2]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.config.rateLimitCount = 5
        harness.config.rateLimitWindowSeconds = 60
        var replies: [FetchedReply] = (1...6).map { index in
            seedRoute(harness, guid: "g\(index)", chat: 1)
            return routedReply("a\(index)", chat: 1, text: "answer \(index)", guid: "g\(index)")
        }
        seedRoute(harness, guid: "gb", chat: 2)
        replies.append(routedReply("b1", chat: 2, text: "other", guid: "gb"))
        harness.replies.pages = [ReplyPage(replies: replies, nextCursor: "c")]
        let engine = try harness.engine()
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.filter { $0.chatID == 1 }.count, 5)
        XCTAssertEqual(harness.sender.sent.filter { $0.chatID == 2 }.count, 1)
        var snap = await engine.snapshot()
        XCTAssertEqual(snap.haltedChatIDs, [1])
        XCTAssertEqual(snap.heldCount, 1)
        await engine.resumeRateLimit(chatID: 1)
        XCTAssertEqual(harness.sender.sent.filter { $0.chatID == 1 }.count, 5)
        harness.clock.current = harness.clock.current.addingTimeInterval(61)
        await engine.resumeRateLimit(chatID: 1)
        XCTAssertEqual(harness.sender.sent.filter { $0.chatID == 1 }.count, 6)
        snap = await engine.snapshot()
        XCTAssertTrue(snap.haltedChatIDs.isEmpty)
        for sent in harness.sender.sent {
            XCTAssertFalse(Signal.matches(sent.text))
            XCTAssertTrue(sent.text.hasPrefix(GenieConfig.productDefaults.marker))
        }
    }

    func testDisabledChatReplyIsNotSent() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        seedRoute(harness, guid: "g9", chat: 9)
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r", chat: 9, text: "nope", guid: "g9")], nextCursor: "c"),
        ]
        let engine = try harness.engine()
        await engine.pollReplies()
        XCTAssertTrue(harness.sender.sent.isEmpty)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.heldCount, 0)
    }

    func testLampMarkerIsReplacedWithTheDefaultBeforeSend() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.config.marker = "\u{1FA94}"
        seedRoute(harness, guid: "g", chat: 1)
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r", chat: 1, text: "hello", guid: "g")], nextCursor: nil),
        ]
        let engine = try harness.engine()
        await engine.pollReplies()
        let text = try XCTUnwrap(harness.sender.sent.first?.text)
        XCTAssertTrue(text.hasPrefix(GenieConfig.productDefaults.marker))
        XCTAssertFalse(Signal.matches(text))
        XCTAssertFalse(text.hasPrefix("\u{1FA94}"))
        let warnings = harness.log.records.filter { $0.code == "marker_replaced" }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.level, LogLevel.warning.rawValue)
    }
}
