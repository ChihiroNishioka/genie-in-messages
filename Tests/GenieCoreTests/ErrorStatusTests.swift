import XCTest
@testable import GenieCore

final class ErrorStatusTests: XCTestCase {
    private func harness() -> Harness {
        let h = Harness()
        h.allow.ids = [7]
        h.config.replyFetchURL = "https://example.com/replies"
        return h
    }

    func testSendFailureRemainsVisibleDuringFetchFailureAndRecovery() async throws {
        let h = harness()
        h.webhook.results = [.success(WebhookHTTPResult(statusCode: 403))]
        let e = try await h.opened()
        h.replies.failNext = true
        _ = await e.pollReplies()
        let result = await e.ingestWatchLine(watchLine(id: 1, guid: "failed", chat: 7, fromMe: true, text: "🪔 request"))
        XCTAssertEqual(result, .deadLettered("webhook_http_403"))
        h.replies.failNext = true
        _ = await e.pollReplies()
        let during = await e.snapshot()
        XCTAssertEqual(during.lastError, "webhook_http_403")
        XCTAssertEqual(during.replyFetchError, "reply_fetch_failed")
        XCTAssertEqual(ErrorStatus.menuLines(for: during), [
            "最後のエラー: 送信など: webhook_http_403",
            "返信の取得: 返事の取得に失敗しました"
        ])
        _ = await e.pollReplies()
        let recovered = await e.snapshot()
        XCTAssertEqual(recovered.lastError, "webhook_http_403")
        XCTAssertNil(recovered.replyFetchError)
        XCTAssertEqual(ErrorStatus.menuLines(for: recovered), ["最後のエラー: webhook_http_403"])
    }

    func testWatchStartFailureRemainsVisibleDuringFetchFailure() async throws {
        let h = harness()
        let e = try await h.opened()
        await e.refreshLock()
        await e.setLastError("watch_start_failed")
        h.replies.failNext = true
        _ = await e.pollReplies()
        let snapshot = await e.snapshot()
        XCTAssertEqual(snapshot.lastError, "watch_start_failed")
        XCTAssertEqual(LampIcon.appearance(for: snapshot), .warning)
        XCTAssertEqual(ErrorStatus.menuLines(for: snapshot), [
            "最後のエラー: 送信など: imsg を起動できませんでした",
            "返信の取得: 返事の取得に失敗しました"
        ])
    }

    func testSuccessfulSendDoesNotClearFetchFailure() async throws {
        let h = harness()
        let e = try await h.opened()
        await e.refreshLock()
        h.replies.failNext = true
        _ = await e.pollReplies()
        let result = await e.ingestWatchLine(watchLine(id: 1, guid: "sent", chat: 7, fromMe: true, text: "🪔 request"))
        XCTAssertEqual(result, .delivered)
        let snapshot = await e.snapshot()
        XCTAssertNil(snapshot.lastError)
        XCTAssertEqual(snapshot.replyFetchError, "reply_fetch_failed")
        XCTAssertEqual(ErrorStatus.menuLines(for: snapshot), ["最後のエラー: 返事の取得に失敗しました"])
        XCTAssertEqual(LampIcon.appearance(for: snapshot), .running)
        await e.setPaused(true)
        let paused = await e.snapshot()
        XCTAssertEqual(LampIcon.appearance(for: paused), .paused)
    }

    func testLaneRecoveryPreservesOtherFailures() async throws {
        let h = harness()
        h.config.notionDataSourceID = "00000000-0000-0000-0000-000000000007"
        h.httpReplies.failNext = true
        h.replies.failNext = true
        let e = try await h.opened()
        await e.setLastError("job_secret_missing")
        _ = await e.pollReplies()
        let bothFailed = await e.snapshot()
        XCTAssertEqual(bothFailed.lastError, "job_secret_missing")
        XCTAssertEqual(bothFailed.replyFetchError, "reply_fetch_failed")
        XCTAssertEqual(ErrorStatus.menuLines(for: bothFailed), [
            "最後のエラー: 送信など: job_secret_missing",
            "返信の取得: 返事の取得に失敗しました"
        ])
        h.replies.failNext = true
        _ = await e.pollReplies()
        let notionFailed = await e.snapshot()
        XCTAssertEqual(notionFailed.replyFetchError, "reply_fetch_failed")
        _ = await e.pollReplies()
        let recovered = await e.snapshot()
        XCTAssertNil(recovered.replyFetchError)
        XCTAssertEqual(recovered.lastError, "job_secret_missing")
    }

    func testHTTPFailureHasPriorityOverNotionFailure() async throws {
        let h = harness()
        h.config.notionDataSourceID = "00000000-0000-0000-0000-000000000007"
        h.config.replyFetchURL = "http://example.com/replies"
        h.replies.failNext = true
        let e = try await h.opened()
        _ = await e.pollReplies()
        let snapshot = await e.snapshot()
        XCTAssertNil(snapshot.lastError)
        XCTAssertEqual(snapshot.replyFetchError, "url_not_https")
    }

    func testMenuWithNoErrorsOrOnlyWatchFailure() async throws {
        XCTAssertEqual(ErrorStatus.menuLines(for: nil), ["最後のエラー: なし"])
        let e = try await harness().opened()
        let empty = await e.snapshot()
        XCTAssertEqual(ErrorStatus.menuLines(for: empty), ["最後のエラー: なし"])
        await e.setLastError("watch_start_failed")
        let failed = await e.snapshot()
        XCTAssertEqual(ErrorStatus.menuLines(for: failed), ["最後のエラー: imsg を起動できませんでした"])
    }
}
