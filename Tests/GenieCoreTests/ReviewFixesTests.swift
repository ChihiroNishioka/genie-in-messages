import XCTest
@testable import GenieCore

final class ReviewFixesTests: XCTestCase {
    func testReplyGoesToTheChatSavedWithTheGuid() async throws {
        let harness = Harness()
        harness.allow.ids = [1, 2]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        let engine = try harness.engine()
        let forwarded = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "origin", chat: 1, fromMe: true, text: "\u{1FA94} ask"
        ))
        XCTAssertEqual(forwarded, .delivered)
        let body = try JSONDecoder().decode(IdempotencyBody.self, from: harness.webhook.bodies[0])
        XCTAssertEqual(body.idempotencyKey, "origin")
        XCTAssertEqual(harness.state.state.routes.first?.chatID, 1)

        harness.replies.pages = [
            ReplyPage(
                replies: [
                    routedReply("wrong", chat: 2, text: "nope", guid: "origin"),
                    routedReply("missing", chat: 1, text: "nope", guid: "unknown"),
                    routedReply("old", chat: 1, text: "stale", guid: "origin", created: "2000-01-01T00:00:00Z"),
                    routedReply("right", chat: 1, text: "yes", guid: "origin"),
                ],
                nextCursor: "c"
            ),
        ]
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.map(\.chatID), [1])
        XCTAssertTrue(harness.sender.sent[0].text.contains("yes"))
        XCTAssertEqual(
            Set(harness.log.records.map(\.code)),
            Set(harness.log.records.map(\.code)).union(["reply_chat_mismatch", "reply_unrouted", "reply_too_old"])
        )
        XCTAssertTrue(harness.log.records.contains { $0.code == "reply_chat_mismatch" })
        XCTAssertTrue(harness.log.records.contains { $0.code == "reply_unrouted" })
        XCTAssertTrue(harness.log.records.contains { $0.code == "reply_too_old" })
        assertNoBody(harness, "nope")
        assertNoBody(harness, "stale")
    }

    func testUnmappedRepliesOnAFreshCursorAreNotSent() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.replies.pages = [
            ReplyPage(
                replies: [routedReply("old", chat: 1, text: "SECRET_REPLY", guid: "nobody")],
                nextCursor: "end"
            ),
        ]
        let engine = try harness.engine()
        await engine.pollReplies()
        XCTAssertTrue(harness.sender.sent.isEmpty)
        XCTAssertEqual(harness.state.state.replyCursor, "end")
        assertNoBody(harness, "SECRET_REPLY")
    }

    func testHeldReplyIsDroppedWhenTheChatIsTurnedOff() async throws {
        let harness = Harness()
        harness.allow.ids = [7]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        seedRoute(harness, guid: "origin", chat: 7)
        harness.lock.locked = true
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r1", chat: 7, text: "SECRET_REPLY", guid: "origin")], nextCursor: nil),
        ]
        let engine = try harness.engine()
        await engine.pollReplies()
        XCTAssertTrue(harness.sender.sent.isEmpty)
        await engine.setChatEnabled(7, enabled: false)
        harness.lock.locked = false
        harness.clock.current = harness.clock.current.addingTimeInterval(15)
        await engine.retryHolds()
        XCTAssertTrue(harness.sender.sent.isEmpty)
        XCTAssertTrue(harness.log.records.contains { $0.code == "reply_chat_disabled" })
        assertNoBody(harness, "SECRET_REPLY")
    }

    func testWebhookRetryStopsWhenTheChatIsDisabledOrPaused() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.webhook.results = [
            .success(WebhookHTTPResult(statusCode: 503)),
            .success(WebhookHTTPResult(statusCode: 200)),
        ]
        let engine = try harness.engine()
        harness.clock.onSleep = {
            await engine.setChatEnabled(1, enabled: false)
        }
        let disabled = await engine.ingestWatchLine(watchLine(
            id: 4, guid: "g", chat: 1, fromMe: true, text: "\u{1FA94} hi"
        ))
        XCTAssertEqual(disabled, .ignoredNotAllowed)
        XCTAssertEqual(harness.webhook.bodies.count, 1)

        await engine.setChatEnabled(1, enabled: true)
        harness.clock.onSleep = {
            await engine.setPaused(true)
        }
        harness.webhook.results = [
            .success(WebhookHTTPResult(statusCode: 503)),
            .success(WebhookHTTPResult(statusCode: 200)),
        ]
        let paused = await engine.ingestWatchLine(watchLine(
            id: 8, guid: "g2", chat: 1, fromMe: true, text: "\u{1FA94} later"
        ))
        XCTAssertEqual(paused, .deferredPaused)
        XCTAssertEqual(harness.webhook.bodies.count, 2)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.cursorRowID, 4)
    }

    func testReentrantPollDoesNotSendTheSameReplyTwice() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        seedRoute(harness, guid: "origin", chat: 1)
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r1", chat: 1, text: "once", guid: "origin")], nextCursor: "c"),
            ReplyPage(replies: [routedReply("r1", chat: 1, text: "once", guid: "origin")], nextCursor: "c"),
        ]
        let engine = try harness.engine()
        harness.sender.onSend = {
            await engine.pollReplies()
            await engine.resumeRateLimit(chatID: 1)
        }
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 1)
    }

    func testFailedSendIsDeadLetteredAndNotRetried() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        seedRoute(harness, guid: "origin", chat: 1)
        harness.sender.script = [
            .failure(.failed),
            .success(SendReceipt(id: 1, guid: "out", status: "sent")),
        ]
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r1", chat: 1, text: "SECRET_REPLY", guid: "origin")], nextCursor: "c"),
            ReplyPage(replies: [routedReply("r1", chat: 1, text: "SECRET_REPLY", guid: "origin")], nextCursor: "c"),
        ]
        let engine = try harness.engine()
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 1)
        XCTAssertEqual(harness.state.deadLetters.first?.error, "send_failed")
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 1)
        assertNoBody(harness, "SECRET_REPLY")
    }

    func testIntentIsRecordedBeforeSendAndInterruptedSendsAreNotRetried() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        seedRoute(harness, guid: "origin", chat: 1)
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r1", chat: 1, text: "hello", guid: "origin")], nextCursor: nil),
        ]
        let engine = try harness.engine()
        var sawPending = false
        harness.sender.onSend = {
            sawPending = !harness.state.state.pendingSends.isEmpty
        }
        await engine.pollReplies()
        XCTAssertTrue(sawPending)
        XCTAssertTrue(harness.state.state.pendingSends.isEmpty)
        XCTAssertFalse(harness.state.state.fingerprints.isEmpty)

        let restarted = Harness()
        restarted.allow.ids = [1]
        restarted.config.replyFetchURL = "https://127.0.0.1/replies"
        restarted.state.state.pendingSends = [
            PendingSend(replyID: "r9", chatID: 1, hash: "abc", at: restarted.clock.current),
        ]
        restarted.state.state.routes = [MessageRoute(guid: "origin", chatID: 1, at: restarted.clock.current)]
        restarted.replies.pages = [
            ReplyPage(replies: [routedReply("r9", chat: 1, text: "again", guid: "origin")], nextCursor: nil),
        ]
        let second = try restarted.engine()
        XCTAssertEqual(restarted.state.deadLetters.first?.error, "send_interrupted")
        await second.pollReplies()
        XCTAssertTrue(restarted.sender.sent.isEmpty)
        XCTAssertEqual(restarted.state.state.rateEvents.count, 1)
    }

    func testPausedLineIsNotOvertakenInTheSameWatch() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        let engine = try harness.engine()
        var first = true
        let results = await WatchApply.apply(lines: [
            watchLine(id: 10, guid: "a", chat: 1, fromMe: true, text: "\u{1FA94} one"),
            watchLine(id: 11, guid: "b", chat: 1, fromMe: true, text: "\u{1FA94} two"),
        ]) { line in
            if first {
                first = false
                await engine.setPaused(true)
                let result = await engine.ingestWatchLine(line)
                await engine.setPaused(false)
                return result
            }
            return await engine.ingestWatchLine(line)
        }
        XCTAssertEqual(results, [.deferredPaused])
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.cursorRowID, 0)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
    }

    func testDeadLetterWriteFailureDoesNotAdvanceTheCursor() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.state.shouldFailDeadLetter = true
        harness.webhook.results = [.success(WebhookHTTPResult(statusCode: 400))]
        let engine = try harness.engine()
        let result = await engine.ingestWatchLine(watchLine(
            id: 3, guid: "g", chat: 1, fromMe: true, text: "\u{1FA94} hi"
        ))
        XCTAssertEqual(result, .blocked)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.cursorRowID, 0)
        XCTAssertTrue(harness.state.deadLetters.isEmpty)
        XCTAssertFalse(harness.state.state.seenGUIDs.contains("g"))
        XCTAssertTrue(harness.log.records.contains { $0.code == "deadletter_write_failed" })
    }

    func testChatGuidChangeClearsTheAllowlistAndCursor() async throws {
        let harness = Harness()
        let engine = try harness.engine()
        await engine.setChatEnabled(4, guid: "chat-a", enabled: true)
        let first = await engine.ingestWatchLine(watchLine(
            id: 20, guid: "m", chat: 4, fromMe: true, text: "\u{1FA94} hi", chatGUID: "chat-a"
        ))
        XCTAssertEqual(first, .delivered)
        let swapped = await engine.ingestWatchLine(watchLine(
            id: 21, guid: "n", chat: 4, fromMe: true, text: "\u{1FA94} next", chatGUID: "chat-b"
        ))
        XCTAssertEqual(swapped, .ignoredDatabaseReset)
        XCTAssertEqual(harness.webhook.bodies.count, 1)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.cursorRowID, 0)
        XCTAssertEqual(snap.enabledChatIDs, [])
        XCTAssertTrue(harness.state.state.routes.isEmpty)
        XCTAssertEqual(snap.lastError, "messages_db_reset")
    }

    func testUncertainSendsCountTowardTheRateLimit() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.config.rateLimitCount = 1
        seedRoute(harness, guid: "g1", chat: 1)
        seedRoute(harness, guid: "g2", chat: 1)
        harness.sender.script = [.failure(.uncertain), .failure(.uncertain)]
        harness.replies.pages = [
            ReplyPage(
                replies: [
                    routedReply("r1", chat: 1, text: "one", guid: "g1"),
                    routedReply("r2", chat: 1, text: "two", guid: "g2"),
                ],
                nextCursor: nil
            ),
        ]
        let engine = try harness.engine()
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 1)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.haltedChatIDs, [1])
        XCTAssertEqual(snap.heldCount, 1)
    }

    func testAllowlistSaveFailureKeepsThePreviousValue() async throws {
        let harness = Harness()
        let engine = try harness.engine()
        await engine.setChatEnabled(3, guid: "g", enabled: true)
        harness.allow.failSave = true
        await engine.setChatEnabled(3, enabled: false)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.enabledChatIDs, [3])
        XCTAssertEqual(snap.lastError, "allowlist_save_failed")
        XCTAssertEqual(harness.allow.ids, [3])
    }

    func testHTTPEndpointsAreNotUsed() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.webhookURL = "http://127.0.0.1/webhook"
        harness.config.replyFetchURL = "http://127.0.0.1/replies"
        seedRoute(harness, guid: "g", chat: 1)
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r", chat: 1, text: "x", guid: "g")], nextCursor: nil),
        ]
        let engine = try harness.engine()
        let result = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g", chat: 1, fromMe: true, text: "\u{1FA94} hi"
        ))
        XCTAssertEqual(result, .deadLettered("url_not_https"))
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
        await engine.pollReplies()
        XCTAssertTrue(harness.sender.sent.isEmpty)
    }

    func testHTTPSessionDoesNotUseTheSharedCache() {
        let session = GenieHTTP.session()
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        let request = HTTPRequestBuilder.webhook(
            url: URL(string: "https://127.0.0.1/hook")!,
            secret: "tok",
            body: Data("{}".utf8),
            idempotencyKey: "g"
        )
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testOversizedWatchLineDoesNotKeepTheBody() async throws {
        var splitter = WatchSplitter()
        var bytes = Data("{\"text\":\"".utf8)
        bytes.append(Data(repeating: 0x61, count: WatchSplitter.maxBytes))
        bytes.append(Data("\",\"id\":42}\n".utf8))
        bytes.append(Data("{\"id\":43,\"text\":\"next\"}\n".utf8))
        let events = splitter.append(bytes)
        XCTAssertEqual(events.first, .tooLarge(rowID: 42))
        XCTAssertEqual(events.last, .line("{\"id\":43,\"text\":\"next\"}"))

        var early = WatchSplitter()
        var head = Data("{\"id\":7,\"text\":\"".utf8)
        head.append(Data(repeating: 0x61, count: WatchSplitter.maxBytes))
        head.append(Data("\"}\n".utf8))
        XCTAssertEqual(early.append(head).first, .tooLarge(rowID: 7))

        let harness = Harness()
        let engine = try harness.engine()
        let noted = await engine.noteOversizedWatchLine(rowID: 42)
        XCTAssertEqual(noted, .skipped)
        XCTAssertEqual(harness.state.deadLetters.first?.error, "watch_line_too_large")
        XCTAssertEqual(harness.state.deadLetters.first?.rowid, 42)
        let rendered = String(data: try JSONEncoder().encode(harness.state.deadLetters[0]), encoding: .utf8) ?? ""
        XCTAssertFalse(rendered.contains("aaaa"))
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.cursorRowID, 42)

        let blocked = await engine.noteOversizedWatchLine(rowID: nil)
        XCTAssertEqual(blocked, .blocked)
    }

    func testInterruptedSendIsHandledEvenWhenDeadLetterWriteFails() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.state.shouldFailDeadLetter = true
        harness.state.state.pendingSends = [
            PendingSend(replyID: "r1", chatID: 1, hash: "abc", at: harness.clock.current),
        ]
        harness.state.state.routes = [MessageRoute(guid: "origin", chatID: 1, at: harness.clock.current)]
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r1", chat: 1, text: "SECRET_REPLY", guid: "origin")], nextCursor: nil),
            ReplyPage(replies: [routedReply("r1", chat: 1, text: "SECRET_REPLY", guid: "origin")], nextCursor: nil),
        ]
        let engine = try harness.engine()
        XCTAssertTrue(harness.state.deadLetters.isEmpty)
        XCTAssertTrue(harness.state.state.handledReplyIDs.contains("r1"))
        XCTAssertEqual(harness.state.state.pendingSends.map(\.replyID), ["r1"])
        XCTAssertTrue(harness.state.state.pendingSends[0].rateCounted)
        XCTAssertTrue(harness.log.records.contains { $0.code == "deadletter_write_failed" })
        await engine.pollReplies()
        XCTAssertTrue(harness.sender.sent.isEmpty)

        harness.state.shouldFailDeadLetter = false
        let restarted = try harness.engine()
        XCTAssertEqual(harness.state.deadLetters.map(\.error), ["send_interrupted"])
        XCTAssertTrue(harness.state.state.pendingSends.isEmpty)
        await restarted.pollReplies()
        XCTAssertTrue(harness.sender.sent.isEmpty)
        assertNoBody(harness, "SECRET_REPLY")
    }

    func testHeldReplyIsNotSentAfterTheRouteExpires() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.config.routeTTLSeconds = 60
        harness.lock.locked = true
        seedRoute(harness, guid: "origin", chat: 1)
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r1", chat: 1, text: "hello", guid: "origin")], nextCursor: nil),
        ]
        let engine = try harness.engine()
        await engine.pollReplies()
        XCTAssertTrue(harness.sender.sent.isEmpty)
        harness.lock.locked = false
        harness.clock.current = harness.clock.current.addingTimeInterval(61)
        await engine.retryHolds()
        XCTAssertTrue(harness.sender.sent.isEmpty)
        XCTAssertTrue(harness.log.records.contains { $0.code == "reply_too_old" })
        XCTAssertTrue(harness.state.state.handledReplyIDs.contains("r1"))
    }

    func testConcurrentSendsDoNotExceedTheRateLimit() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.config.rateLimitCount = 1
        seedRoute(harness, guid: "g1", chat: 1)
        seedRoute(harness, guid: "g2", chat: 1)
        let page = ReplyPage(
            replies: [
                routedReply("r1", chat: 1, text: "one", guid: "g1"),
                routedReply("r2", chat: 1, text: "two", guid: "g2"),
            ],
            nextCursor: nil
        )
        harness.replies.pages = [page, page]
        let engine = try harness.engine()
        harness.sender.onSend = {
            await engine.pollReplies()
        }
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 1)
    }

    func testChildProcessTimeout() async {
        let result = await ProcessRunner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.3)
        XCTAssertTrue(result.timedOut)
        let missing = await ProcessRunner.run(executable: "/no/such/imsg", arguments: [], timeout: 1)
        XCTAssertEqual(missing.exitCode, -1)
        XCTAssertFalse(missing.timedOut)
        let stubborn = await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: ["-c", "trap '' TERM; while true; do :; done"],
            timeout: 0.2
        )
        XCTAssertTrue(stubborn.timedOut)
    }

    func testOldStateFileStillDecodes() throws {
        let json = #"{"v":1,"cursor_rowid":9,"seen_guids":["a"]}"#
        let state = try StateCoding.decoder().decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(state.cursorRowID, 9)
        XCTAssertEqual(state.seenGUIDs, ["a"])
        XCTAssertTrue(state.routes.isEmpty)
        XCTAssertTrue(state.pendingSends.isEmpty)
        let pending = #"{"v":1,"pending_sends":[{"reply_id":"r","chat_id":1,"hash":"h","at":0}]}"#
        let decoded = try StateCoding.decoder().decode(PersistedState.self, from: Data(pending.utf8))
        XCTAssertEqual(decoded.pendingSends.first?.rateCounted, false)
    }

    func testUncertainDeadLetterFailureIsRecordedOnRestartAndNotResent() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.state.shouldFailDeadLetter = true
        seedRoute(harness, guid: "origin", chat: 1)
        harness.sender.script = [.failure(.uncertain)]
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r1", chat: 1, text: "SECRET_REPLY", guid: "origin")], nextCursor: nil),
            ReplyPage(replies: [routedReply("r1", chat: 1, text: "SECRET_REPLY", guid: "origin")], nextCursor: nil),
        ]
        let engine = try harness.engine()
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 1)
        XCTAssertTrue(harness.state.deadLetters.isEmpty)
        XCTAssertEqual(harness.state.state.pendingSends.map(\.replyID), ["r1"])
        XCTAssertTrue(harness.state.state.pendingSends[0].rateCounted)
        XCTAssertEqual(harness.state.state.rateEvents.count, 1)
        XCTAssertTrue(harness.state.state.handledReplyIDs.contains("r1"))
        harness.state.shouldFailDeadLetter = false
        let restarted = try harness.engine()
        XCTAssertEqual(harness.state.deadLetters.first?.error, "send_interrupted")
        XCTAssertTrue(harness.state.state.pendingSends.isEmpty)
        XCTAssertEqual(harness.state.state.rateEvents.count, 1)
        await restarted.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 1)
        assertNoBody(harness, "SECRET_REPLY")
    }

    func testUnknownLockStillAttemptsTheSend() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.lock.forced = .unknown
        seedRoute(harness, guid: "g", chat: 1)
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r", chat: 1, text: "hi", guid: "g")], nextCursor: nil),
        ]
        let engine = try harness.engine()
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.count, 1)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.screenLock, .unknown)
        XCTAssertFalse(snap.screenLocked)
    }
}

private struct IdempotencyBody: Decodable {
    var idempotencyKey: String
    enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
    }
}
