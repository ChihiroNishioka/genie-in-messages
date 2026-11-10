import Foundation
import XCTest
@testable import GenieCore

final class JobReviewContractTests: XCTestCase {
    private func configured(job: Bool = true) -> Harness {
        let h = Harness()
        h.allow.ids = [7]
        h.config.webhookURL = "https://example.com/hook"
        h.config.jobWebhookURL = "http://127.0.0.1:3321/ingress/genie"
        h.config.jobChatIDs = job ? [7] : []
        h.config.webhookMaxAttempts = 3
        return h
    }

    private func message() -> String {
        watchLine(id: 1, guid: "review-message", chat: 7, fromMe: true, text: "🪔 review")
    }

    func testOrdinaryWebhookRetriesDoNotAddIntermediateErrorLogs() async throws {
        for succeeds in [true, false] {
            let h = configured(job: false)
            h.webhook.results = [
                .success(WebhookHTTPResult(statusCode: 503)),
                .failure(ScriptedFetchFailure()),
                .success(WebhookHTTPResult(statusCode: succeeds ? 200 : 503))
            ]
            let engine = try await h.opened()
            let result = await engine.ingestWatchLine(message())
            XCTAssertEqual(result, succeeds ? .delivered : .deadLettered("webhook_http_503"))
            XCTAssertEqual(h.clock.slept, [1, 2])
            let errors = h.log.records.filter { $0.level == "error" }
            XCTAssertEqual(errors.map(\.code), succeeds ? [] : ["webhook_http_503"])
            XCTAssertTrue(errors.allSatisfy { $0.detail == nil })
        }
    }

    func testUnreadableJobSecretBacksOffRetriesAndKeepsJobError() async throws {
        let h = configured()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConfigPaths(root: root, logFile: root.appendingPathComponent("genie.log"))
        try ConfigDirectory.prepare(paths)
        try Data("ordinary-token".utf8).write(to: paths.secretFile)
        try FilePermissions.set(paths.secretFile, mode: 0o600)
        try FileManager.default.createDirectory(at: paths.jobSecretFile, withIntermediateDirectories: false)
        h.secrets = FileSecretProvider(paths: paths)
        let engine = try await h.opened()
        let result = await engine.ingestWatchLine(message())
        XCTAssertEqual(result, .deadLettered("job_secret_unreadable"))
        XCTAssertEqual(h.clock.slept, [1, 2])
        XCTAssertTrue(h.webhook.urls.isEmpty)
        XCTAssertEqual(h.state.deadLetters.first?.kind, "job_webhook")
        XCTAssertEqual(h.state.deadLetters.first?.error, "job_secret_unreadable")
        XCTAssertEqual(h.state.deadLetters.first?.attempts, 3)
        XCTAssertEqual(h.log.records.last { $0.level == "error" }?.code, "job_secret_unreadable")
        XCTAssertEqual(h.log.records.last { $0.level == "error" }?.detail, "job")
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.lastError, "job_secret_unreadable")
    }

    func testDocsDescribeJobEngineCredentials() throws {
        for name in ["README.md", "SPEC.md"] {
            let text = try String(contentsOf: repoRoot().appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains("`job-secret` と `reply-secret` に Job Engine の `GENIE_TOKEN` と同じ値"), name)
            XCTAssertTrue(text.contains("Job Engine の返信取得では `reply-secret` が必須"), name)
            XCTAssertTrue(text.contains("無いと 401"), name)
        }
    }

    func testDocsDescribeBothJobEngineAllowlists() throws {
        for name in ["README.md", "SPEC.md"] {
            let text = try String(contentsOf: repoRoot().appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains("`GENIE_ALLOWED_CHAT_IDS` と `ALLOWED_SOURCE_CHAT_IDS` に同じ `chat_id`"), name)
            XCTAssertTrue(text.contains("`webhook_http_403`"), name)
            XCTAssertTrue(text.contains("`job_webhook`"), name)
        }
    }

    func testHardwareChecksHaveOneListInSpec() throws {
        let text = try String(contentsOf: repoRoot().appendingPathComponent("SPEC.md"), encoding: .utf8)
        let section = try XCTUnwrap(text.components(separatedBy: "## 9. 実機で未確認のこと\n").last)
            .components(separatedBy: "## 10.")[0]
        XCTAssertFalse(section.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n\n- "))
        for item in ["macOS の ATS", "Job Engine との疎通", "iMessage 送信", "macOS の CI ジョブ"] {
            XCTAssertTrue(section.contains(item), item)
        }
        let readme = try String(contentsOf: repoRoot().appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("[実機で未確認のこと](SPEC.md#9-実機で未確認のこと)"))
    }
}
