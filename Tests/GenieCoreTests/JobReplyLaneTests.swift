import Foundation
import XCTest
@testable import GenieCore

final class JobReplyLaneTests: XCTestCase {
    private func lane(_ both: Bool = true) -> Harness {
        let h = Harness()
        h.allow.ids = [7]
        h.config.replyFetchURL = "http://127.0.0.1:3321/genie/replies"
        h.config.notionDataSourceID = both ? "00000000-0000-0000-0000-000000000007" : ""
        seedRoute(h, guid: "origin", chat: 7)
        return h
    }

    private func reply(_ id: String, _ text: String) -> FetchedReply {
        routedReply(id, chat: 7, text: text, guid: "origin")
    }

    private func notionCursor() -> String {
        NotionCursor(createdAt: "2023-11-14T22:13:20Z", seen: []).encoded()!
    }

    func testG11HTTPOnlyAcceptsLoopback() async throws {
        let h = lane(false)
        h.replies.pages = [ReplyPage(replies: [reply("h1", "answer")], nextCursor: "end")]
        let e = try await h.opened()
        let result = await e.pollReplies()
        XCTAssertEqual(result, .fetched)
        XCTAssertEqual(h.sender.sent.map(\.text), [h.config.marker, "answer"])
    }

    func testG12BothSourcesRunHTTPFirstWithSeparateCursors() async throws {
        let h = lane()
        let events = EventLog()
        h.httpReplies.onFetch = { events.append("http") }
        h.replies.onFetch = { events.append("notion") }
        h.state.state.httpReplyCursor = "http-before"
        let nc = notionCursor()
        h.state.state.replyCursor = nc
        h.httpReplies.pages = [ReplyPage(replies: [reply("h1", "HTTP")], nextCursor: "http-after")]
        h.replies.pages = [ReplyPage(replies: [reply("n1", "Notion")], nextCursor: nc)]
        let e = try await h.opened()
        let result = await e.pollReplies()
        XCTAssertEqual(result, .fetched)
        XCTAssertEqual(events.snapshot(), ["http", "notion"])
        XCTAssertEqual(h.httpReplies.cursors, ["http-before"])
        XCTAssertEqual(h.replies.cursors, [nc])
        XCTAssertEqual(h.state.state.httpReplyCursor, "http-after")
        XCTAssertEqual(h.state.state.replyCursor, nc)
        XCTAssertEqual(h.sender.sent.map(\.text), [h.config.marker, "HTTP", h.config.marker, "Notion"])
    }

    func testG13FailureOfEitherSourceDoesNotBlockTheOther() async throws {
        for httpFails in [true, false] {
            let h = lane()
            h.state.state.httpReplyCursor = "before"
            h.httpReplies.failNext = httpFails
            h.replies.failNext = !httpFails
            h.httpReplies.pages = [ReplyPage(replies: [reply("h1", "HTTP")], nextCursor: "after")]
            h.replies.pages = [ReplyPage(replies: [reply("n1", "Notion")], nextCursor: notionCursor())]
            let e = try await h.opened()
            let result = await e.pollReplies()
            XCTAssertEqual(result, .fetchFailed)
            XCTAssertEqual(h.httpReplies.cursors.count, 1)
            XCTAssertEqual(h.replies.cursors.count, 1)
            XCTAssertEqual(h.sender.sent.map(\.text), [h.config.marker, httpFails ? "Notion" : "HTTP"])
            XCTAssertEqual(h.state.state.httpReplyCursor, httpFails ? "before" : "after")
            XCTAssertTrue(h.log.records.contains { $0.code == "reply_fetch_failed" && $0.detail == (httpFails ? "http" : "notion") })
        }
    }

    func testG14MultipleRepliesRetainRouteAndHoldCursorUntilSent() async throws {
        let h = lane()
        let page = ReplyPage(replies: [reply("accepted", "accepted"), reply("complete", "complete")], nextCursor: "end")
        h.httpReplies.pages = [page, page, page]
        h.lock.locked = true
        let e = try await h.opened()
        _ = await e.pollReplies()
        XCTAssertNil(h.state.state.httpReplyCursor)
        XCTAssertTrue(h.sender.sent.isEmpty)
        h.lock.locked = false
        await e.refreshLock()
        await e.retryHolds()
        _ = await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [h.config.marker, "accepted", h.config.marker, "complete"])
        XCTAssertEqual(h.state.state.httpReplyCursor, "end")
        XCTAssertTrue(h.state.state.routes.contains { $0.guid == "origin" })
    }

    func testG15HTTPOnlyKeepsLegacyCursorAndIgnoresNotionCursor() async throws {
        for old in ["legacy", notionCursor()] {
            let h = lane(false)
            h.config.replyFetchURL = "https://example.com/replies"
            h.state.state.replyCursor = old
            h.replies.pages = [ReplyPage(replies: [reply("h1", "answer")], nextCursor: "end")]
            let e = try await h.opened()
            _ = await e.pollReplies()
            XCTAssertEqual(h.replies.cursors, [old == "legacy" ? old : nil])
            XCTAssertEqual(h.state.state.replyCursor, "end")
            XCTAssertNil(h.state.state.httpReplyCursor)
        }
    }

    func testG16ControllerWiresHTTPSource() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/GenieMenuBar/GenieController.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("httpReplySource: ConfiguredHTTPReplySource(config: config, secrets: secrets)"))
    }

    func testG18NotionOnlyNeverCallsHTTP() async throws {
        let h = lane()
        h.config.replyFetchURL = ""
        h.replies.pages = [ReplyPage(replies: [reply("n1", "answer")], nextCursor: notionCursor())]
        let e = try await h.opened()
        let result = await e.pollReplies()
        XCTAssertEqual(result, .fetched)
        XCTAssertTrue(h.httpReplies.cursors.isEmpty)
        XCTAssertEqual(h.sender.sent.map(\.text), [h.config.marker, "answer"])
    }
}
