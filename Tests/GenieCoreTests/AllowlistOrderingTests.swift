import XCTest
@testable import GenieCore

final class AllowlistOrderingTests: XCTestCase {
    func testEnabledAndDirectChatsLeadAndSearchFindsAnID() {
        var chats: [ChatSummary] = []
        for id in 1...100 {
            chats.append(ChatSummary(
                id: Int64(id),
                title: "トーク \(id)",
                isGroup: id % 2 == 0,
                guid: "g\(id)"
            ))
        }
        let idle = AllowlistOrdering.rows(chats: chats, enabledIDs: [], query: "")
        XCTAssertEqual(idle.count, 100)
        XCTAssertTrue(idle.allSatisfy { !$0.enabled })
        XCTAssertEqual(idle.first?.kindLabel, "1対1")

        let rows = AllowlistOrdering.rows(chats: chats, enabledIDs: [40, 21], query: "")
        XCTAssertEqual(rows.prefix(2).map(\.id), [21, 40])
        XCTAssertEqual(rows[0].kindLabel, "1対1")
        XCTAssertEqual(rows[1].kindLabel, "グループ")
        XCTAssertTrue(rows[0].enabled)
        XCTAssertTrue(rows[1].enabled)
        XCTAssertFalse(rows[2].enabled)

        let found = AllowlistOrdering.rows(chats: chats, enabledIDs: [], query: "21")
        XCTAssertEqual(found.map(\.id), [21])
        XCTAssertEqual(found.first?.kindLabel, "1対1")
        XCTAssertFalse(found.first?.enabled ?? true)

        let named = AllowlistOrdering.rows(
            chats: [ChatSummary(id: 8, title: "Family", isGroup: false, guid: "")] + chats,
            enabledIDs: [],
            query: "fam"
        )
        XCTAssertEqual(named.map(\.id), [8])
    }
}