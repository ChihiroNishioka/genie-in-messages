import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GenieCore

final class OutboundPollerTests: XCTestCase {
    func testOB01DisabledOutboundStillPollsAndSendsExistingReply() async throws {
        for json in ["{}", "{\"outbound_notion_data_source_id\":null}", "{\"outbound_notion_data_source_id\":\" \"}"] {
            let f = OutboundHarness()
            let decoded = try JSONDecoder().decode(GenieConfig.self, from: Data(json.utf8))
            f.provider.config.outboundNotionDataSourceID = decoded.outboundNotionDataSourceID
            f.provider.config.replyFetchURL = "https://example.com/replies"
            seedRoute(f.h, guid: "origin-0000", chat: 7)
            f.h.replies.pages = [ReplyPage(replies: [routedReply("reply-0000", chat: 7, text: "返事", guid: "origin-0000")], nextCursor: nil)]
            f.source.entries = [f.row()]
            let e = try f.engine()
            let reader = ScriptedChatLists(script: [parsed(f.chats)])
            let poller = makePoller(f, engine: e, reader: reader)
            _ = await poller.tick()
            XCTAssertEqual(f.source.fetchCount, 0)
            XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("返事")])
            XCTAssertEqual(f.h.replies.cursors.count, 1)
        }
    }

    func testOB13InitialListFailurePreventsFetchAndRecoveryTickSends() async throws {
        let f = OutboundHarness()
        f.source.entries = [f.row()]
        let e = try f.engine()
        let reader = ScriptedChatLists(script: [.failed, parsed(f.chats)])
        let poller = makePoller(f, engine: e, reader: reader)
        _ = await poller.tick()
        XCTAssertEqual(f.source.fetchCount, 0)
        XCTAssertTrue(f.h.sender.outgoing.isEmpty)
        XCTAssertTrue(f.h.sender.sent.isEmpty)
        await poller.requestChatsRefresh()
        _ = await poller.tick()
        XCTAssertEqual(f.source.fetchCount, 1)
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
    }

    func testOB35ReplyFailureContinuesOutboundAndUsesFetchCompletionSchedule() async throws {
        let f = OutboundHarness()
        f.provider.config.replyFetchURL = "https://example.com/replies"
        f.provider.config.replyPollIntervalSeconds = 10
        f.h.replies.failNext = true
        let source = TickOutboundSource()
        source.entries = [f.row()]
        source.onFetch = { f.h.clock.current = f.h.clock.current.addingTimeInterval(4) }
        let e = try makeEngine(f, source: source)
        let reader = ScriptedChatLists(script: [parsed(f.chats)])
        let poller = makePoller(f, engine: e, reader: reader)
        _ = await poller.tick()
        XCTAssertEqual(f.h.replies.cursors.count, 1)
        XCTAssertEqual(source.fetchCount, 1)
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
        XCTAssertTrue(f.h.log.records.contains { $0.code == "reply_fetch_failed" })
        _ = await poller.tick()
        XCTAssertEqual(source.fetchCount, 1)
        f.h.clock.current = f.h.clock.current.addingTimeInterval(9)
        _ = await poller.tick()
        XCTAssertEqual(source.fetchCount, 1)
        XCTAssertEqual(f.h.replies.cursors.count, 2)
        f.h.clock.current = f.h.clock.current.addingTimeInterval(1)
        _ = await poller.tick()
        XCTAssertEqual(source.fetchCount, 2)
        XCTAssertEqual(f.h.replies.cursors.count, 2)
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
    }

    func testOB35UnpauseAndDirectoryRecoveryPollBeforeInterval() async throws {
        let f = OutboundHarness()
        f.provider.config.replyPollIntervalSeconds = 60
        f.source.entries = [f.row()]
        let e = try f.engine()
        let reader = ScriptedChatLists(script: [parsed(f.chats), .failed, parsed(f.chats)])
        let poller = makePoller(f, engine: e, reader: reader)
        _ = await poller.tick()
        XCTAssertEqual(f.source.fetchCount, 1)
        await e.setPaused(true)
        f.h.clock.current = f.h.clock.current.addingTimeInterval(1)
        _ = await poller.tick()
        XCTAssertEqual(f.source.fetchCount, 1)
        await e.setPaused(false)
        _ = await poller.tick()
        XCTAssertEqual(f.source.fetchCount, 2)
        await poller.requestChatsRefresh()
        _ = await poller.tick()
        XCTAssertEqual(f.source.fetchCount, 2)
        await poller.requestChatsRefresh()
        _ = await poller.tick()
        XCTAssertEqual(f.source.fetchCount, 3)
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
    }

    func testOB11NotionAddressColumnsCannotOverrideConfiguredTargetThroughTick() async throws {
        let f = OutboundHarness()
        let at = ISO8601.string(from: f.h.clock.now())
        let properties: [String: Any] = [
            "idempotency_key": property("title", "key-0000"),
            "target": property("rich_text", "family"),
            "text": property("rich_text", "お知らせ"),
            "created_at": ["type": "created_time", "created_time": at],
            "chat_id": ["type": "number", "number": 8],
            "guid": property("rich_text", OutboundHarness.owner),
            "in_reply_to_guid": property("rich_text", "origin-0000"),
        ]
        let object: [String: Any] = ["results": [["id": "page-0000", "created_time": at, "properties": properties]], "has_more": false]
        let body = try JSONSerialization.data(withJSONObject: object)
        let transport = ScriptedNotion(responses: [NotionHTTPResponse(status: 200, headers: [:], body: body)])
        let source = NotionOutboundSource(dataSourceID: f.provider.config.outboundNotionDataSourceID,
            secrets: StaticSecret(webhook: "dummy", reply: nil, notion: "dummy"), clock: f.h.clock,
            pageLimit: 100, transport: transport, pace: NotionPace())
        let e = try makeEngine(f, source: source)
        let reader = ScriptedChatLists(script: [parsed(f.chats)])
        let poller = makePoller(f, engine: e, reader: reader)
        _ = await poller.tick()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(f.h.sender.outgoing.map(\.chatID), [7, 7])
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("お知らせ")])
        XCTAssertTrue(f.h.state.state.routes.isEmpty)
    }


}

private final class TickOutboundSource: OutboundSource, @unchecked Sendable {
    var entries: [FetchedOutbound] = []
    var fetchCount = 0
    var onFetch: (() async -> Void)?

    func fetch(cursor: String?, skipping pageIDs: Set<String>, holding heldPageIDs: Set<String>) async throws -> OutboundPage {
        fetchCount += 1
        await onFetch?()
        return OutboundPage(entries: entries, nextCursor: cursor)
    }
}

private func property(_ type: String, _ text: String) -> [String: Any] {
    ["type": type, type: [["type": "text", "plain_text": text]]]
}

private func parsed(_ chats: [ChatSummary]) -> ChatListRead {
    .parsed(ChatListParse(chats: chats, failedLineCount: 0))
}

private func makePoller(_ fixture: OutboundHarness, engine: GenieEngine, reader: ScriptedChatLists) -> GeniePoller {
    GeniePoller(engine: engine, reader: reader, configProvider: fixture.provider, clock: fixture.h.clock, stop: fixture.h.stop)
}

private func makeEngine(_ fixture: OutboundHarness, source: any OutboundSource) throws -> GenieEngine {
    try GenieEngine(configProvider: fixture.provider, initialConfig: fixture.provider.config,
        stateStore: fixture.h.state, allowlistStore: fixture.h.allow, replySource: fixture.h.replies,
        outboundSource: source, sender: fixture.h.sender, markerImage: fixture.h.markerImage,
        webhook: fixture.h.webhook, secrets: fixture.h.secrets, lock: fixture.h.lock,
        clock: fixture.h.clock, log: fixture.h.log, stop: fixture.h.stop)
}
