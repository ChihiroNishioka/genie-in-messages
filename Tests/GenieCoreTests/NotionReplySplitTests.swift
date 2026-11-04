import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import GenieCore

extension NotionReplyTests {
    func testWaitingSameChatRepliesDoNotBlockAnotherChat() async {
        let h = Harness()
        h.allow.ids = [1, 2]
        h.config.notionDataSourceID = "11111111-1111-4111-8111-111111111111"
        h.config.replyFetchURL = ""
        let origin = ISO8601.date(from: NotionCursor.freshStart(now: h.clock.now())) ?? h.clock.now()
        var rows: [[String: Any]] = []
        for index in 0..<101 {
            let id = String(format: "h%03d", index)
            let guid = String(format: "g%03d", index)
            let created = ISO8601.string(from: origin.addingTimeInterval(Double(index)))
            seedRoute(h, guid: guid, chat: 1)
            rows.append([
                "object": "page", "id": "page-\(id)", "created_time": created,
                "properties": [
                    "reply_id": ["type": "title", "title": [["plain_text": id]]],
                    "created_at": ["type": "created_time", "created_time": created],
                    "chat_id": ["type": "number", "number": 1],
                    "in_reply_to_guid": ["type": "rich_text", "rich_text": [["plain_text": guid]]],
                    "text": ["type": "rich_text", "rich_text": [["plain_text": "held"]]],
                ],
            ])
        }
        let otherCreated = ISO8601.string(from: origin.addingTimeInterval(300))
        seedRoute(h, guid: "g-other", chat: 2)
        rows.append([
            "object": "page", "id": "page-other", "created_time": otherCreated,
            "properties": [
                "reply_id": ["type": "title", "title": [["plain_text": "other"]]],
                "created_at": ["type": "created_time", "created_time": otherCreated],
                "chat_id": ["type": "number", "number": 2],
                "in_reply_to_guid": ["type": "rich_text", "rich_text": [["plain_text": "g-other"]]],
                "text": ["type": "rich_text", "rich_text": [["plain_text": "other-chat"]]],
            ],
        ])
        let transport = DatasetNotion(rows: rows)
        let source = NotionReplySource(
            dataSourceID: h.config.notionDataSourceID,
            secrets: StaticSecret(webhook: "hook-secret", reply: nil, notion: "x"),
            clock: h.clock,
            pageLimit: 100,
            transport: transport
        )
        h.sender.script = [.success(SendReceipt(id: 1, guid: "sent-1", status: "sent")), .failure(.notStarted)]
        do {
            let engine = try GenieEngine(
                configProvider: StaticConfig(config: h.config), initialConfig: h.config,
                stateStore: h.state, allowlistStore: h.allow, replySource: source,
                sender: h.sender, webhook: h.webhook, secrets: h.secrets,
                lock: h.lock, clock: h.clock, log: h.log
            )
            await engine.showChats(h.verifiedChatList())
            await engine.pollReplies()
            await engine.pollReplies()
            await engine.pollReplies()
            let otherTexts = h.sender.sent.filter { $0.chatID == 2 }.map(\.text)
            let sameChatCount = h.sender.sent.filter { $0.chatID == 1 }.count
            XCTAssertEqual(otherTexts, [M, "other-chat"])
            XCTAssertEqual(sameChatCount, 2)
        } catch { XCTFail("engine setup failed: \(error)") }
    }
}
