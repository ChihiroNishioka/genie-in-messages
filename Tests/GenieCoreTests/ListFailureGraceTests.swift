import XCTest
@testable import GenieCore

/// 取得失敗の猶予と、一覧の状態の移り変わり。いまの回数判定では落ちる。
final class ListFailureGraceTests: XCTestCase {
    func testThreeFailuresAtTheSameMomentStayQuiet() async throws {
        let started = try graceEngine()
        await started.engine.applyChatList(.failed)
        await started.engine.applyChatList(.failed)
        await started.engine.applyChatList(.failed)
        let snap = await started.engine.snapshot()
        XCTAssertNil(snap.holdNotice)
        XCTAssertEqual(SendHoldStatus.menuLine(for: snap.holdNotice), "照合: なし")
        let notes = started.harness.log.records.filter { $0.code == "chats_failed" }
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.level, "error")
        XCTAssertTrue(notes.allSatisfy { $0.chatID == nil && $0.guid == nil && $0.rowid == nil })
        XCTAssertEqual(started.harness.sender.sent.count, 0)
    }

    func testShortOutageNeverShowsChatsFailed() async throws {
        let started = try graceEngine()
        await started.engine.applyChatList(.parsed(verifiedList()))
        started.harness.clock.current = started.harness.clock.current.addingTimeInterval(30)
        await started.engine.applyChatList(.failed)
        await started.engine.applyChatList(.failed)
        var snap = await started.engine.snapshot()
        XCTAssertNotEqual(snap.holdNotice, "chats_failed")
        started.harness.replies.pages = [ReplyPage(
            replies: [routedReply("r-during", chat: 7, text: "hello", guid: "origin")],
            nextCursor: nil
        )]
        started.harness.clock.current = started.harness.clock.current.addingTimeInterval(10)
        await started.engine.pollReplies()
        XCTAssertEqual(started.harness.sender.sent.count, 0)
        started.harness.clock.current = started.harness.clock.current.addingTimeInterval(20)
        await started.engine.applyChatList(.parsed(verifiedList()))
        started.harness.replies.pages = [ReplyPage(
            replies: [routedReply("r-during", chat: 7, text: "hello", guid: "origin")],
            nextCursor: nil
        )]
        await started.engine.pollReplies()
        snap = await started.engine.snapshot()
        XCTAssertNotEqual(snap.holdNotice, "chats_failed")
        XCTAssertEqual(started.harness.sender.sent.count, 1)
        XCTAssertEqual(started.harness.log.records.filter { $0.code == "chats_failed" }.count, 1)
    }

    func testGraceBoundaryIsSixtySecondsFromTheFirstFailure() async throws {
        let started = try graceEngine()
        let start = started.harness.clock.current
        await started.engine.applyChatList(.parsed(verifiedList()))
        started.harness.clock.current = start.addingTimeInterval(30)
        await started.engine.applyChatList(.failed)
        started.harness.clock.current = start.addingTimeInterval(60)
        await started.engine.applyChatList(.failed)
        var snap = await started.engine.snapshot()
        XCTAssertNil(snap.holdNotice)
        started.harness.clock.current = start.addingTimeInterval(89.999)
        snap = await started.engine.snapshot()
        XCTAssertNil(snap.holdNotice)
        started.harness.clock.current = start.addingTimeInterval(90)
        snap = await started.engine.snapshot()
        XCTAssertEqual(snap.holdNotice, "chats_failed")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: snap.holdNotice),
            "照合: トーク一覧を読めないため、返事を待っています"
        )
    }

    func testRecoveryStartsANewGracePeriod() async throws {
        let started = try graceEngine()
        let start = started.harness.clock.current
        await started.engine.applyChatList(.failed)
        started.harness.clock.current = start.addingTimeInterval(30)
        await started.engine.applyChatList(.failed)
        started.harness.clock.current = start.addingTimeInterval(60)
        var snap = await started.engine.snapshot()
        XCTAssertEqual(snap.holdNotice, "chats_failed")
        started.harness.clock.current = start.addingTimeInterval(62)
        await started.engine.applyChatList(.parsed(verifiedList()))
        snap = await started.engine.snapshot()
        XCTAssertNil(snap.holdNotice)
        started.harness.clock.current = start.addingTimeInterval(90)
        await started.engine.applyChatList(.failed)
        started.harness.clock.current = start.addingTimeInterval(120)
        await started.engine.applyChatList(.failed)
        snap = await started.engine.snapshot()
        XCTAssertNil(snap.holdNotice)
        started.harness.clock.current = start.addingTimeInterval(150)
        snap = await started.engine.snapshot()
        XCTAssertEqual(snap.holdNotice, "chats_failed")
        XCTAssertEqual(started.harness.log.records.filter { $0.code == "chats_failed" }.count, 2)
    }

    func testPartialSuccessUsesASeparateSentenceWhenTheChatIsVerified() async throws {
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: "chats_parse_partial_ok"),
            "照合: 一覧の一部の行を読めませんでした。許可したトークは一覧で確かめられました"
        )
        let started = try graceEngine()
        await started.engine.applyChatList(.parsed(ChatListParse(chats: [room(7, "chat-kept")], failedLineCount: 1)))
        let snap = await started.engine.snapshot()
        XCTAssertEqual(snap.holdNotice, "chats_parse_partial_ok")
        XCTAssertEqual(started.harness.sender.sent.count, 0)
    }
}

private func graceEngine() throws -> Started {
    let harness = Harness()
    harness.allow.ids = [7]
    harness.allow.guids = [7: "chat-kept"]
    harness.config.replyFetchURL = "https://127.0.0.1/replies"
    seedRoute(harness, guid: "origin", chat: 7)
    let engine = try harness.engine()
    return Started(harness: harness, engine: engine, replies: CountingReplies(page: ReplyPage(replies: [], nextCursor: nil)))
}

private func room(_ id: Int64, _ guid: String) -> ChatSummary {
    ChatSummary(id: id, title: "room", isGroup: false, guid: guid)
}

private func verifiedList() -> ChatListParse {
    ChatListParse(chats: [room(7, "chat-kept")], failedLineCount: 0)
}
