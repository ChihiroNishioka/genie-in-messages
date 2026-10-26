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

        let outside = AllowlistOrdering.rows(chats: chats, enabledIDs: [21, 250], query: "")
        XCTAssertEqual(outside.first?.id, 250)
        XCTAssertEqual(outside.first?.title, "id:250（一覧外）")
        XCTAssertEqual(outside.first?.kindLabel, "一覧外")
        XCTAssertTrue(outside.first?.enabled == true)
        XCTAssertEqual(outside.dropFirst().first?.id, 21)
        let foundOutside = AllowlistOrdering.rows(chats: chats, enabledIDs: [250], query: "250")
        XCTAssertEqual(foundOutside.map(\.id), [250])
    }

    func testTwoQuickTogglesReturnToOff() async throws {
        let harness = Harness()
        let engine = try harness.engine()
        async let first: Void = engine.toggleChat(id: 21, guid: "g21")
        async let second: Void = engine.toggleChat(id: 21, guid: "g21")
        _ = await (first, second)
        let snap = await engine.snapshot()
        XCTAssertFalse(snap.enabledChatIDs.contains(21))
        await engine.toggleChat(id: 21, guid: "g21")
        let on = await engine.snapshot()
        XCTAssertEqual(on.enabledChatIDs, [21])
    }

    func testOutsideToggleKeepsTheKnownGuid() async throws {
        let harness = Harness()
        let engine = try harness.engine()
        await engine.reconcileChats([
            ChatSummary(id: 21, title: "自分", isGroup: false, guid: "guid-21"),
        ])
        await engine.setChatEnabled(21, guid: "guid-21", enabled: true)
        await engine.toggleChat(id: 21, guid: "")
        await engine.toggleChat(id: 21, guid: "")
        XCTAssertEqual(harness.allow.guids[21], "guid-21")
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.enabledChatIDs, [21])
    }
}