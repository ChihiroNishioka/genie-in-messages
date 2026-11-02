import XCTest
@testable import GenieCore

/// 一部の行だけ読めなかったときは、「返事を待っています」と出さない。
final class PartialParseWordingTests: XCTestCase {
    func testPartialUnreadLinesDoNotSayAReplyIsWaiting() async throws {
        let harness = Harness()
        harness.allow.ids = [7]
        harness.allow.guids = [7: "chat-kept"]
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        let engine = try harness.engine()
        _ = await engine.applyChatList(.parsed(ChatListParse(
            chats: [ChatSummary(id: 8, title: "room", isGroup: false, guid: "someone-else")],
            failedLineCount: 1
        )))
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.holdNotice, "chats_parse_failed")
        XCTAssertEqual(
            SendHoldStatus.menuLine(for: snap.holdNotice),
            "照合: 一覧の行を読めなかったため、照合できていません"
        )
        XCTAssertFalse(SendHoldStatus.menuLine(for: snap.holdNotice).contains("返事を待っています"))
        XCTAssertEqual(harness.sender.sent.count, 0)
    }
}
