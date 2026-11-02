import XCTest
@testable import GenieCore

/// 一覧を読んでから返事を取る、実際の1周を繰り返して表示を見る。
final class PollerNoticeLoopTests: XCTestCase {
    func testPartialParseNoticeSurvivesTheReplyPollUntilTheListIsVerified() async throws {
        let started = try loopEngine()
        await started.engine.runPollerPass(.parsed(ChatListParse(
            chats: [ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept")],
            failedLineCount: 1
        )))
        let afterPoll = await started.engine.snapshot()
        XCTAssertEqual(started.harness.sender.sent.count, 0)
        XCTAssertEqual(afterPoll.holdNotice, "chats_parse_failed")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: afterPoll.holdNotice),
            "照合: トーク一覧を読めないため、返事を待っています"
        )

        await started.engine.runPollerPass(.parsed(ChatListParse(
            chats: [ChatSummary(id: 8, title: "other", isGroup: false, guid: "someone-else")],
            failedLineCount: 0
        )))
        let unverified = await started.engine.snapshot()
        XCTAssertEqual(unverified.holdNotice, "chats_parse_failed")
        XCTAssertNotEqual(SendHoldStatus.menuLine(for: unverified.holdNotice), "照合: なし")

        await started.engine.runPollerPass(.parsed(ChatListParse(
            chats: [ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept")],
            failedLineCount: 0
        )))
        let verified = await started.engine.snapshot()
        XCTAssertNil(verified.holdNotice)
        XCTAssertEqual(SendHoldStatus.menuLine(for: verified.holdNotice), "照合: なし")
        XCTAssertEqual(started.harness.sender.sent.count, 0)
    }

    func testRepeatedListFailureIsLoggedOnceEvenWhenAReplyOverwritesTheNotice() async throws {
        let started = try loopEngine()
        started.harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-missing", chat: 7, text: "hello", guid: "origin")], nextCursor: nil),
            ReplyPage(replies: [routedReply("r-missing", chat: 7, text: "hello", guid: "origin")], nextCursor: nil),
        ]
        let partial = ChatListParse(
            chats: [ChatSummary(id: 8, title: "other", isGroup: false, guid: "someone-else")],
            failedLineCount: 1
        )
        await started.engine.runPollerPass(.parsed(partial))
        await started.engine.runPollerPass(.parsed(partial))
        let notes = started.harness.log.records.filter { $0.code == "chats_parse_failed" }
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.level, "error")
        XCTAssertTrue(notes.allSatisfy { $0.chatID == nil && $0.guid == nil && $0.rowid == nil })
        XCTAssertEqual(started.harness.sender.sent.count, 0)
    }

    func testAllLinesFailingDoesNotKeepTheNoticeAfterACleanVerifiedRead() async throws {
        let started = try loopEngine()
        await started.engine.runPollerPass(.parsed(ChatListParse(chats: [], failedLineCount: 1)))
        let stuck = await started.engine.snapshot()
        XCTAssertEqual(stuck.holdNotice, "chats_parse_failed")

        // 次の正常な取得では、返事を見る前に表示が消えている。
        _ = await started.engine.applyChatList(.parsed(ChatListParse(
            chats: [ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept")],
            failedLineCount: 0
        )))
        let accepted = await started.engine.snapshot()
        XCTAssertNil(accepted.holdNotice)
        await started.engine.retryHolds()
        await started.engine.pollReplies()
        let cleared = await started.engine.snapshot()
        XCTAssertNil(cleared.holdNotice)
        XCTAssertEqual(SendHoldStatus.menuLine(for: cleared.holdNotice), "照合: なし")
        XCTAssertEqual(started.harness.sender.sent.count, 0)
    }

    func testOneStartupListFailureDoesNotSayAReplyIsWaiting() async throws {
        let started = try loopEngine()
        await started.engine.runPollerPass(.failed)
        let once = await started.engine.snapshot()
        XCTAssertNil(once.holdNotice)
        XCTAssertNotEqual(
            SendHoldStatus.menuLine(for: once.holdNotice),
            "照合: トーク一覧を読めないため、返事を待っています"
        )
        XCTAssertEqual(started.harness.sender.sent.count, 0)

        await started.engine.runPollerPass(.failed)
        let again = await started.engine.snapshot()
        XCTAssertEqual(again.holdNotice, "chats_failed")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: again.holdNotice),
            "照合: トーク一覧を読めないため、返事を待っています"
        )
        let notes = started.harness.log.records.filter { $0.code == "chats_failed" }
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.level, "error")
        XCTAssertTrue(notes.allSatisfy { $0.chatID == nil && $0.guid == nil && $0.rowid == nil })
    }

    func testMatchedGuidDoesNotRestoreTheOldMismatchNotice() async throws {
        let started = try loopEngine(routeTTL: 60)
        await started.engine.runPollerPass(.parsed(ChatListParse(
            chats: [ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept")],
            failedLineCount: 0
        )))
        await started.engine.setChatEnabled(7, guid: "chat-other", enabled: true)
        started.harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-mismatch", chat: 7, text: "hello", guid: "origin")], nextCursor: nil),
        ]
        await started.engine.pollReplies()
        let mismatched = await started.engine.snapshot()
        XCTAssertEqual(started.harness.sender.sent.count, 0)
        XCTAssertEqual(mismatched.holdNotice, "reply_chat_guid_mismatch")

        await started.engine.setChatEnabled(7, guid: "chat-kept", enabled: true)
        await started.engine.runPollerPass(.parsed(ChatListParse(
            chats: [ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept")],
            failedLineCount: 0
        )))
        let matched = await started.engine.snapshot()
        XCTAssertNil(matched.holdNotice)
        XCTAssertEqual(SendHoldStatus.menuLine(for: matched.holdNotice), "照合: なし")

        started.harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-later", chat: 7, text: "later", guid: "origin")], nextCursor: nil),
        ]
        await started.engine.runPollerPass(.parsed(ChatListParse(chats: [], failedLineCount: 0)))
        started.harness.clock.current = started.harness.clock.current.addingTimeInterval(120)
        started.harness.replies.pages = [
            ReplyPage(replies: [routedReply("r-later", chat: 7, text: "later", guid: "origin")], nextCursor: nil),
        ]
        await started.engine.runPollerPass(.parsed(ChatListParse(chats: [], failedLineCount: 0)))
        let after = await started.engine.snapshot()
        XCTAssertEqual(started.harness.sender.sent.count, 0)
        XCTAssertNil(after.holdNotice)
        XCTAssertNotEqual(after.holdNotice, "reply_chat_guid_mismatch")
        XCTAssertEqual(SendHoldStatus.menuLine(for: after.holdNotice), "照合: なし")
    }
}

private func loopEngine(routeTTL: Double? = nil) throws -> Started {
    let harness = Harness()
    harness.allow.ids = [7]
    harness.allow.guids = [7: "chat-kept"]
    harness.config.replyFetchURL = "https://127.0.0.1/replies"
    if let routeTTL {
        harness.config.routeTTLSeconds = routeTTL
    }
    seedRoute(harness, guid: "origin", chat: 7)
    let engine = try harness.engine()
    return Started(harness: harness, engine: engine, replies: CountingReplies(page: ReplyPage(replies: [], nextCursor: nil)))
}
