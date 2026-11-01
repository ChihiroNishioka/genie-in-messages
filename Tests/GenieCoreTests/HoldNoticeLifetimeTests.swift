import XCTest
@testable import GenieCore

/// 照合の表示が、ほかのエラーを消さず、待つ理由がなくなったら消えることを見る。
/// メニューに出る文は SendHoldStatus.text。いまは最後のエラーのコードから作る。
final class HoldNoticeLifetimeTests: XCTestCase {
    func testListFailureDoesNotReplaceAnotherError() async throws {
        let started = try makeEngine(allowedGuid: "chat-kept")
        await started.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        await started.engine.setLastError("messages_db_reset")
        await started.engine.noteChatsProblem(code: "chats_failed", updateMenu: false)
        let during = await started.engine.snapshot()
        XCTAssertEqual(during.lastError, "messages_db_reset")
        XCTAssertEqual(SendHoldStatus.text(for: during.lastError), "なし")
        let notes = started.harness.log.records.filter { $0.code == "chats_failed" }
        XCTAssertFalse(notes.isEmpty)
        XCTAssertTrue(notes.allSatisfy { $0.chatID == nil && $0.guid == nil && $0.rowid == nil })
        XCTAssertEqual(
            SendHoldStatus.text(for: "chats_failed"),
            "トーク一覧を読めないため、返事を送っていません"
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
        XCTAssertEqual(SendHoldStatus.text(for: afterSave.lastError), "なし")
        let mismatch = saved.harness.log.records.filter { $0.code == "reply_chat_guid_mismatch" }
        XCTAssertFalse(mismatch.isEmpty)
        XCTAssertTrue(mismatch.allSatisfy { $0.chatID == nil && $0.guid == nil && $0.rowid == nil })
        XCTAssertTrue(saved.harness.log.records.contains { $0.code == "state_save_failed" })
        XCTAssertEqual(
            SendHoldStatus.text(for: "reply_chat_guid_mismatch"),
            "トークの識別子が変わったため、返事を送っていません"
        )
    }

    func testWaitingNoticeClearsWhenTheReplyExpiresOrTheListReturns() async throws {
        let expired = try makeEngine(allowedGuid: "chat-kept", routeTTL: 60)
        await expired.engine.reconcileChats([])
        await expired.engine.pollReplies()
        let waiting = await expired.engine.snapshot()
        XCTAssertEqual(waiting.lastError, "reply_held_empty_list")
        XCTAssertEqual(
            SendHoldStatus.text(for: waiting.lastError),
            "トーク一覧が空のため、返事を送っていません"
        )
        XCTAssertEqual(expired.harness.sender.sent.count, 0)

        expired.harness.clock.current = expired.harness.clock.current.addingTimeInterval(120)
        await expired.engine.pollReplies()
        let gone = await expired.engine.snapshot()
        XCTAssertEqual(expired.harness.sender.sent.count, 0)
        XCTAssertNil(gone.lastError)
        XCTAssertEqual(SendHoldStatus.text(for: gone.lastError), "なし")
        XCTAssertTrue(expired.harness.log.records.contains { $0.code == "reply_too_old" })

        let empty = try makeEngine(allowedGuid: "chat-kept")
        await empty.engine.reconcileChats([])
        await empty.engine.pollReplies()
        let emptyHeld = await empty.engine.snapshot()
        XCTAssertEqual(emptyHeld.lastError, "reply_held_empty_list")
        await empty.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        let listed = await empty.engine.snapshot()
        XCTAssertNil(listed.lastError)
        XCTAssertEqual(SendHoldStatus.text(for: listed.lastError), "なし")

        let missing = try makeEngine(allowedGuid: "chat-kept")
        await missing.engine.reconcileChats([
            ChatSummary(id: 99, title: "other", isGroup: false, guid: "someone-else"),
        ])
        await missing.engine.pollReplies()
        let missingHeld = await missing.engine.snapshot()
        XCTAssertEqual(missingHeld.lastError, "reply_held_not_in_list")
        XCTAssertEqual(
            SendHoldStatus.text(for: missingHeld.lastError),
            "一覧に無いトークのため、返事を送っていません"
        )
        await missing.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        let found = await missing.engine.snapshot()
        XCTAssertNil(found.lastError)
        XCTAssertEqual(SendHoldStatus.text(for: found.lastError), "なし")
    }

    func testSuccessfulRereadClearsTheListFailureAndKeepsAnotherError() async throws {
        let started = try makeEngine(allowedGuid: "chat-kept")
        await started.engine.setLastError("messages_db_reset")
        await started.engine.noteChatsProblem(code: "chats_failed", updateMenu: false)
        let during = await started.engine.snapshot()
        XCTAssertEqual(during.lastError, "messages_db_reset")
        XCTAssertEqual(SendHoldStatus.text(for: during.lastError), "なし")

        await started.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        let snap = await started.engine.snapshot()
        XCTAssertEqual(snap.lastError, "messages_db_reset")
        XCTAssertEqual(SendHoldStatus.text(for: snap.lastError), "なし")
        XCTAssertTrue(started.harness.log.records.contains { $0.code == "chats_failed" })
    }
}
