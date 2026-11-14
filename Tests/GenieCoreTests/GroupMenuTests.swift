import XCTest
@testable import GenieCore

final class GroupMenuTests: XCTestCase {
    func testConfigGroupRowsAreEnabledAndLockedWithoutMenuPermission() {
        let chats = [
            ChatSummary(id: 42, title: "家族", isGroup: true, guid: "iMessage;+;chat000000000000000001"),
            ChatSummary(id: 21, title: "オーナー", isGroup: false, guid: "direct-chat"),
        ]
        let rows = AllowlistOrdering.rows(chats: chats, enabledIDs: [21], query: "", configIDs: [42])
        XCTAssertEqual(rows.map(\.id), [21, 42])
        XCTAssertTrue(rows[0].enabled)
        XCTAssertFalse(rows[0].configLocked)
        XCTAssertEqual(rows[0].kindLabel, "1対1")
        XCTAssertTrue(rows[1].enabled)
        XCTAssertTrue(rows[1].configLocked)
        XCTAssertEqual(rows[1].kindLabel, "グループ（設定）")
        XCTAssertFalse(rows[1].kindLabel.contains(chats[0].guid))
        let menuOnly = AllowlistOrdering.rows(chats: chats, enabledIDs: [42], query: "")
        XCTAssertFalse(menuOnly.first?.configLocked ?? true)
        XCTAssertEqual(menuOnly.first?.kindLabel, "グループ")
    }

    func testConfigGroupOutsideListRemainsVisibleAndLocked() {
        let rows = AllowlistOrdering.rows(chats: [], enabledIDs: [], query: "42", configIDs: [42])
        XCTAssertEqual(rows.map(\.id), [42])
        XCTAssertEqual(rows.first?.kindLabel, "グループ（設定）")
        XCTAssertEqual(rows.first?.enabled, true)
        XCTAssertEqual(rows.first?.configLocked, true)
        XCTAssertEqual(rows.first?.title, "id:42（一覧外）")
    }

    func testUnresolvedGroupNoticeContainsOnlyCountAndAdvice() {
        XCTAssertNil(configGroupNotice(notFound: 0, notGroup: 0))
        XCTAssertEqual(configGroupNotice(notFound: 2, notGroup: 0), "設定のグループ 2 件が一覧に見つかりません（chats_limit を増やすと入ることがあります）")
    }

    func testGroupNoticeDoesNotChangeLampState() {
        let snapshot = EngineSnapshot(
            paused: false, cursorRowID: 0, enabledChatIDs: [42], haltedChatIDs: [],
            heldCount: 0, heldLockCount: 0, lastError: nil, holdNotice: nil,
            screenLocked: false, screenLock: .unlocked, replyFetchConfigured: true,
            webhookConfigured: true, configChatIDs: [42], configGroupUnresolved: 2
        )
        XCTAssertEqual(snapshot.configChatIDs, [42])
        XCTAssertEqual(snapshot.configGroupUnresolved, 2)
        XCTAssertEqual(LampIcon.appearance(for: snapshot), .running)
    }
}
