import XCTest
@testable import GenieCore

/// 照合できずに返事を送らなかった理由が、状態とログから見えることを見る。
final class UnverifiedSendNoticeTests: XCTestCase {
    func testEmptyListShowsWhyTheReplyWasHeld() async throws {
        let started = try makeEngine(allowedGuid: "chat-kept")
        await started.engine.reconcileChats([])
        await started.engine.pollReplies()
        await assertHeld(
            started,
            code: "reply_held_empty_list",
            status: "トーク一覧が空のため、返事を待っています"
        )
    }

    func testChatMissingFromListShowsWhyTheReplyWasHeld() async throws {
        let started = try makeEngine(allowedGuid: "chat-kept")
        await started.engine.reconcileChats([
            ChatSummary(id: 99, title: "other", isGroup: false, guid: "someone-else"),
        ])
        await started.engine.pollReplies()
        await assertHeld(
            started,
            code: "reply_held_not_in_list",
            status: "一覧に無いトークのため、返事を待っています。chats_limit を増やすと入ることがあります"
        )
    }

    func testFailedChatFetchShowsOnTheStatusEvenWhenTheCallerHidesIt() async throws {
        let started = try makeEngine(allowedGuid: "chat-kept")
        await started.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-kept"),
        ])
        await started.engine.noteChatsProblem(code: "chats_failed", updateMenu: false)
        let snap = await started.engine.snapshot()
        XCTAssertEqual(started.harness.sender.sent.count, 0)
        XCTAssertNil(snap.lastError)
        XCTAssertEqual(snap.holdNotice, "chats_failed")
        XCTAssertEqual(SendHoldStatus.text(for: snap.holdNotice), "トーク一覧を読めないため、返事を待っています")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: snap.holdNotice),
            "照合: トーク一覧を読めないため、返事を待っています"
        )
        let notes = started.harness.log.records.filter { $0.code == "chats_failed" }
        XCTAssertFalse(notes.isEmpty)
        XCTAssertTrue(notes.allSatisfy { $0.chatID == nil && $0.guid == nil && $0.rowid == nil })
    }

    func testDifferentGuidShowsWhyTheReplyWasHeldWithoutIdentifiers() async throws {
        let started = try makeEngine(allowedGuid: "chat-kept")
        await started.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: true, guid: "chat-kept"),
        ])
        await started.engine.setChatEnabled(7, guid: "chat-other", enabled: true)
        await started.engine.pollReplies()
        await assertHeld(
            started,
            code: "reply_chat_guid_mismatch",
            status: "トークの識別子が変わったため、その返事は捨てました"
        )
    }
}

private func assertHeld(
    _ started: Started,
    code: String,
    status: String,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let snap = await started.engine.snapshot()
    XCTAssertEqual(started.harness.sender.sent.count, 0, file: file, line: line)
    XCTAssertNil(snap.lastError, file: file, line: line)
    XCTAssertEqual(snap.holdNotice, code, file: file, line: line)
    XCTAssertEqual(SendHoldStatus.text(for: snap.holdNotice), status, file: file, line: line)
    XCTAssertEqual(SendHoldStatus.menuLine(for: snap.holdNotice), "照合: \(status)", file: file, line: line)
    let notes = started.harness.log.records.filter { $0.code == code }
    XCTAssertFalse(notes.isEmpty, file: file, line: line)
    XCTAssertTrue(notes.allSatisfy { $0.chatID == nil && $0.guid == nil && $0.rowid == nil }, file: file, line: line)
    for note in notes {
        XCTAssertFalse(note.code.contains("chat-kept"), file: file, line: line)
        XCTAssertFalse((note.guid ?? "").contains("chat-"), file: file, line: line)
        XCTAssertFalse((note.detail ?? "").contains("chat-"), file: file, line: line)
    }
}
