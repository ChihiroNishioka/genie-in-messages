import XCTest
@testable import GenieCore

/// 解析の問題と一時的な保留が、取得失敗の回数で消えないことを見る。
final class ListStateTransitionTests: XCTestCase {
    func testUnverifiedRecoveryAfterAFailureNoticeKeepsTheParseProblem() async throws {
        let started = try transitionEngine()
        let start = started.harness.clock.current
        await started.engine.applyChatList(.parsed(ChatListParse(
            chats: [room(8, "someone-else")],
            failedLineCount: 1
        )))
        var snap = await started.engine.snapshot()
        XCTAssertEqual(snap.holdNotice, "chats_parse_failed")
        started.harness.clock.current = start.addingTimeInterval(30)
        await started.engine.applyChatList(.failed)
        started.harness.clock.current = start.addingTimeInterval(60)
        await started.engine.applyChatList(.failed)
        started.harness.clock.current = start.addingTimeInterval(90)
        snap = await started.engine.snapshot()
        XCTAssertEqual(snap.holdNotice, "chats_failed")
        started.harness.clock.current = start.addingTimeInterval(92)
        await started.engine.applyChatList(.parsed(ChatListParse(
            chats: [room(8, "someone-else")],
            failedLineCount: 0
        )))
        snap = await started.engine.snapshot()
        XCTAssertEqual(snap.holdNotice, "chats_parse_failed")
        XCTAssertEqual(started.harness.sender.sent.count, 0)
    }

    func testExpiryDoesNotClearAnUnresolvedParseProblem() async throws {
        let started = try transitionEngine(routeTTL: 60)
        await started.engine.applyChatList(.parsed(ChatListParse(
            chats: [room(8, "someone-else")],
            failedLineCount: 1
        )))
        started.harness.replies.pages = [ReplyPage(
            replies: [routedReply("r-wait", chat: 7, text: "hello", guid: "origin")],
            nextCursor: nil
        )]
        await started.engine.pollReplies()
        started.harness.clock.current = started.harness.clock.current.addingTimeInterval(120)
        started.harness.replies.pages = [ReplyPage(
            replies: [routedReply("r-wait", chat: 7, text: "hello", guid: "origin")],
            nextCursor: nil
        )]
        await started.engine.pollReplies()
        let snap = await started.engine.snapshot()
        XCTAssertEqual(snap.holdNotice, "chats_parse_failed")
        XCTAssertEqual(started.harness.sender.sent.count, 0)
        XCTAssertTrue(started.harness.log.records.contains { $0.code == "reply_too_old" })
    }

    func testAllRowsFailureStaysVisibleThroughTheFetchGrace() async throws {
        let started = try transitionEngine()
        let start = started.harness.clock.current
        await started.engine.applyChatList(.parsed(ChatListParse(chats: [], failedLineCount: 1)))
        var snap = await started.engine.snapshot()
        XCTAssertEqual(snap.holdNotice, "chats_parse_failed")
        started.harness.clock.current = start.addingTimeInterval(30)
        await started.engine.applyChatList(.failed)
        started.harness.clock.current = start.addingTimeInterval(60)
        await started.engine.applyChatList(.failed)
        snap = await started.engine.snapshot()
        XCTAssertEqual(snap.holdNotice, "chats_parse_failed")
        XCTAssertEqual(started.harness.log.records.filter { $0.code == "chats_parse_failed" }.count, 1)
        XCTAssertEqual(started.harness.sender.sent.count, 0)
    }

    func testWaitingReasonSurvivesTheFetchGrace() async throws {
        let started = try transitionEngine()
        let start = started.harness.clock.current
        await started.engine.applyChatList(.parsed(ChatListParse(chats: [], failedLineCount: 0)))
        started.harness.replies.pages = [ReplyPage(
            replies: [routedReply("r-empty", chat: 7, text: "hello", guid: "origin")],
            nextCursor: nil
        )]
        await started.engine.pollReplies()
        var snap = await started.engine.snapshot()
        XCTAssertEqual(snap.holdNotice, "reply_held_empty_list")
        started.harness.clock.current = start.addingTimeInterval(30)
        await started.engine.applyChatList(.failed)
        started.harness.clock.current = start.addingTimeInterval(60)
        await started.engine.applyChatList(.failed)
        snap = await started.engine.snapshot()
        XCTAssertEqual(snap.holdNotice, "reply_held_empty_list")
        XCTAssertEqual(started.harness.sender.sent.count, 0)
    }
}

private func transitionEngine(routeTTL: Double? = nil) throws -> Started {
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

private func room(_ id: Int64, _ guid: String) -> ChatSummary {
    ChatSummary(id: id, title: "room", isGroup: false, guid: guid)
}
