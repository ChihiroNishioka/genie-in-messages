import Foundation
import XCTest
@testable import GenieCore

final class JobPollContractTests: XCTestCase {
    private func harness() -> Harness {
        let h = Harness()
        h.allow.ids = [7]
        h.config.notionDataSourceID = "00000000-0000-0000-0000-000000000007"
        h.config.replyFetchURL = "https://example.com/replies"
        seedRoute(h, guid: "origin", chat: 7)
        return h
    }

    func testPollFreezesConfiguredNotionSourceBeforeHTTPAwait() async throws {
        let h = harness()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConfigPaths(root: root, logFile: root.appendingPathComponent("log"))
        try ConfigDirectory.prepare(paths)
        try ConfigLoader.write(h.config, to: paths.configFile)
        try Data("reply-fixture".utf8).write(to: paths.replySecretFile)
        try FilePermissions.set(paths.replySecretFile, mode: 0o644)
        h.state.state.httpReplyCursor = "before"
        h.lock.locked = true
        h.httpReplies.pages = [ReplyPage(replies: [
            routedReply("held-during-change", chat: 7, text: "answer", guid: "origin")
        ], nextCursor: "o:42")]
        let provider = FileConfigProvider(url: paths.configFile)
        let secrets = FileSecretProvider(paths: paths)
        h.httpReplies.onFetch = {
            var changed = h.config
            changed.notionDataSourceID = ""
            try! ConfigLoader.write(changed, to: paths.configFile)
        }
        let e = try GenieEngine(
            configProvider: provider, initialConfig: h.config, stateStore: h.state,
            allowlistStore: h.allow, replySource: ConfiguredReplySource(config: provider, secrets: secrets),
            httpReplySource: h.httpReplies, sender: h.sender, webhook: h.webhook,
            secrets: secrets, lock: h.lock, clock: h.clock, log: h.log
        )
        await e.showChats(h.verifiedChatList())
        let result = await e.pollReplies()
        XCTAssertEqual(result, .fetchFailed)
        XCTAssertTrue(h.log.records.contains { $0.code == "notion_token_missing" && $0.detail == "notion" })
        XCTAssertEqual(h.httpReplies.cursors, ["before"])
        XCTAssertEqual(h.state.state.httpReplyCursor, "before")
        XCTAssertNil(h.state.state.replyCursor)
        XCTAssertTrue(h.sender.sent.isEmpty)
    }

    func testHTTPNotionShapedCursorStaysUnchangedWhileHeld() async throws {
        let h = harness()
        let cursor = NotionCursor(createdAt: "2023-11-14T22:13:20Z", seen: []).encoded()!
        h.state.state.httpReplyCursor = "before"
        h.httpReplies.pages = [ReplyPage(replies: [routedReply("held", chat: 7, text: "answer", guid: "origin")], nextCursor: cursor)]
        h.lock.locked = true
        let e = try await h.opened()
        _ = await e.pollReplies()
        XCTAssertEqual(h.state.state.httpReplyCursor, "before")
        XCTAssertTrue(h.sender.sent.isEmpty)
    }

    func testNotionUnreadableCursorDoesNotAdvanceWhileHeld() async throws {
        let h = harness()
        h.config.replyFetchURL = ""
        h.state.state.replyCursor = "before"
        h.replies.pages = [ReplyPage(replies: [routedReply("held", chat: 7, text: "answer", guid: "origin")], nextCursor: "unreadable")]
        h.lock.locked = true
        let e = try await h.opened()
        _ = await e.pollReplies()
        XCTAssertEqual(h.state.state.replyCursor, "before")
        XCTAssertTrue(h.sender.sent.isEmpty)
    }

    func testFailedFetchKeepsChatWaitingIDsUntilSuccessfulFetch() async throws {
        let h = harness()
        h.config.notionDataSourceID = ""
        h.replies.pages = [ReplyPage(replies: [
            routedReply("first", chat: 7, text: "one", guid: "origin"),
            routedReply("waiting", chat: 7, text: "two", guid: "origin")
        ], nextCursor: nil)]
        h.sender.script = [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.notStarted)]
        let e = try await h.opened()
        _ = await e.pollReplies()
        h.replies.failNext = true
        _ = await e.pollReplies()
        _ = await e.pollReplies()
        XCTAssertTrue(h.replies.holdings[1].contains("waiting"))
        XCTAssertTrue(h.replies.holdings[2].contains("waiting"))
        _ = await e.pollReplies()
        XCTAssertFalse(h.replies.holdings[3].contains("waiting"))
    }
}
