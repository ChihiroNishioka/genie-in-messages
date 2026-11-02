import XCTest
@testable import GenieCore

/// 照合の表示が、ほかのエラーを消さず、待つ理由がなくなったら消えることを見る。
/// メニューの照合の行は SendHoldStatus.menuLine。最後のエラーとは別。
final class HoldNoticeLifetimeTests: XCTestCase {
    func testListFailureDoesNotReplaceAnotherError() async throws {
        let started = try makeEngine(allowedGuid: "chat-kept")
        await started.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        await started.engine.setLastError("messages_db_reset")
        await started.engine.noteChatsProblem(code: "chats_failed", updateMenu: false)
        await started.engine.noteChatsProblem(code: "chats_failed", updateMenu: false)
        let during = await started.engine.snapshot()
        XCTAssertEqual(during.lastError, "messages_db_reset")
        XCTAssertEqual(during.holdNotice, "chats_failed")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: during.holdNotice),
            "照合: トーク一覧を読めないため、返事を待っています"
        )
        let notes = started.harness.log.records.filter { $0.code == "chats_failed" }
        XCTAssertFalse(notes.isEmpty)
        XCTAssertTrue(notes.allSatisfy { $0.chatID == nil && $0.guid == nil && $0.rowid == nil })
        XCTAssertEqual(
            SendHoldStatus.text(for: "chats_failed"),
            "トーク一覧を読めないため、返事を待っています"
        )

        let saved = try makeEngine(allowedGuid: "chat-kept")
        await saved.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        saved.harness.state.shouldFailSave = true
        await saved.engine.setChatEnabled(7, guid: "chat-other", enabled: true)
        await saved.engine.pollReplies()
        let afterSave = await saved.engine.snapshot()
        XCTAssertEqual(saved.harness.sender.sent.count, 0)
        XCTAssertEqual(afterSave.lastError, "state_save_failed")
        XCTAssertEqual(afterSave.holdNotice, "reply_chat_guid_mismatch")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: afterSave.holdNotice),
            "照合: トークの識別子が変わったため、その返事は捨てました"
        )
        let mismatch = saved.harness.log.records.filter { $0.code == "reply_chat_guid_mismatch" }
        XCTAssertFalse(mismatch.isEmpty)
        XCTAssertTrue(mismatch.allSatisfy { $0.chatID == nil && $0.guid == nil && $0.rowid == nil })
        XCTAssertTrue(saved.harness.log.records.contains { $0.code == "state_save_failed" })
        XCTAssertEqual(
            SendHoldStatus.text(for: "reply_chat_guid_mismatch"),
            "トークの識別子が変わったため、その返事は捨てました"
        )
    }

    func testWaitingNoticeClearsWhenTheReplyExpiresOrTheListReturns() async throws {
        let expired = try makeEngine(allowedGuid: "chat-kept", routeTTL: 60)
        await expired.engine.reconcileChats([])
        await expired.engine.pollReplies()
        let waiting = await expired.engine.snapshot()
        XCTAssertNil(waiting.lastError)
        XCTAssertEqual(waiting.holdNotice, "reply_held_empty_list")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: waiting.holdNotice),
            "照合: トーク一覧が空のため、返事を待っています"
        )
        XCTAssertEqual(expired.harness.sender.sent.count, 0)

        expired.harness.clock.current = expired.harness.clock.current.addingTimeInterval(120)
        await expired.engine.pollReplies()
        let gone = await expired.engine.snapshot()
        XCTAssertEqual(expired.harness.sender.sent.count, 0)
        XCTAssertNil(gone.lastError)
        XCTAssertNil(gone.holdNotice)
        XCTAssertEqual(SendHoldStatus.menuLine(for: gone.holdNotice), "照合: なし")
        XCTAssertTrue(expired.harness.log.records.contains { $0.code == "reply_too_old" })

        let empty = try makeEngine(allowedGuid: "chat-kept")
        await empty.engine.reconcileChats([])
        await empty.engine.pollReplies()
        let emptyHeld = await empty.engine.snapshot()
        XCTAssertEqual(emptyHeld.holdNotice, "reply_held_empty_list")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: emptyHeld.holdNotice),
            "照合: トーク一覧が空のため、返事を待っています"
        )
        await empty.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        let listed = await empty.engine.snapshot()
        XCTAssertNil(listed.lastError)
        XCTAssertNil(listed.holdNotice)
        XCTAssertEqual(SendHoldStatus.menuLine(for: listed.holdNotice), "照合: なし")

        let missing = try makeEngine(allowedGuid: "chat-kept")
        await missing.engine.reconcileChats([
            ChatSummary(id: 99, title: "other", isGroup: false, guid: "someone-else"),
        ])
        await missing.engine.pollReplies()
        let missingHeld = await missing.engine.snapshot()
        XCTAssertEqual(missingHeld.holdNotice, "reply_held_not_in_list")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: missingHeld.holdNotice),
            "照合: 一覧に無いトークのため、返事を待っています。chats_limit を増やすと入ることがあります"
        )
        await missing.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        let found = await missing.engine.snapshot()
        XCTAssertNil(found.lastError)
        XCTAssertNil(found.holdNotice)
        XCTAssertEqual(SendHoldStatus.menuLine(for: found.holdNotice), "照合: なし")
    }

    func testSuccessfulRereadClearsTheListFailureAndKeepsAnotherError() async throws {
        let started = try makeEngine(allowedGuid: "chat-kept")
        await started.engine.setLastError("messages_db_reset")
        await started.engine.noteChatsProblem(code: "chats_failed", updateMenu: false)
        await started.engine.noteChatsProblem(code: "chats_failed", updateMenu: false)
        let during = await started.engine.snapshot()
        XCTAssertEqual(during.lastError, "messages_db_reset")
        XCTAssertEqual(during.holdNotice, "chats_failed")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: during.holdNotice),
            "照合: トーク一覧を読めないため、返事を待っています"
        )

        await started.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        let snap = await started.engine.snapshot()
        XCTAssertEqual(snap.lastError, "messages_db_reset")
        XCTAssertNil(snap.holdNotice)
        XCTAssertEqual(SendHoldStatus.menuLine(for: snap.holdNotice), "照合: なし")
        XCTAssertEqual(SendHoldStatus.text(for: snap.lastError), "なし")
        XCTAssertTrue(started.harness.log.records.contains { $0.code == "chats_failed" })
    }
}
