import XCTest
@testable import GenieCore

/// 起動直後の返事が、トークの照合より先に送られないことを、送信の有無で見る。
final class StartupSendTests: XCTestCase {
    func testReplyIsNotSentBeforeTheFirstChatCheckOrToADifferentGuid() async throws {
        let early = try makeEngine(allowedGuid: "chat-kept")
        await early.engine.pollReplies()
        XCTAssertEqual(early.replies.fetches, 0)
        XCTAssertTrue(early.harness.sender.sent.isEmpty)

        let swapped = try makeEngine(allowedGuid: "chat-old")
        await swapped.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: true, guid: "chat-new"),
        ])
        await swapped.engine.pollReplies()
        XCTAssertTrue(swapped.harness.sender.sent.isEmpty)

        let same = try makeEngine(allowedGuid: "chat-same")
        await same.engine.reconcileChats([
            ChatSummary(id: 7, title: "room", isGroup: true, guid: "chat-same"),
        ])
        await same.engine.pollReplies()
        XCTAssertEqual(same.harness.sender.sent.map(\.chatID), [7])
    }
}

private struct Started {
    var harness: Harness
    var engine: GenieEngine
    var replies: CountingReplies
}

private func makeEngine(allowedGuid: String) throws -> Started {
    let harness = Harness()
    harness.allow.ids = [7]
    harness.allow.guids = [7: allowedGuid]
    harness.config.replyFetchURL = "https://127.0.0.1/replies"
    seedRoute(harness, guid: "origin", chat: 7)
    var config = harness.config
    if config.webhookURL.isEmpty {
        config.webhookURL = "https://127.0.0.1/webhook"
    }
    let replies = CountingReplies(page: ReplyPage(
        replies: [routedReply("r-start", chat: 7, text: "hello", guid: "origin")],
        nextCursor: nil
    ))
    let engine = try GenieEngine(
        configProvider: StaticConfig(config: config),
        initialConfig: config,
        stateStore: harness.state,
        allowlistStore: harness.allow,
        replySource: replies,
        sender: harness.sender,
        webhook: harness.webhook,
        secrets: harness.secrets,
        lock: harness.lock,
        clock: harness.clock,
        log: harness.log
    )
    return Started(harness: harness, engine: engine, replies: replies)
}

private final class CountingReplies: ReplySource, @unchecked Sendable {
    private let page: ReplyPage
    private(set) var fetches = 0

    init(page: ReplyPage) {
        self.page = page
    }

    func fetch(
        cursor: String?,
        skipping handledReplyIDs: Set<String>,
        holding replyIDs: Set<String>
    ) async throws -> ReplyPage {
        _ = cursor
        _ = handledReplyIDs
        _ = replyIDs
        fetches += 1
        return page
    }
}
