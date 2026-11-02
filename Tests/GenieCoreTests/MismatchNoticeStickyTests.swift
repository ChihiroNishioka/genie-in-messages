import XCTest
@testable import GenieCore

/// guid が違って捨てた返事の表示は、ほかの理由で上書きされても、guid が合うまで戻る。
final class MismatchNoticeStickyTests: XCTestCase {
    func testMismatchNoticeReturnsAfterTheListIsReread() async throws {
        let started = try makeEngine(allowedGuid: "chat-kept")
        await started.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        await started.engine.setChatEnabled(7, guid: "chat-other", enabled: true)
        await started.engine.pollReplies()
        let mismatched = await started.engine.snapshot()
        XCTAssertEqual(started.harness.sender.sent.count, 0)
        XCTAssertEqual(mismatched.holdNotice, "reply_chat_guid_mismatch")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: mismatched.holdNotice),
            "照合: トークの識別子が変わったため、その返事は捨てました"
        )

        await started.engine.noteChatsProblem(code: "chats_failed")
        await started.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        let reread = await started.engine.snapshot()
        XCTAssertEqual(started.harness.sender.sent.count, 0)
        XCTAssertEqual(reread.holdNotice, "reply_chat_guid_mismatch")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: reread.holdNotice),
            "照合: トークの識別子が変わったため、その返事は捨てました"
        )
        XCTAssertNotEqual(SendHoldStatus.menuLine(for: reread.holdNotice), "照合: なし")

        await started.engine.setChatEnabled(7, guid: "chat-kept", enabled: true)
        await started.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        let matched = await started.engine.snapshot()
        XCTAssertNil(matched.holdNotice)
        XCTAssertEqual(SendHoldStatus.menuLine(for: matched.holdNotice), "照合: なし")
        XCTAssertEqual(started.harness.sender.sent.count, 0)
    }

    func testMismatchNoticeReturnsAfterAnotherReplyOverwritesIt() async throws {
        let harness = Harness()
        harness.allow.ids = [7]
        harness.allow.guids = [7: "chat-kept"]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        harness.config.routeTTLSeconds = 60
        seedRoute(harness, guid: "origin", chat: 7)
        harness.replies.pages = [
            ReplyPage(
                replies: [routedReply("r-mismatch", chat: 7, text: "hello", guid: "origin")],
                nextCursor: nil
            ),
            ReplyPage(
                replies: [routedReply("r-other", chat: 7, text: "later", guid: "origin")],
                nextCursor: nil
            ),
        ]
        let engine = try harness.engine()
        await engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        await engine.setChatEnabled(7, guid: "chat-other", enabled: true)
        await engine.pollReplies()
        let mismatched = await engine.snapshot()
        XCTAssertEqual(harness.sender.sent.count, 0)
        XCTAssertEqual(mismatched.holdNotice, "reply_chat_guid_mismatch")

        await engine.reconcileChats([])
        await engine.pollReplies()
        let overwritten = await engine.snapshot()
        XCTAssertEqual(overwritten.holdNotice, "reply_held_empty_list")
        XCTAssertEqual(harness.sender.sent.count, 0)

        harness.replies.pages = [
            ReplyPage(
                replies: [routedReply("r-other", chat: 7, text: "later", guid: "origin")],
                nextCursor: nil
            ),
        ]
        harness.clock.current = harness.clock.current.addingTimeInterval(120)
        await engine.pollReplies()
        let restored = await engine.snapshot()
        XCTAssertEqual(harness.sender.sent.count, 0)
        XCTAssertEqual(restored.holdNotice, "reply_chat_guid_mismatch")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: restored.holdNotice),
            "照合: トークの識別子が変わったため、その返事は捨てました"
        )
        XCTAssertNotEqual(SendHoldStatus.menuLine(for: restored.holdNotice), "照合: なし")
        XCTAssertTrue(harness.log.records.contains { record in
            record.code == "reply_chat_guid_mismatch"
                && record.chatID == nil
                && record.guid == nil
                && record.rowid == nil
        })
    }
}
