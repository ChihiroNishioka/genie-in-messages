import XCTest
@testable import GenieCore

/// 設計の GREEN のうち、入口が GeniePoller であるものを見る。
final class PollerCoverageTests: XCTestCase {
    func testLauncherWaitsUntilTheListIsApplied() async throws {
        try await assertLaunchOrder(.parsed(ChatListParse(chats: [], failedLineCount: 0)))
    }

    func testLauncherWaitsWhenTheFirstReadFails() async throws {
        try await assertLaunchOrder(.failed)
    }

    func testRequestsDuringTheFirstReadCollapse() async throws {
        let harness = Harness()
        let engine = try harness.engine()
        let reader = ScriptedChatLists(script: [.failed, .failed])
        let poller = makePoller(harness, engine, reader, schedule: .production)
        reader.onRead = {
            await poller.requestChatsRefresh()
            await poller.requestChatsRefresh()
            await poller.requestChatsRefresh()
        }
        let first = await poller.tick()
        XCTAssertEqual(reader.calls, 1)
        let seen1 = await engine.snapshot().holdNotice
        XCTAssertNil(seen1)
        XCTAssertEqual(first.steps.first, .lock)
        XCTAssertEqual(codeCount(harness, "chats_failed"), 1)
        XCTAssertEqual(harness.sender.sent.count, 0)
        harness.clock.current = harness.clock.current.addingTimeInterval(2)
        _ = await poller.tick()
        XCTAssertEqual(reader.calls, 1)
        await poller.requestChatsRefresh()
        harness.clock.current = harness.clock.current.addingTimeInterval(2)
        _ = await poller.tick()
        XCTAssertEqual(reader.calls, 2)
        let seen2 = await engine.snapshot().holdNotice
        XCTAssertNil(seen2)
    }

    func testTickSkipsChatsAndRepliesThatAreNotDue() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.config.replyPollIntervalSeconds = 10
        let engine = try harness.engine()
        let reader = ScriptedChatLists(script: [okList([]), okList([])])
        let poller = makePoller(harness, engine, reader, schedule: .production)
        let first = await poller.tick()
        XCTAssertEqual(first.steps, [.lock, .chats(.ok), .holds, .replies(.fetched)])
        harness.clock.current = harness.clock.current.addingTimeInterval(2)
        let skipped = await poller.tick()
        XCTAssertEqual(skipped.steps, [.lock, .holds])
        harness.clock.current = harness.clock.current.addingTimeInterval(10)
        let repliesOnly = await poller.tick()
        XCTAssertEqual(repliesOnly.steps, [.lock, .holds, .replies(.fetched)])
        XCTAssertEqual(reader.calls, 1)
    }

    func testFiveSecondRepliesLandOnTheTwoSecondGrid() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.config.replyPollIntervalSeconds = 5
        let engine = try harness.engine()
        let start = harness.clock.current
        let reader = repeatingOk()
        var replies: [TimeInterval] = []
        harness.replies.onFetch = { replies.append(harness.clock.current.timeIntervalSince(start)) }
        let poller = makePoller(harness, engine, reader, schedule: .production)
        harness.clock.onSleep = {
            if harness.clock.current.timeIntervalSince(start) > 12 { harness.stop.stop() }
        }
        await poller.run()
        XCTAssertEqual(replies, [0, 6, 12])
    }

    func testShorterReplyIntervalIsReadOnThatTick() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.config.replyPollIntervalSeconds = 60
        let engine = try harness.engine()
        let start = harness.clock.current
        let mutable = MutableConfig(harness.config)
        let reader = repeatingOk()
        var replies: [TimeInterval] = []
        harness.replies.onFetch = { replies.append(harness.clock.current.timeIntervalSince(start)) }
        let poller = makePoller(harness, engine, reader, schedule: .production, config: mutable)
        harness.clock.onSleep = {
            if harness.clock.current.timeIntervalSince(start) >= 20 {
                mutable.config.replyPollIntervalSeconds = 10
            }
            if replies.count >= 2 { harness.stop.stop() }
        }
        await poller.run()
        XCTAssertEqual(replies, [0, 20])
    }

    func testRequestedReadRestartsTheChatInterval() async throws {
        let harness = Harness()
        let engine = try harness.engine()
        let start = harness.clock.current
        let reader = repeatingOk()
        var chats: [TimeInterval] = []
        reader.onRead = { chats.append(harness.clock.current.timeIntervalSince(start)) }
        let poller = makePoller(harness, engine, reader, schedule: .production)
        harness.clock.onSleep = {
            let elapsed = harness.clock.current.timeIntervalSince(start)
            if elapsed == 10 { await poller.requestChatsRefresh() }
            if elapsed > 70 { harness.stop.stop() }
        }
        await poller.run()
        XCTAssertEqual(chats, [0, 10, 40, 70])
    }

    func testPauseDoesNotAdvanceTheReplyClock() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.config.replyPollIntervalSeconds = 60
        let engine = try harness.engine()
        let reader = repeatingOk()
        let poller = makePoller(harness, engine, reader, schedule: .production)
        let start = harness.clock.current
        let first = await poller.tick()
        let startedAt = await poller.currentSchedule().lastRepliesAt
        XCTAssertEqual(first.steps.last, .replies(.fetched))
        await engine.setPaused(true)
        harness.clock.current = start.addingTimeInterval(60)
        let paused = await poller.tick()
        XCTAssertEqual(paused.steps, [.lock, .chats(.ok), .holds, .replies(.skippedPaused)])
        let seen3 = await poller.currentSchedule().lastRepliesAt
        XCTAssertEqual(seen3, startedAt)
        XCTAssertEqual(harness.sender.sent.count, 0)
        await engine.setPaused(false)
        harness.clock.current = start.addingTimeInterval(62)
        let resumed = await poller.tick()
        XCTAssertEqual(resumed.steps.last, .replies(.fetched))
    }

    func testReplyClockUsesTheFetchCompletionTime() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.config.replyPollIntervalSeconds = 10
        let engine = try harness.engine()
        let start = harness.clock.current
        let reader = repeatingOk()
        var stamps: [Date] = []
        harness.replies.onFetch = {
            stamps.append(harness.clock.current)
            harness.clock.current = harness.clock.current.addingTimeInterval(7)
            if stamps.count >= 2 { harness.stop.stop() }
        }
        let poller = makePoller(harness, engine, reader, schedule: .production)
        let report = await poller.tick()
        XCTAssertEqual(report.at, start)
        let seen4 = await poller.currentSchedule().lastRepliesAt
        XCTAssertEqual(seen4, start.addingTimeInterval(7))
        await poller.run()
        XCTAssertEqual(stamps, [start, start.addingTimeInterval(17)])
    }

    func testFailedFetchUsesTheSameCompletionTime() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.config.replyPollIntervalSeconds = 10
        let engine = try harness.engine()
        let start = harness.clock.current
        let reader = repeatingOk()
        harness.replies.failNext = true
        harness.replies.onFetch = {
            harness.clock.current = harness.clock.current.addingTimeInterval(7)
        }
        let poller = makePoller(harness, engine, reader, schedule: .production)
        let report = await poller.tick()
        XCTAssertEqual(report.steps.last, .replies(.fetchFailed))
        XCTAssertEqual(report.at, start)
        let seen5 = await poller.currentSchedule().lastRepliesAt
        XCTAssertEqual(seen5, start.addingTimeInterval(7))
    }

    func testMissingReplyURLRecordsTheTickEnd() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = ""
        let engine = try harness.engine()
        let mutable = MutableConfig(harness.config)
        mutable.onLoad = {
            harness.clock.current = harness.clock.current.addingTimeInterval(1)
        }
        let reader = repeatingOk()
        let poller = makePoller(harness, engine, reader, config: mutable)
        let report = await poller.tick()
        XCTAssertEqual(report.steps.last, .replies(.notConfigured))
        let last = await poller.currentSchedule().lastRepliesAt
        XCTAssertNotEqual(last, report.at)
        XCTAssertEqual(last, harness.clock.current)
    }

    func testSkippedReplyPollsLeaveTheClock() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.config.replyPollIntervalSeconds = 10
        let engine = try harness.engine()
        let reader = ScriptedChatLists(script: [.failed])
        reader.onRead = { reader.script.append(okList([])) }
        let poller = makePoller(harness, engine, reader, schedule: .production)
        let start = harness.clock.current
        let blocked = await poller.tick()
        XCTAssertEqual(blocked.steps.last, .replies(.skippedUnchecked))
        let seen6 = await poller.currentSchedule().lastRepliesAt
        XCTAssertNil(seen6)
        harness.clock.current = start.addingTimeInterval(30)
        let recovered = await poller.tick()
        XCTAssertEqual(recovered.steps.last, .replies(.fetched))
        let recoveredAt = await poller.currentSchedule().lastRepliesAt
        XCTAssertEqual(recoveredAt, start.addingTimeInterval(30))

        await engine.setPaused(true)
        harness.clock.current = start.addingTimeInterval(40)
        let paused = await poller.tick()
        XCTAssertEqual(paused.steps.last, .replies(.skippedPaused))
        let seen7 = await poller.currentSchedule().lastRepliesAt
        XCTAssertEqual(seen7, recoveredAt)
        await engine.setPaused(false)
        harness.clock.current = start.addingTimeInterval(41)
        let seen8 = (await poller.tick()).steps.last
        XCTAssertEqual(seen8, .replies(.fetched))

        harness.replies.onFetch = { harness.stop.stop() }
        harness.clock.current = start.addingTimeInterval(52)
        let beforeStop = await poller.currentSchedule().lastRepliesAt
        let stopped = await poller.tick()
        XCTAssertEqual(stopped.steps.last, .replies(.skippedStopped))
        let seen9 = await poller.currentSchedule().lastRepliesAt
        XCTAssertEqual(seen9, beforeStop)
    }

    func testShortOutageNeverShowsTheFailureLine() async throws {
        let pair = try prepared(interval: 10)
        let harness = pair.0
        let engine = pair.1
        let start = harness.clock.current
        let reader = ScriptedChatLists(script: [
            okList([room(7, "chat-kept")]),
            .failed,
            okList([room(7, "chat-kept")]),
        ])
        harness.replies.pages = [
            ReplyPage(replies: [], nextCursor: nil),
            ReplyPage(replies: [routedReply("r-late", chat: 7, text: "hello", guid: "origin")], nextCursor: nil),
        ]
        let poller = makePoller(harness, engine, reader, schedule: .production)
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(30)
        _ = await poller.tick()
        let seen10 = await engine.snapshot().holdNotice
        XCTAssertNil(seen10)
        harness.clock.current = start.addingTimeInterval(40)
        _ = await poller.tick()
        XCTAssertEqual(harness.sender.sent.count, 0)
        let seen11 = await engine.snapshot().holdNotice
        XCTAssertNil(seen11)
        harness.clock.current = start.addingTimeInterval(60)
        _ = await poller.tick()
        XCTAssertEqual(harness.sender.sent.count, 1)
        let seen12 = await engine.snapshot().holdNotice
        XCTAssertNil(seen12)
        let seen13 = await engine.snapshot().holdNotice
        XCTAssertNotEqual(seen13, "chats_failed")
        XCTAssertEqual(codeCount(harness, "chats_failed"), 1)
    }

    func testGraceStaysAnchoredToTheFirstFailure() async throws {
        let pair = try prepared()
        let harness = pair.0
        let engine = pair.1
        let start = harness.clock.current
        let reader = ScriptedChatLists(script: [.failed, .failed, .failed, .failed])
        let poller = makePoller(harness, engine, reader)
        harness.clock.current = start.addingTimeInterval(30)
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(60)
        _ = await poller.tick()
        await poller.requestChatsRefresh()
        harness.clock.current = start.addingTimeInterval(70)
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(89.999)
        let seen14 = await engine.snapshot().holdNotice
        XCTAssertNil(seen14)
        harness.clock.current = start.addingTimeInterval(90)
        let seen15 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen15, "chats_failed")
    }

    func testFailureDuringFetchDoesNotLogTwice() async throws {
        let pair = try prepared()
        let harness = pair.0
        let engine = pair.1
        let reader = ScriptedChatLists(script: [okList([room(7, "chat-kept")])])
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-1", chat: 7, text: "hello", guid: "origin")], nextCursor: nil),
        ]
        harness.replies.onFetch = { _ = await engine.applyChatList(.failed) }
        let poller = makePoller(harness, engine, reader)
        _ = await poller.tick()
        XCTAssertEqual(harness.sender.sent.count, 0)
        XCTAssertEqual(codeCount(harness, "chats_failed"), 1)
        let seen16 = await engine.snapshot().holdNotice
        XCTAssertNil(seen16)
    }

    func testImmediateRetryDoesNotSkipTheGrace() async throws {
        let pair = try prepared()
        let harness = pair.0
        harness.config.rateLimitCount = 1
        let limited = try harness.engine()
        let reader = ScriptedChatLists(script: [okList([room(7, "chat-kept")])])
        harness.replies.pages = [ReplyPage(
            replies: [
                routedReply("r-1", chat: 7, text: "one", guid: "origin"),
                routedReply("r-2", chat: 7, text: "two", guid: "origin"),
            ],
            nextCursor: nil
        )]
        let poller = makePoller(harness, limited, reader)
        _ = await poller.tick()
        XCTAssertEqual(harness.sender.sent.count, 1)
        let seen17 = await limited.snapshot().heldCount
        XCTAssertEqual(seen17, 1)
        let armed = LockedFlag(true)
        harness.lock.onState = {
            guard armed.value else { return }
            armed.value = false
            _ = await limited.applyChatList(.failed)
        }
        let start = harness.clock.current
        await limited.resumeRateLimit(chatID: 7)
        let seen18 = await limited.snapshot().holdNotice
        XCTAssertNil(seen18)
        XCTAssertEqual(codeCount(harness, "chats_failed"), 1)
        harness.clock.current = start.addingTimeInterval(60)
        let seen19 = await limited.snapshot().holdNotice
        XCTAssertEqual(seen19, "chats_failed")
    }

    func testOutageKeepsExpiredRepliesUntilRecovery() async throws {
        let pair = try prepared(ids: [7, 8], ttl: 60)
        let harness = pair.0
        let engine = pair.1
        harness.lock.locked = true
        let start = harness.clock.current
        let reader = ScriptedChatLists(script: [
            okList([room(7, "chat-kept")]),
            .failed,
            .failed,
            okList([room(7, "chat-kept"), room(8, "chat-b")]),
        ])
        harness.replies.pages = [
            ReplyPage(replies: [
                routedReply("r-hold", chat: 7, text: "one", guid: "origin"),
                routedReply("r-wait", chat: 8, text: "two", guid: "origin-b"),
            ], nextCursor: nil),
            ReplyPage(replies: [routedReply("r-wait", chat: 8, text: "two", guid: "origin-b")], nextCursor: nil),
        ]
        let poller = makePoller(harness, engine, reader)
        _ = await poller.tick()
        XCTAssertEqual(harness.sender.sent.count, 0)
        let seen20 = await engine.snapshot().heldCount
        XCTAssertEqual(seen20, 1)
        harness.clock.current = start.addingTimeInterval(30)
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(100)
        _ = await poller.tick()
        XCTAssertEqual(harness.sender.sent.count, 0)
        let seen21 = await engine.snapshot().heldCount
        XCTAssertEqual(seen21, 1)
        let seen22 = await engine.inFlightReplyCount()
        XCTAssertEqual(seen22, 0)
        XCTAssertFalse(harness.state.state.handledReplyIDs.contains("r-hold"))
        XCTAssertFalse(harness.state.state.handledReplyIDs.contains("r-wait"))
        XCTAssertEqual(codeCount(harness, "reply_too_old"), 0)
        let seen23 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen23, "chats_failed")
        harness.lock.locked = false
        harness.clock.current = start.addingTimeInterval(102)
        _ = await poller.tick()
        XCTAssertEqual(harness.sender.sent.count, 0)
        XCTAssertEqual(codeCount(harness, "reply_too_old"), 2)
        let seen24 = await engine.snapshot().holdNotice
        XCTAssertNil(seen24)
    }

    func testRecoveryKeepsAnotherError() async throws {
        let pair = try prepared()
        let harness = pair.0
        let engine = pair.1
        await engine.setLastError("watch_exited")
        let reader = ScriptedChatLists(script: [.failed, okList([room(7, "chat-kept")])])
        let poller = makePoller(harness, engine, reader)
        let start = harness.clock.current
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(60)
        _ = await poller.tick()
        let snap = await engine.snapshot()
        XCTAssertNil(snap.holdNotice)
        XCTAssertEqual(snap.lastError, "watch_exited")
    }

    func testPartialSuccessStillSends() async throws {
        let pair = try prepared()
        let harness = pair.0
        let engine = pair.1
        let reader = ScriptedChatLists(script: [
            .parsed(ChatListParse(chats: [room(7, "chat-kept")], failedLineCount: 1)),
        ])
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-1", chat: 7, text: "hello", guid: "origin")], nextCursor: nil),
        ]
        let poller = makePoller(harness, engine, reader)
        _ = await poller.tick()
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.holdNotice, "chats_parse_partial_ok")
        XCTAssertEqual(harness.sender.sent.count, 1)
        XCTAssertEqual(codeCount(harness, "chats_parse_failed"), 1)
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: "chats_parse_partial_ok"),
            "照合: 一覧の一部の行を読めませんでした。許可したトークは一覧で確かめられました"
        )
    }

    func testPartialTimelineThroughThePoller() async throws {
        let pair = try prepared()
        let harness = pair.0
        let engine = pair.1
        let start = harness.clock.current
        let reader = ScriptedChatLists(script: [
            partial([room(7, "chat-kept")]),
            .failed,
            .failed,
            partial([room(7, "chat-kept")]),
            okList([room(8, "someone-else")]),
            okList([room(7, "chat-kept")]),
        ])
        let poller = makePoller(harness, engine, reader)
        _ = await poller.tick()
        let seen25 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen25, "chats_parse_partial_ok")
        XCTAssertEqual(codeCount(harness, "chats_parse_failed"), 1)
        harness.clock.current = start.addingTimeInterval(30)
        _ = await poller.tick()
        let seen26 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen26, "chats_parse_partial_ok")
        harness.clock.current = start.addingTimeInterval(60)
        _ = await poller.tick()
        let seen27 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen27, "chats_parse_partial_ok")
        harness.clock.current = start.addingTimeInterval(90)
        let seen28 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen28, "chats_failed")
        harness.clock.current = start.addingTimeInterval(92)
        _ = await poller.tick()
        let seen29 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen29, "chats_parse_partial_ok")
        XCTAssertEqual(codeCount(harness, "chats_parse_failed"), 1)
        XCTAssertEqual(codeCount(harness, "chats_failed"), 1)
        harness.clock.current = start.addingTimeInterval(120)
        _ = await poller.tick()
        let seen30 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen30, "chats_parse_failed")
        harness.clock.current = start.addingTimeInterval(150)
        _ = await poller.tick()
        let seen31 = await engine.snapshot().holdNotice
        XCTAssertNil(seen31)
    }

    func testUnverifiedRecoveryThenFailureLogsAgain() async throws {
        let pair = try prepared()
        let harness = pair.0
        let engine = pair.1
        let start = harness.clock.current
        let other = okList([room(8, "someone-else")])
        let reader = ScriptedChatLists(script: [
            partial([room(8, "someone-else")]),
            .failed,
            .failed,
            other,
            .failed,
        ])
        let poller = makePoller(harness, engine, reader)
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(30)
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(60)
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(90)
        let seen32 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen32, "chats_failed")
        harness.clock.current = start.addingTimeInterval(92)
        _ = await poller.tick()
        let seen33 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen33, "chats_parse_failed")
        harness.clock.current = start.addingTimeInterval(122)
        _ = await poller.tick()
        let seen34 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen34, "chats_parse_failed")
        XCTAssertEqual(codeCount(harness, "chats_failed"), 2)
    }

    func testNotInListLogGrowsOnlyAfterTheChatReturns() async throws {
        let pair = try prepared(ids: [7, 8])
        let harness = pair.0
        let engine = pair.1
        let start = harness.clock.current
        let missing = partial([room(7, "chat-kept")])
        let both = partial([room(7, "chat-kept"), room(8, "chat-b")])
        let reader = ScriptedChatLists(script: [missing, missing, missing, both, missing])
        let poller = makePoller(harness, engine, reader)
        func page(_ id: String) -> ReplyPage {
            ReplyPage(replies: [routedReply(id, chat: 8, text: "wait", guid: "origin-b")], nextCursor: nil)
        }
        harness.replies.pages = [page("r-b")]
        _ = await poller.tick()
        XCTAssertEqual(codeCount(harness, "reply_held_not_in_list"), 1)
        harness.clock.current = start.addingTimeInterval(30)
        harness.replies.pages = [page("r-b")]
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(60)
        harness.replies.pages = [page("r-b")]
        _ = await poller.tick()
        XCTAssertEqual(codeCount(harness, "reply_held_not_in_list"), 1)
        XCTAssertEqual(codeCount(harness, "chats_parse_failed"), 1)
        harness.clock.current = start.addingTimeInterval(90)
        harness.replies.pages = [page("r-b")]
        _ = await poller.tick()
        XCTAssertEqual(harness.sender.sent.count, 1)
        harness.clock.current = start.addingTimeInterval(120)
        harness.replies.pages = [page("r-b3")]
        _ = await poller.tick()
        XCTAssertEqual(codeCount(harness, "reply_held_not_in_list"), 2)
        XCTAssertEqual(codeCount(harness, "chats_parse_failed"), 1)
    }

    func testExpiryResolvesTheWaitingLog() async throws {
        let pair = try prepared(ids: [7, 8], ttl: 120)
        let harness = pair.0
        let engine = pair.1
        let start = harness.clock.current
        let missing = okList([room(7, "chat-kept")])
        let reader = ScriptedChatLists(script: [missing, .failed, .failed, missing, missing, missing])
        let poller = makePoller(harness, engine, reader)
        func page(_ id: String) -> ReplyPage {
            ReplyPage(replies: [routedReply(id, chat: 8, text: "wait", guid: "origin-b")], nextCursor: nil)
        }
        harness.replies.pages = [page("r-b")]
        _ = await poller.tick()
        XCTAssertEqual(codeCount(harness, "reply_held_not_in_list"), 1)
        harness.clock.current = start.addingTimeInterval(30)
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(60)
        _ = await poller.tick()
        let seen35 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen35, "reply_held_not_in_list")
        harness.clock.current = start.addingTimeInterval(62)
        harness.replies.pages = [page("r-b")]
        _ = await poller.tick()
        XCTAssertEqual(codeCount(harness, "reply_held_not_in_list"), 1)
        harness.clock.current = start.addingTimeInterval(130)
        harness.replies.pages = [page("r-b")]
        _ = await poller.tick()
        XCTAssertEqual(codeCount(harness, "reply_too_old"), 1)
        let seen36 = await engine.snapshot().holdNotice
        XCTAssertNil(seen36)
        harness.clock.current = start.addingTimeInterval(142)
        let fresh = ISO8601.string(from: harness.clock.current)
        _ = await engine.ingestWatchLine(watchLine(
            id: 90,
            guid: "origin-new",
            chat: 8,
            fromMe: true,
            text: "\u{1FA94} again",
            chatGUID: "chat-b"
        ))
        harness.replies.pages = [ReplyPage(
            replies: [routedReply("r-new", chat: 8, text: "wait", guid: "origin-new", created: fresh)],
            nextCursor: nil
        )]
        _ = await poller.tick()
        XCTAssertEqual(codeCount(harness, "reply_held_not_in_list"), 2)
    }

    func testUnverifiedRecoveryMakesTheNextFailureLogAgain() async throws {
        let pair = try prepared(ids: [7, 8])
        let harness = pair.0
        let engine = pair.1
        let start = harness.clock.current
        let missing = okList([room(7, "chat-kept")])
        let partialMissing = partial([room(7, "chat-kept")])
        let reader = ScriptedChatLists(script: [.failed, missing, .failed, partialMissing, .failed])
        let poller = makePoller(harness, engine, reader)
        _ = await poller.tick()
        XCTAssertEqual(codeCount(harness, "chats_failed"), 1)
        harness.clock.current = start.addingTimeInterval(30)
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(60)
        _ = await poller.tick()
        XCTAssertEqual(codeCount(harness, "chats_failed"), 2)
        harness.clock.current = start.addingTimeInterval(62)
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(90)
        _ = await poller.tick()
        XCTAssertEqual(codeCount(harness, "chats_failed"), 3)
    }

    func testAllRowsFailureStaysThroughTheGrace() async throws {
        let pair = try prepared()
        let harness = pair.0
        let engine = pair.1
        let start = harness.clock.current
        let all = ChatListRead.parsed(ChatListParse(chats: [], failedLineCount: 1))
        let reader = ScriptedChatLists(script: [all, .failed, .failed, all, okList([room(7, "chat-kept")])])
        let poller = makePoller(harness, engine, reader)
        _ = await poller.tick()
        let seen37 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen37, "chats_parse_failed")
        XCTAssertEqual(harness.sender.sent.count, 0)
        harness.clock.current = start.addingTimeInterval(30)
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(60)
        _ = await poller.tick()
        let seen38 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen38, "chats_parse_failed")
        harness.clock.current = start.addingTimeInterval(62)
        _ = await poller.tick()
        XCTAssertEqual(codeCount(harness, "chats_parse_failed"), 1)
        XCTAssertEqual(harness.sender.sent.count, 0)
        harness.clock.current = start.addingTimeInterval(92)
        _ = await poller.tick()
        let seen39 = await engine.snapshot().holdNotice
        XCTAssertNil(seen39)
    }

    func testWaitingReasonReturnsWhenTheFetchRecovers() async throws {
        let pair = try prepared()
        let harness = pair.0
        let engine = pair.1
        let start = harness.clock.current
        let events = EventLog()
        let applied = Gate()
        let probe = RecordingProbe(log: events)
        let reader = ScriptedChatLists(script: [
            okList([]),
            .failed,
            .failed,
            .failed,
            okList([]),
            okList([room(7, "chat-kept")]),
        ])
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-1", chat: 7, text: "hello", guid: "origin")], nextCursor: nil),
        ]
        let poller = makePoller(harness, engine, reader, probe: probe)
        _ = await poller.tick()
        let seen40 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen40, "reply_held_empty_list")
        harness.clock.current = start.addingTimeInterval(30)
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(60)
        _ = await poller.tick()
        let seen41 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen41, "reply_held_empty_list")
        harness.clock.current = start.addingTimeInterval(90)
        _ = await poller.tick()
        let seen42 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen42, "chats_failed")
        let arrived = Gate()
        probe.arrived["chatsApplied"] = arrived
        probe.gates["chatsApplied"] = applied
        let saw = expectGate(arrived, "applied")
        harness.clock.current = start.addingTimeInterval(92)
        let running = Task { await poller.tick() }
        await fulfillment(of: [saw], timeout: 2)
        let seen43 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen43, "reply_held_empty_list")
        applied.open()
        _ = await running.value
        harness.clock.current = start.addingTimeInterval(94)
        _ = await poller.tick()
        let seen44 = await engine.snapshot().holdNotice
        XCTAssertNil(seen44)
    }

    func testTickDuringFetchDoesNotReadChats() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        let engine = try harness.engine()
        let reader = ScriptedChatLists(script: [okList([]), .failed])
        let release = Gate()
        defer { release.open() }
        let entered = expectation(description: "fetch")
        harness.replies.onFetch = {
            entered.fulfill()
            await release.wait()
        }
        let poller = makePoller(harness, engine, reader, schedule: .production)
        let running = Task { await poller.tick() }
        await fulfillment(of: [entered], timeout: 2)
        let nested = await poller.tick()
        XCTAssertTrue(nested.skippedBusy)
        XCTAssertEqual(reader.calls, 1)
        await poller.requestChatsRefresh()
        release.open()
        _ = await running.value
        harness.clock.current = harness.clock.current.addingTimeInterval(2)
        _ = await poller.tick()
        XCTAssertEqual(reader.calls, 2)
    }

    func testLongFetchDefersTheListAndTheHeldReply() async throws {
        let pair = try prepared(interval: 10)
        let harness = pair.0
        let engine = pair.1
        harness.lock.locked = true
        let start = harness.clock.current
        let reader = ScriptedChatLists(script: [okList([room(7, "chat-kept")]), okList([room(7, "chat-kept")])])
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-1", chat: 7, text: "hello", guid: "origin")], nextCursor: nil),
            ReplyPage(replies: [], nextCursor: nil),
        ]
        let poller = makePoller(harness, engine, reader, schedule: .production)
        _ = await poller.tick()
        XCTAssertEqual(harness.sender.sent.count, 0)
        let seen45 = await engine.snapshot().heldCount
        XCTAssertEqual(seen45, 1)
        let release = Gate()
        defer { release.open() }
        let entered = expectation(description: "long fetch")
        var callsDuring = -1
        var nestedBusy = false
        harness.replies.onFetch = {
            entered.fulfill()
            harness.clock.current = harness.clock.current.addingTimeInterval(300)
            await poller.requestChatsRefresh()
            harness.lock.locked = false
            await engine.noteLock(.unlocked)
            let nested = await poller.tick()
            nestedBusy = nested.skippedBusy
            callsDuring = reader.calls
            await release.wait()
        }
        harness.clock.current = start.addingTimeInterval(10)
        let running = Task { await poller.tick() }
        await fulfillment(of: [entered], timeout: 2)
        release.open()
        _ = await running.value
        XCTAssertTrue(nestedBusy)
        XCTAssertEqual(callsDuring, 1)
        let seen46 = await poller.currentSchedule().lastRepliesAt
        XCTAssertEqual(seen46, start.addingTimeInterval(310))
        harness.clock.current = start.addingTimeInterval(312)
        _ = await poller.tick()
        XCTAssertEqual(reader.calls, 2)
        XCTAssertEqual(harness.sender.sent.count, 1)
    }

    func testCancelDuringSleepStopsTheRun() async throws {
        let harness = Harness()
        let engine = try harness.engine()
        let reader = repeatingOk()
        let poller = makePoller(
            harness,
            engine,
            reader,
            schedule: PollSchedule(tickSeconds: 2, chatsSeconds: 0, lastChatsAt: nil, lastRepliesAt: nil)
        )
        let slot = TaskSlot()
        let armed = Gate()
        let second = Gate()
        defer {
            harness.stop.stop()
            armed.open()
            second.open()
        }
        let keep = reader.onRead
        reader.onRead = {
            await keep?()
            if reader.calls >= 2 { second.open() }
        }
        harness.clock.onSleep = {
            await armed.wait()
            slot.task?.cancel()
        }
        let task = Task { await poller.run() }
        slot.task = task
        armed.open()
        let outcome = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                await second.wait()
                return false
            }
            let first = await group.next() ?? false
            harness.stop.stop()
            second.open()
            return first
        }
        XCTAssertTrue(outcome)
        XCTAssertEqual(reader.calls, 1)
        XCTAssertEqual(harness.clock.slept.count, 1)
    }

    func testStopDuringLockCheckReadsNothing() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        let engine = try harness.engine()
        harness.lock.onState = { harness.stop.stop() }
        let reader = ScriptedChatLists(script: [.failed])
        let poller = makePoller(harness, engine, reader)
        let report = await poller.tick()
        XCTAssertEqual(report.steps, [.lock])
        XCTAssertTrue(report.stoppedMidway)
        XCTAssertEqual(reader.calls, 0)
    }

    func testCancelDuringSleepEndsTheInitialWait() async throws {
        let harness = Harness()
        let engine = try harness.engine()
        let release = Gate()
        defer { release.open() }
        let reader = ScriptedChatLists(script: [okList([])])
        let started = expectation(description: "read")
        reader.onRead = {
            started.fulfill()
            await release.wait()
        }
        let poller = makePoller(harness, engine, reader, schedule: .production, probe: RecordingProbe(log: EventLog()))
        let ticking = Task { await poller.tick() }
        await fulfillment(of: [started], timeout: 2)
        let slot = TaskSlot()
        let armed = Gate()
        harness.clock.onSleep = {
            await armed.wait()
            slot.task?.cancel()
        }
        let watched = LockedFlag()
        let tasks = GenieRuntimeLauncher.launch(poller: poller, stop: harness.stop) { watched.value = true }
        slot.task = tasks.poller
        armed.open()
        let early = expectation(description: "initial stopped")
        Task {
            let value = await poller.waitForInitialChatList()
            if value == .stopped { early.fulfill() }
        }
        await fulfillment(of: [early], timeout: 2)
        let supervisor = expectation(description: "supervisor")
        Task {
            _ = await tasks.supervisor.value
            supervisor.fulfill()
        }
        await fulfillment(of: [supervisor], timeout: 2)
        XCTAssertFalse(watched.value)
        XCTAssertEqual(reader.calls, 1)
        release.open()
        _ = await ticking.value
        let seen47 = await poller.waitForInitialChatList()
        XCTAssertEqual(seen47, .stopped)
        XCTAssertFalse(watched.value)
        _ = await tasks.poller.value
    }

    func testStopAfterTheReadCheckDiscardsTheApply() async throws {
        let pair = try prepared()
        let harness = pair.0
        let engine = pair.1
        let start = harness.clock.current
        let events = EventLog()
        let gate = Gate()
        defer { gate.open() }
        let probe = RecordingProbe(log: events)
        let reader = ScriptedChatLists(script: [okList([room(7, "chat-kept")]), .failed])
        let poller = makePoller(harness, engine, reader, schedule: .production, probe: probe)
        _ = await poller.tick()
        let beforeChats = await poller.latestChats()
        let beforeSchedule = await poller.currentSchedule().lastChatsAt
        let before = await engine.snapshot()
        let arrived = Gate()
        probe.arrived["chatsReadReturned"] = arrived
        probe.gates["chatsReadReturned"] = gate
        let saw = expectGate(arrived, "returned")
        harness.clock.current = start.addingTimeInterval(30)
        let running = Task { await poller.tick() }
        await fulfillment(of: [saw], timeout: 2)
        harness.stop.stop()
        gate.open()
        let report = await running.value
        XCTAssertEqual(report.steps, [.lock, .chats(.discardedAfterStop)])
        XCTAssertTrue(report.stoppedMidway)
        let seen48 = await poller.latestChats()
        XCTAssertEqual(seen48, beforeChats)
        let seen49 = await poller.currentSchedule().lastChatsAt
        XCTAssertEqual(seen49, beforeSchedule)
        let after = await engine.snapshot()
        XCTAssertEqual(after.holdNotice, before.holdNotice)
        XCTAssertEqual(codeCount(harness, "chats_failed"), 0)
        let discarded = await engine.applyChatList(.failed)
        XCTAssertEqual(discarded, .discarded)
        XCTAssertEqual(codeCount(harness, "chats_failed"), 0)
    }

    func testStopDuringFetchSendsNothing() async throws {
        let pair = try prepared()
        let harness = pair.0
        let engine = pair.1
        let before = await engine.savedReplyCursor()
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-1", chat: 7, text: "hello", guid: "origin")], nextCursor: "c1"),
        ]
        harness.replies.onFetch = { harness.stop.stop() }
        let reader = ScriptedChatLists(script: [okList([room(7, "chat-kept")])])
        let poller = makePoller(harness, engine, reader)
        let report = await poller.tick()
        XCTAssertEqual(report.steps.last, .replies(.skippedStopped))
        XCTAssertEqual(harness.sender.sent.count, 0)
        XCTAssertFalse(harness.state.state.handledReplyIDs.contains("r-1"))
        let seen50 = await engine.savedReplyCursor()
        XCTAssertEqual(seen50, before)
        let again = try restarted(harness)
        harness.replies.onFetch = nil
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-1", chat: 7, text: "hello", guid: "origin")], nextCursor: "c1"),
        ]
        _ = await again.tick()
        XCTAssertEqual(harness.sender.sent.count, 1)
    }

    func testStopDuringTheFirstOfTwoSendsLeavesTheRest() async throws {
        let pair = try prepared()
        let harness = pair.0
        let engine = pair.1
        let before = await engine.savedReplyCursor()
        harness.replies.pages = [ReplyPage(replies: [
            routedReply("r-1", chat: 7, text: "one", guid: "origin"),
            routedReply("r-2", chat: 7, text: "two", guid: "origin"),
        ], nextCursor: "c2")]
        harness.sender.onSend = { harness.stop.stop() }
        let reader = ScriptedChatLists(script: [okList([room(7, "chat-kept")])])
        let poller = makePoller(harness, engine, reader)
        let report = await poller.tick()
        XCTAssertEqual(report.steps.last, .replies(.skippedStopped))
        XCTAssertEqual(harness.sender.sent.count, 1)
        XCTAssertTrue(harness.state.state.handledReplyIDs.contains("r-1"))
        XCTAssertFalse(harness.state.state.handledReplyIDs.contains("r-2"))
        let seen51 = await engine.savedReplyCursor()
        XCTAssertEqual(seen51, before)
        harness.sender.onSend = nil
        let again = try restarted(harness)
        harness.replies.pages = [ReplyPage(replies: [
            routedReply("r-1", chat: 7, text: "one", guid: "origin"),
            routedReply("r-2", chat: 7, text: "two", guid: "origin"),
        ], nextCursor: "c2")]
        _ = await again.tick()
        XCTAssertEqual(harness.sender.sent.count, 2)
    }

    func testStopDuringRetryDoesNotExpireTheRest() async throws {
        let pair = try prepared(ttl: 60)
        let harness = pair.0
        let engine = pair.1
        harness.lock.locked = true
        let start = harness.clock.current
        harness.replies.pages = [ReplyPage(replies: [
            routedReply("r-a", chat: 7, text: "one", guid: "origin"),
            routedReply("r-b", chat: 7, text: "two", guid: "origin"),
        ], nextCursor: nil)]
        let reader = ScriptedChatLists(script: [
            okList([room(7, "chat-kept")]),
            okList([room(7, "chat-kept")]),
        ])
        let poller = makePoller(harness, engine, reader)
        _ = await poller.tick()
        XCTAssertEqual(harness.sender.sent.count, 0)
        let seen52 = await engine.snapshot().heldCount
        XCTAssertEqual(seen52, 2)
        harness.lock.locked = false
        await engine.noteLock(.unlocked)
        harness.sender.onSend = {
            harness.stop.stop()
            harness.clock.current = start.addingTimeInterval(harness.config.routeTTLSeconds + 5)
        }
        harness.clock.current = start.addingTimeInterval(1)
        _ = await poller.tick()
        XCTAssertEqual(harness.sender.sent.count, 1)
        let seen53 = await engine.snapshot().heldCount
        XCTAssertEqual(seen53, 1)
        let seen54 = await engine.inFlightReplyCount()
        XCTAssertEqual(seen54, 0)
        XCTAssertFalse(harness.log.records.contains { $0.code == "reply_too_old" })
        _ = await poller.tick()
        let seen55 = await engine.snapshot().heldCount
        XCTAssertEqual(seen55, 1)
        XCTAssertEqual(codeCount(harness, "reply_too_old"), 0)
    }

    func testStopDuringSendDoesNotAdvanceTheCursor() async throws {
        let pair = try prepared()
        let harness = pair.0
        let engine = pair.1
        let before = await engine.savedReplyCursor()
        harness.replies.pages = [ReplyPage(
            replies: [routedReply("r-one", chat: 7, text: "hello", guid: "origin")],
            nextCursor: "c1"
        )]
        harness.sender.onSend = { harness.stop.stop() }
        let reader = ScriptedChatLists(script: [okList([room(7, "chat-kept")])])
        let poller = makePoller(harness, engine, reader)
        let report = await poller.tick()
        XCTAssertEqual(harness.sender.sent.count, 1)
        XCTAssertEqual(report.steps.last, .replies(.skippedStopped))
        let seen56 = await engine.savedReplyCursor()
        XCTAssertEqual(seen56, before)
        XCTAssertTrue(harness.state.state.handledReplyIDs.contains("r-one"))
        harness.sender.onSend = nil
        harness.replies.pages = [ReplyPage(
            replies: [routedReply("r-one", chat: 7, text: "hello", guid: "origin")],
            nextCursor: "c1"
        )]
        let again = try restarted(harness)
        _ = await again.tick()
        XCTAssertEqual(harness.sender.sent.count, 1)
    }

    func testStopWhileTheFirstReadIsWaiting() async throws {
        let harness = Harness()
        let engine = try harness.engine()
        let release = Gate()
        defer { release.open() }
        let reader = ScriptedChatLists(script: [.failed])
        let started = expectation(description: "read waiting")
        reader.onRead = {
            started.fulfill()
            await release.wait()
        }
        let watched = LockedFlag()
        let poller = makePoller(harness, engine, reader, schedule: .production)
        let tasks = GenieRuntimeLauncher.launch(poller: poller, stop: harness.stop) { watched.value = true }
        await fulfillment(of: [started], timeout: 2)
        let early = expectation(description: "stopped first")
        Task {
            let value = await poller.waitForInitialChatList()
            if value == .stopped { early.fulfill() }
        }
        harness.stop.stop()
        await fulfillment(of: [early], timeout: 2)
        XCTAssertFalse(watched.value)
        release.open()
        _ = await tasks.poller.value
        _ = await tasks.supervisor.value
        XCTAssertEqual(reader.calls, 1)
        XCTAssertFalse(watched.value)
        XCTAssertEqual(codeCount(harness, "chats_failed"), 0)
    }

    func testPauseStillReadsAndResumeSends() async throws {
        let pair = try prepared(interval: 60)
        let harness = pair.0
        let engine = pair.1
        harness.lock.locked = true
        let start = harness.clock.current
        let reader = ScriptedChatLists(script: [
            okList([room(7, "chat-kept")]),
            okList([room(7, "chat-kept")]),
            okList([room(7, "chat-kept")]),
        ])
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-1", chat: 7, text: "hello", guid: "origin")], nextCursor: nil),
        ]
        let poller = makePoller(harness, engine, reader, schedule: .production)
        _ = await poller.tick()
        let seen57 = await engine.snapshot().heldCount
        XCTAssertEqual(seen57, 1)
        await engine.setPaused(true)
        harness.lock.locked = false
        harness.clock.current = start.addingTimeInterval(60)
        let paused = await poller.tick()
        XCTAssertEqual(paused.steps.first, .lock)
        XCTAssertTrue(paused.steps.contains(.chats(.ok)))
        XCTAssertEqual(paused.steps.last, .replies(.skippedPaused))
        XCTAssertEqual(harness.sender.sent.count, 0)
        await engine.setPaused(false)
        harness.clock.current = start.addingTimeInterval(62)
        _ = await poller.tick()
        XCTAssertEqual(harness.sender.sent.count, 1)
    }

    func testShortPauseAndOutageFetchImmediately() async throws {
        let pair = try prepared(interval: 60)
        let harness = pair.0
        let engine = pair.1
        let start = harness.clock.current
        let reader = ScriptedChatLists(script: [
            okList([room(7, "chat-kept")]),
            okList([room(7, "chat-kept")]),
            .failed,
            okList([room(7, "chat-kept")]),
        ])
        harness.replies.pages = [
            ReplyPage(replies: [], nextCursor: nil),
            ReplyPage(replies: [routedReply("r-1", chat: 7, text: "hello", guid: "origin")], nextCursor: nil),
            ReplyPage(replies: [], nextCursor: nil),
        ]
        let poller = makePoller(harness, engine, reader, schedule: .production)
        let seen58 = (await poller.tick()).steps.last
        XCTAssertEqual(seen58, .replies(.fetched))
        await engine.setPaused(true)
        harness.clock.current = start.addingTimeInterval(10)
        await engine.setPaused(false)
        harness.clock.current = start.addingTimeInterval(20)
        let resumed = await poller.tick()
        XCTAssertEqual(resumed.steps.last, .replies(.fetched))
        XCTAssertEqual(harness.sender.sent.count, 1)
        let after = await poller.currentSchedule().lastRepliesAt
        harness.clock.current = start.addingTimeInterval(70)
        let notYet = await poller.tick()
        XCTAssertFalse(notYet.steps.contains(.replies(.fetched)))
        let seen59 = await poller.currentSchedule().lastRepliesAt
        XCTAssertEqual(seen59, after)
        harness.clock.current = start.addingTimeInterval(80)
        let seen60 = (await poller.tick()).steps.last
        XCTAssertEqual(seen60, .replies(.fetched))

        let outage = try prepared(interval: 60)
        let reader2 = ScriptedChatLists(script: [
            okList([room(7, "chat-kept")]),
            .failed,
            okList([room(7, "chat-kept")]),
        ])
        outage.0.replies.pages = [
            ReplyPage(replies: [], nextCursor: nil),
            ReplyPage(replies: [routedReply("r-2", chat: 7, text: "again", guid: "origin")], nextCursor: nil),
        ]
        let second = makePoller(outage.0, outage.1, reader2, schedule: .production)
        let opened = outage.0.clock.current
        _ = await second.tick()
        outage.0.clock.current = opened.addingTimeInterval(30)
        _ = await second.tick()
        await second.requestChatsRefresh()
        outage.0.clock.current = opened.addingTimeInterval(40)
        let recovered = await second.tick()
        XCTAssertTrue(recovered.steps.contains(.chats(.ok)))
        XCTAssertEqual(recovered.steps.last, .replies(.fetched))
        XCTAssertEqual(outage.0.sender.sent.count, 1)
    }

    func testEmptyFetchDoesNotClearAWaitingNotice() async throws {
        let pair = try prepared(interval: 1)
        let harness = pair.0
        let engine = pair.1
        let reader = ScriptedChatLists(script: [okList([]), okList([])])
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-1", chat: 7, text: "hello", guid: "origin")], nextCursor: nil),
            ReplyPage(replies: [], nextCursor: nil),
        ]
        let poller = makePoller(harness, engine, reader)
        _ = await poller.tick()
        let seen61 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen61, "reply_held_empty_list")
        harness.clock.current = harness.clock.current.addingTimeInterval(2)
        _ = await poller.tick()
        let seen62 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen62, "reply_held_empty_list")
        XCTAssertEqual(codeCount(harness, "reply_too_old"), 0)
    }

    func testMatchedGuidStaysClearThroughTheGrace() async throws {
        let pair = try prepared(interval: 1)
        let harness = pair.0
        let engine = pair.1
        let start = harness.clock.current
        let kept = okList([room(7, "chat-kept")])
        let reader = ScriptedChatLists(script: [kept, kept, .failed])
        let poller = makePoller(harness, engine, reader, schedule: .production)
        _ = await poller.tick()
        await engine.setChatEnabled(7, guid: "chat-other", enabled: true)
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-mismatch", chat: 7, text: "hello", guid: "origin")], nextCursor: nil),
        ]
        harness.clock.current = start.addingTimeInterval(2)
        _ = await poller.tick()
        let seen63 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen63, "reply_chat_guid_mismatch")
        XCTAssertEqual(harness.sender.sent.count, 0)
        await engine.setChatEnabled(7, guid: "chat-kept", enabled: true)
        harness.clock.current = start.addingTimeInterval(30)
        _ = await poller.tick()
        let seen64 = await engine.snapshot().holdNotice
        XCTAssertNil(seen64)
        await poller.requestChatsRefresh()
        harness.clock.current = start.addingTimeInterval(40)
        _ = await poller.tick()
        let seen65 = await engine.snapshot().holdNotice
        XCTAssertNil(seen65)
        harness.clock.current = start.addingTimeInterval(100)
        let seen66 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen66, "chats_failed")
    }

    func testCleanReadClearsTheNoticeBeforeReplies() async throws {
        let pair = try prepared()
        let harness = pair.0
        let engine = pair.1
        let events = EventLog()
        let applied = Gate()
        defer { applied.open() }
        let probe = RecordingProbe(log: events)
        let reader = ScriptedChatLists(script: [
            .parsed(ChatListParse(chats: [], failedLineCount: 1)),
            okList([room(7, "chat-kept")]),
        ])
        let poller = makePoller(harness, engine, reader, probe: probe)
        _ = await poller.tick()
        let seen67 = await engine.snapshot().holdNotice
        XCTAssertEqual(seen67, "chats_parse_failed")
        let arrived = Gate()
        probe.arrived["chatsApplied"] = arrived
        probe.gates["chatsApplied"] = applied
        let saw = expectGate(arrived, "applied")
        let running = Task { await poller.tick() }
        await fulfillment(of: [saw], timeout: 2)
        let seen68 = await engine.snapshot().holdNotice
        XCTAssertNil(seen68)
        applied.open()
        _ = await running.value
        let seen69 = await engine.snapshot().holdNotice
        XCTAssertNil(seen69)
        XCTAssertEqual(harness.sender.sent.count, 0)
    }

    func testHeldReplyReturnsWhenTheListBecomesUnchecked() async throws {
        let pair = try prepared(ttl: 60)
        let harness = pair.0
        let engine = pair.1
        harness.lock.locked = true
        let start = harness.clock.current
        harness.replies.pages = [ReplyPage(replies: [
            routedReply("r-a", chat: 7, text: "one", guid: "origin"),
            routedReply("r-b", chat: 7, text: "two", guid: "origin"),
        ], nextCursor: nil)]
        let kept = okList([room(7, "chat-kept")])
        let reader = ScriptedChatLists(script: [kept, kept])
        let poller = makePoller(harness, engine, reader)
        _ = await poller.tick()
        let held = await engine.snapshot()
        XCTAssertEqual(held.heldCount, 2)
        harness.lock.locked = false
        await engine.noteLock(.unlocked)
        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func bump() -> Int {
                lock.lock()
                defer { lock.unlock() }
                n += 1
                return n
            }
        }
        let phase = Count()
        harness.lock.onState = {
            if phase.bump() >= 2 {
                harness.clock.current = start.addingTimeInterval(harness.config.routeTTLSeconds + 5)
                _ = await engine.applyChatList(.failed)
            }
        }
        harness.clock.current = start.addingTimeInterval(1)
        _ = await poller.tick()
        let snap = await engine.snapshot()
        let inFlight = await engine.inFlightReplyCount()
        XCTAssertEqual(snap.heldCount, 2)
        XCTAssertEqual(inFlight, 0)
        XCTAssertEqual(harness.sender.sent.count, 0)
        XCTAssertEqual(codeCount(harness, "reply_too_old"), 0)
    }

    func testPartialSuccessResolvesTheHoldLogAcrossADatabaseReset() async throws {
        let pair = try prepared(ids: [7, 8])
        let harness = pair.0
        let engine = pair.1
        let reader = ScriptedChatLists(script: [
            okList([room(7, "chat-kept")]),
            partial([room(7, "chat-kept")]),
            okList([room(7, "chat-kept")]),
        ])
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-b", chat: 8, text: "wait", guid: "origin-b")], nextCursor: nil),
        ]
        harness.config.replyPollIntervalSeconds = 1
        let poller = makePoller(harness, engine, reader)
        _ = await poller.tick()
        XCTAssertEqual(codeCount(harness, "reply_held_not_in_list"), 1)
        await engine.setChatEnabled(7, guid: "chat-other", enabled: true)
        _ = await poller.tick()
        let reset = await engine.snapshot()
        XCTAssertEqual(reset.lastError, "messages_db_reset")
        await engine.setChatEnabled(8, guid: "chat-b", enabled: true)
        _ = await engine.ingestWatchLine(watchLine(
            id: 91,
            guid: "origin-b",
            chat: 8,
            fromMe: true,
            text: "\u{1FA94} again",
            chatGUID: "chat-b"
        ))
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-b2", chat: 8, text: "again", guid: "origin-b")], nextCursor: nil),
        ]
        harness.clock.current = harness.clock.current.addingTimeInterval(2)
        _ = await poller.tick()
        XCTAssertEqual(codeCount(harness, "reply_held_not_in_list"), 2)
    }

    func testVerifiedChatDoesNotSendAfterEveryLineFails() async throws {
        let pair = try prepared()
        let harness = pair.0
        let engine = pair.1
        let reader = ScriptedChatLists(script: [
            okList([room(7, "chat-kept")]),
            .parsed(ChatListParse(chats: [], failedLineCount: 1)),
        ])
        harness.replies.pages = [
            ReplyPage(replies: [], nextCursor: nil),
            ReplyPage(replies: [routedReply("r-1", chat: 7, text: "hello", guid: "origin")], nextCursor: nil),
        ]
        harness.config.replyPollIntervalSeconds = 1
        let poller = makePoller(harness, engine, reader)
        _ = await poller.tick()
        XCTAssertEqual(harness.sender.sent.count, 0)
        harness.clock.current = harness.clock.current.addingTimeInterval(2)
        _ = await poller.tick()
        let afterRows = await engine.snapshot()
        XCTAssertEqual(harness.sender.sent.count, 0)
        XCTAssertEqual(afterRows.holdNotice, "chats_parse_failed")
    }

    func testMismatchStaysBehindTheFailureNoticeAfterTheGrace() async throws {
        let pair = try prepared(interval: 1)
        let harness = pair.0
        let engine = pair.1
        let start = harness.clock.current
        let kept = okList([room(7, "chat-kept")])
        let reader = ScriptedChatLists(script: [kept, .failed])
        let poller = makePoller(harness, engine, reader, schedule: .production)
        _ = await poller.tick()
        await engine.setChatEnabled(7, guid: "chat-other", enabled: true)
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-mismatch", chat: 7, text: "hello", guid: "origin")], nextCursor: nil),
        ]
        harness.clock.current = start.addingTimeInterval(2)
        _ = await poller.tick()
        let mismatched = await engine.snapshot()
        XCTAssertEqual(mismatched.holdNotice, "reply_chat_guid_mismatch")
        await poller.requestChatsRefresh()
        harness.clock.current = start.addingTimeInterval(4)
        _ = await poller.tick()
        harness.clock.current = start.addingTimeInterval(64)
        let later = await engine.snapshot()
        XCTAssertEqual(later.holdNotice, "chats_failed")
    }

    func testCancellingTheSupervisorDoesNotStartWatch() async throws {
        let harness = Harness()
        let engine = try harness.engine()
        let release = Gate()
        defer { release.open() }
        let reader = ScriptedChatLists(script: [okList([])])
        let started = Gate()
        reader.onRead = {
            started.open()
            await release.wait()
        }
        let watched = LockedFlag()
        let poller = makePoller(harness, engine, reader, schedule: .production)
        let tasks = GenieRuntimeLauncher.launch(poller: poller, stop: harness.stop) {
            watched.value = true
        }
        await fulfillment(of: [expectGate(started, "read")], timeout: 2)
        tasks.supervisor.cancel()
        release.open()
        _ = await tasks.supervisor.value
        XCTAssertFalse(watched.value)
    }

    func testLessonsKeepTheDesignSentenceAndTheOldDistinction() throws {
        let text = try String(contentsOf: repoRoot().appendingPathComponent("LESSONS.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("条件は1つずつ戻して、どれにも落ちるテストがあることを確かめる"))
        XCTAssertTrue(text.contains("返事を取りに行って保留が見えなかったことと、一覧が戻ったことは別もの"))
    }

    private func assertLaunchOrder(_ read: ChatListRead) async throws {
        let harness = Harness()
        let engine = try harness.engine()
        let events = EventLog()
        let release = Gate()
        let returned = Gate()
        let applied = Gate()
        defer {
            harness.stop.stop()
            release.open()
            returned.open()
            applied.open()
        }
        let reader = ScriptedChatLists(script: [read])
        let readStarted = Gate()
        reader.onRead = {
            events.append("read")
            readStarted.open()
            await release.wait()
        }
        let probe = RecordingProbe(log: events)
        let registered = Gate()
        let returnedArrived = Gate()
        let appliedArrived = Gate()
        probe.arrived["initialWaitRegistered"] = registered
        probe.arrived["chatsReadReturned"] = returnedArrived
        probe.arrived["chatsApplied"] = appliedArrived
        probe.gates["chatsReadReturned"] = returned
        probe.gates["chatsApplied"] = applied
        let poller = makePoller(harness, engine, reader, schedule: .production, probe: probe)
        let saw = LockedFlag()
        let watchGate = Gate()
        defer { watchGate.open() }
        harness.clock.onSleep = { await watchGate.wait() }
        let tasks = GenieRuntimeLauncher.launch(poller: poller, stop: harness.stop) {
            events.append("watch")
            saw.value = true
            watchGate.open()
        }
        await fulfillment(of: [expectGate(registered, "wait registered"), expectGate(readStarted, "read started")], timeout: 2)
        XCTAssertFalse(events.snapshot().contains("watch"))
        release.open()
        await fulfillment(of: [expectGate(returnedArrived, "read returned")], timeout: 2)
        let seen70 = await poller.initialListResolved()
        XCTAssertFalse(seen70)
        XCTAssertFalse(saw.value)
        returned.open()
        await fulfillment(of: [expectGate(appliedArrived, "applied")], timeout: 2)
        let seen71 = await poller.initialListResolved()
        XCTAssertFalse(seen71)
        XCTAssertEqual(
            events.snapshot().filter { $0 == "read" || $0 == "chatsApplied" },
            ["read", "chatsApplied"]
        )
        XCTAssertFalse(saw.value)
        applied.open()
        await fulfillment(of: [expectGate(watchGate, "watch")], timeout: 2)
        harness.stop.stop()
        let relevant = events.snapshot().filter { ["read", "chatsApplied", "watch"].contains($0) }
        let watchAt = relevant.firstIndex(of: "watch")
        XCTAssertNotNil(watchAt)
        if let watchAt {
            XCTAssertEqual(Array(relevant.prefix(through: watchAt)), ["read", "chatsApplied", "watch"])
        }
        let initial = await poller.waitForInitialChatList()
        XCTAssertEqual(initial, .applied)
        harness.stop.stop()
        _ = await tasks.poller.value
        _ = await tasks.supervisor.value
    }

    private func expectGate(_ gate: Gate, _ name: String) -> XCTestExpectation {
        let exp = expectation(description: name)
        Task {
            await gate.wait()
            exp.fulfill()
        }
        return exp
    }
}


private func room(_ id: Int64, _ guid: String) -> ChatSummary {
    ChatSummary(id: id, title: "room", isGroup: false, guid: guid)
}

private func okList(_ chats: [ChatSummary]) -> ChatListRead {
    .parsed(ChatListParse(chats: chats, failedLineCount: 0))
}

private func partial(_ chats: [ChatSummary]) -> ChatListRead {
    .parsed(ChatListParse(chats: chats, failedLineCount: 1))
}

private func repeatingOk() -> ScriptedChatLists {
    let reader = ScriptedChatLists(script: [okList([])])
    reader.onRead = { reader.script.append(okList([])) }
    return reader
}

private func codeCount(_ harness: Harness, _ code: String) -> Int {
    harness.log.records.filter { $0.code == code }.count
}

private func prepared(
    ids: [Int64] = [7],
    ttl: Double? = nil,
    interval: Double? = nil
) throws -> (Harness, GenieEngine) {
    let harness = Harness()
    harness.allow.ids = Set(ids)
    for id in ids {
        let guid = id == 7 ? "chat-kept" : (id == 8 ? "chat-b" : "chat-\(id)")
        harness.allow.guids[id] = guid
        seedRoute(harness, guid: id == 7 ? "origin" : "origin-b", chat: id)
    }
    harness.config.replyFetchURL = "https://127.0.0.1/replies"
    if let ttl { harness.config.routeTTLSeconds = ttl }
    if let interval { harness.config.replyPollIntervalSeconds = interval }
    return (harness, try harness.engine())
}

private func makePoller(
    _ harness: Harness,
    _ engine: GenieEngine,
    _ reader: ScriptedChatLists,
    schedule: PollSchedule = PollSchedule(tickSeconds: 2, chatsSeconds: 0, lastChatsAt: nil, lastRepliesAt: nil),
    config: (any ConfigProviding)? = nil,
    probe: (any PollerProbe)? = nil
) -> GeniePoller {
    GeniePoller(
        engine: engine,
        reader: reader,
        configProvider: config ?? StaticConfig(config: harness.config),
        clock: harness.clock,
        stop: harness.stop,
        schedule: schedule,
        probe: probe
    )
}

private func restarted(_ harness: Harness) throws -> GeniePoller {
    let signal = StopSignal()
    let engine = try harness.engine(stop: signal)
    let reader = ScriptedChatLists(script: [okList([room(7, "chat-kept")])])
    return GeniePoller(
        engine: engine,
        reader: reader,
        configProvider: StaticConfig(config: harness.config),
        clock: harness.clock,
        stop: signal,
        schedule: PollSchedule(tickSeconds: 2, chatsSeconds: 0, lastChatsAt: nil, lastRepliesAt: nil)
    )
}
