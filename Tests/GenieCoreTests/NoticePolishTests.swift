import XCTest
@testable import GenieCore

/// 照合の表示の残り方、ログの重なり、待つか捨てたかの文言、ランプを見る。
final class NoticePolishTests: XCTestCase {
    func testPartialParseFailureStaysVisibleAfterTheSameRead() async throws {
        let started = try makeEngine(allowedGuid: "chat-kept")
        await started.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        await started.engine.noteChatsProblem(code: "chats_parse_failed", updateMenu: false)
        await started.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        let during = await started.engine.snapshot()
        XCTAssertEqual(during.holdNotice, "chats_parse_failed")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: during.holdNotice),
            "照合: トーク一覧を読めないため、返事を待っています"
        )

        await started.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        let cleared = await started.engine.snapshot()
        XCTAssertNil(cleared.holdNotice)
        XCTAssertEqual(SendHoldStatus.menuLine(for: cleared.holdNotice), "照合: なし")
    }

    func testRepeatedChatListFailureIsLoggedOnce() async throws {
        let started = try makeEngine(allowedGuid: "chat-kept")
        await started.engine.noteChatsProblem(code: "chats_failed", updateMenu: false)
        await started.engine.noteChatsProblem(code: "chats_failed", updateMenu: true)
        let notes = started.harness.log.records.filter { $0.code == "chats_failed" }
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.level, "error")
        XCTAssertTrue(notes.allSatisfy { $0.chatID == nil && $0.guid == nil && $0.rowid == nil })
    }

    func testMenuWordingShowsWhetherTheReplyIsWaitingOrDiscarded() {
        XCTAssertEqual(
            SendHoldStatus.text(for: "reply_held_empty_list"),
            "トーク一覧が空のため、返事を待っています"
        )
        XCTAssertEqual(
            SendHoldStatus.text(for: "reply_held_not_in_list"),
            "一覧に無いトークのため、返事を待っています。chats_limit を増やすと入ることがあります"
        )
        XCTAssertEqual(
            SendHoldStatus.text(for: "chats_failed"),
            "トーク一覧を読めないため、返事を待っています"
        )
        XCTAssertEqual(
            SendHoldStatus.text(for: "reply_chat_guid_mismatch"),
            "トークの識別子が変わったため、その返事は捨てました"
        )
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: "reply_chat_guid_mismatch"),
            "照合: トークの識別子が変わったため、その返事は捨てました"
        )
    }

    func testHoldNoticeTurnsTheLampToAttention() {
        let snap = EngineSnapshot(
            paused: false,
            cursorRowID: 0,
            enabledChatIDs: [],
            haltedChatIDs: [],
            heldCount: 0,
            heldLockCount: 0,
            lastError: nil,
            holdNotice: "reply_held_empty_list",
            screenLocked: false,
            screenLock: .unlocked,
            replyFetchConfigured: true,
            webhookConfigured: true
        )
        XCTAssertTrue(LampAppearance.showsAttention(snap))
        var clear = snap
        clear.holdNotice = nil
        XCTAssertFalse(LampAppearance.showsAttention(clear))
    }
}
