import XCTest
@testable import GenieCore

final class GroupNoticeTests: XCTestCase {
    func testNotGroupNoticeRecommendsReviewingConfigInsteadOfIncreasingListLimit() async throws {
        let harness = Harness()
        harness.config.groupChatGUIDs = ["direct-chat"]
        let engine = try harness.engine()
        await engine.showChats([ChatSummary(id: 42, title: "direct", isGroup: false, guid: "direct-chat")])
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.configGroupNotFound, 0)
        XCTAssertEqual(snapshot.configGroupNotGroup, 1)
        let notice = try XCTUnwrap(configGroupNotice(notFound: snapshot.configGroupNotFound, notGroup: snapshot.configGroupNotGroup))
        XCTAssertTrue(notice.contains("1 件"))
        XCTAssertTrue(notice.contains("グループではありません"))
        XCTAssertTrue(notice.contains("設定を見直してください"))
        XCTAssertFalse(notice.contains("chats_limit"))
        XCTAssertFalse(notice.contains("direct-chat"))
    }
    func testMixedUnresolvedNoticeKeepsEachCountAndAdviceWithoutGUIDs() async throws {
        let harness = Harness()
        let missing = ["missing-one", "missing-two"]
        let direct = ["direct-one", "self-chat", "direct-three"]
        harness.config.groupChatGUIDs = missing + direct
        let engine = try harness.engine()
        await engine.showChats(direct.enumerated().map { index, guid in
            ChatSummary(id: Int64(index + 1), title: "direct", isGroup: false, guid: guid)
        })
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.configGroupNotFound, 2)
        XCTAssertEqual(snapshot.configGroupNotGroup, 3)
        XCTAssertEqual(snapshot.configGroupUnresolved, 5)
        let notice = try XCTUnwrap(configGroupNotice(notFound: snapshot.configGroupNotFound, notGroup: snapshot.configGroupNotGroup))
        XCTAssertTrue(notice.contains("2 件が一覧に見つかりません"))
        XCTAssertTrue(notice.contains("3 件はグループではありません"))
        XCTAssertTrue(notice.contains("chats_limit"))
        XCTAssertTrue(notice.contains("設定を見直してください"))
        for guid in missing + direct { XCTAssertFalse(notice.contains(guid)) }
    }
}
