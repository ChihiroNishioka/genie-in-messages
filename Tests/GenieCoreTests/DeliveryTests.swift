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
            id: 1, guid: "g", chat: 1, fromMe: true, text: "\u{1F9DE} \(marker)"
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
            id: 3, guid: "g", chat: 1, fromMe: true, text: "\u{1F9DE} hi"
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
            id: 1, guid: "g", chat: 1, fromMe: true, text: "\u{1F9DE} hi"
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
            id: 1, guid: "g", chat: 1, fromMe: true, text: "\u{1F9DE} \(marker)"
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
        _ = await engine.ingestWatchLine(watchLine(id: 1, guid: "a", chat: 1, fromMe: true, text: "\u{1F9DE} a"))
        try Data("beta\n".utf8).write(to: secretURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretURL.path)
        _ = await engine.ingestWatchLine(watchLine(id: 2, guid: "b", chat: 1, fromMe: true, text: "\u{1F9DE} b"))
        XCTAssertEqual(harness.webhook.secrets, ["alpha", "beta"])
    }

    func testReplyIsSanitizedHeldWhileLockedAndRetried() async throws {
        let harness = Harness()
        harness.allow.ids = [7]
        harness.config.replyFetchURL = "http://127.0.0.1/replies"
        harness.lock.locked = true
        harness.replies.pages = [
            ReplyPage(
                replies: [FetchedReply(id: "r1", chatID: 7, text: "\u{1F9DE}\u{200D}\u{2642}\u{FE0F} answer")],
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
        harness.config.replyFetchURL = "http://127.0.0.1/replies"
        harness.sender.script = [
            .failure(.notStarted),
            .success(SendReceipt(id: 4, guid: "out-guid", status: "sent")),
        ]
        harness.replies.pages = [
            ReplyPage(replies: [FetchedReply(id: "r1", chatID: 7, text: "hello")], nextCursor: "c1"),
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
            id: 20, guid: "out-guid", chat: 7, fromMe: true, text: "\u{1F9DE} echo"
        ))
        XCTAssertEqual(echo, .ignoredSentGUID)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
        snap = await engine.snapshot()
        XCTAssertEqual(snap.heldCount, 0)
    }

    func testUncertainSendIsNotRetried() async throws {
        let harness = Harness()
        harness.allow.ids = [7]
        harness.config.replyFetchURL = "http://127.0.0.1/replies"
        harness.sender.script = [.failure(.uncertain)]
        harness.replies.pages = [
            ReplyPage(replies: [FetchedReply(id: "r1", chatID: 7, text: "hello")], nextCursor: "c1"),
            ReplyPage(replies: [FetchedReply(id: "r1", chatID: 7, text: "hello")], nextCursor: "c1"),
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
    }

    func testRateLimitStopsOneChatUntilResumed() async throws {
        let harness = Harness()
        harness.allow.ids = [1, 2]
        harness.config.replyFetchURL = "http://127.0.0.1/replies"
        harness.config.rateLimitCount = 5
        harness.config.rateLimitWindowSeconds = 60
        var replies: [FetchedReply] = (1...6).map {
            FetchedReply(id: "a\($0)", chatID: 1, text: "answer \($0)")
        }
        replies.append(FetchedReply(id: "b1", chatID: 2, text: "other"))
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
        harness.config.replyFetchURL = "http://127.0.0.1/replies"
        harness.replies.pages = [
            ReplyPage(replies: [FetchedReply(id: "r", chatID: 9, text: "nope")], nextCursor: "c"),
        ]
        let engine = try harness.engine()
        await engine.pollReplies()
        XCTAssertTrue(harness.sender.sent.isEmpty)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.heldCount, 0)
    }

    func testMarkerThatStillMatchesSignalIsNotSent() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.replyFetchURL = "http://127.0.0.1/replies"
        harness.config.marker = "\u{1F9DE}"
        harness.replies.pages = [
            ReplyPage(replies: [FetchedReply(id: "r", chatID: 1, text: "hello")], nextCursor: nil),
        ]
        let engine = try harness.engine()
        await engine.pollReplies()
        XCTAssertTrue(harness.sender.sent.isEmpty)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.lastError, "reply_still_matches_signal")
    }
}
