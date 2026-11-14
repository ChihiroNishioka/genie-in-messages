import Foundation
import XCTest
@testable import GenieCore

final class JobRouteTests: XCTestCase {
    private let jobURL = "http://127.0.0.1:3321/ingress/genie"
    private let ordinaryURL = "https://example.com/hook"

    private func configured() -> Harness {
        let h = Harness()
        h.allow.ids = [7]
        h.config.webhookURL = ordinaryURL
        h.config.jobWebhookURL = jobURL
        h.config.jobChatIDs = [7]
        h.secrets = StaticSecret(webhook: "ordinary-token", reply: nil, job: "job-token")
        return h
    }

    private func line(chat: Int = 7, id: Int = 1, guid: String = "job-message") -> String {
        watchLine(id: id, guid: guid, chat: chat, fromMe: true, text: "🪔 job-body")
    }

    func testG02JobUsesItsURLSecretAndUnchangedPayload() async throws {
        let h = configured()
        let engine = try await h.opened()
        let result = await engine.ingestWatchLine(line())
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(h.webhook.urls.map(\.absoluteString), [jobURL])
        XCTAssertEqual(h.webhook.secrets, ["job-token"])
        let data = try XCTUnwrap(h.webhook.bodies.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set([
            "v", "event", "idempotency_key", "guid", "chat_id", "text", "created_at",
            "sender_is_me", "sender_name"
        ]))
        XCTAssertEqual(body["v"] as? Int, 1)
        XCTAssertEqual(body["guid"] as? String, "job-message")
        XCTAssertEqual(body["chat_id"] as? Int, 7)
        XCTAssertEqual(h.log.records.last { $0.code == "webhook_delivered" }?.detail, "job")
        XCTAssertEqual(h.state.state.routes.first?.guid, "job-message")
    }

    func testG03UnlistedChatUsesOrdinaryWebhook() async throws {
        let h = configured()
        h.allow.ids = [8]
        let engine = try await h.opened()
        let result = await engine.ingestWatchLine(line(chat: 8))
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(h.webhook.urls.map(\.absoluteString), [ordinaryURL])
        XCTAssertEqual(h.webhook.secrets, ["ordinary-token"])
        XCTAssertNil(h.log.records.last { $0.code == "webhook_delivered" }?.detail)
    }

    func testG04JobSelectionDoesNotGrantPermission() async throws {
        let h = configured()
        h.allow.ids = []
        let engine = try await h.opened()
        let result = await engine.ingestWatchLine(line())
        XCTAssertEqual(result, .ignoredNotAllowed)
        XCTAssertTrue(h.webhook.bodies.isEmpty)
        XCTAssertTrue(h.webhook.secrets.isEmpty)
    }

    func testG05EmptyJobURLUsesOrdinaryWebhook() async throws {
        let h = configured()
        h.config.jobWebhookURL = "  \n "
        let engine = try await h.opened()
        let result = await engine.ingestWatchLine(line())
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(h.webhook.urls.map(\.absoluteString), [ordinaryURL])
        XCTAssertEqual(h.webhook.secrets, ["ordinary-token"])
    }

    func testG06JobSecretFailuresNeverUseOrdinarySecret() async throws {
        for (mode, contents, code) in [
            (nil as UInt16?, nil as String?, "job_secret_missing"),
            (UInt16(0o644), "job-token", "job_secret_mode"),
            (UInt16(0o600), " \n ", "job_secret_empty")
        ] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = ConfigPaths(root: root, logFile: root.appendingPathComponent("genie.log"))
            try ConfigDirectory.prepare(paths)
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.jobSecretFile.path))
            try Data("ordinary-token".utf8).write(to: paths.secretFile)
            try FilePermissions.set(paths.secretFile, mode: 0o600)
            if let contents, let mode {
                try Data(contents.utf8).write(to: paths.jobSecretFile)
                try FilePermissions.set(paths.jobSecretFile, mode: mode)
            }
            let h = configured()
            h.secrets = FileSecretProvider(paths: paths)
            let engine = try await h.opened()
            let result = await engine.ingestWatchLine(line())
            XCTAssertEqual(result, .deadLettered(code))
            XCTAssertTrue(h.webhook.bodies.isEmpty)
            XCTAssertTrue(h.webhook.secrets.isEmpty)
            XCTAssertEqual(h.state.deadLetters.first?.kind, "job_webhook")
            XCTAssertEqual(h.state.deadLetters.first?.error, code)
            assertNoBody(h, "ordinary-token")
            assertNoBody(h, "job-token")
            assertNoBody(h, "job-body")
        }
    }

    func testG07LoopbackIsAnExactHostException() {
        for text in [jobURL, "http://[::1]:3321/", "http://LOCALHOST:3321/", "https://example.com/hook"] {
            XCTAssertNotNil(EndpointURL.httpsOrLoopback(text), text)
        }
        for text in [
            "http://127.0.0.2/", "http://localhost.example/", "http://127.0.0.1.example/",
            "http://127.0.0.1@example.com/", "http://example.com/", "ftp://127.0.0.1/",
            "https:///", ""
        ] {
            XCTAssertNil(EndpointURL.httpsOrLoopback(text), text)
        }
    }

    func testG08InvalidJobURLStopsWithoutFallback() async throws {
        let h = configured()
        h.config.jobWebhookURL = "http://example.com/"
        let engine = try await h.opened()
        let result = await engine.ingestWatchLine(line())
        XCTAssertEqual(result, .deadLettered("url_not_https"))
        XCTAssertTrue(h.webhook.urls.isEmpty)
        XCTAssertTrue(h.webhook.secrets.isEmpty)
        XCTAssertEqual(h.state.deadLetters.first?.kind, "job_webhook")
        XCTAssertEqual(h.state.deadLetters.first?.error, "url_not_https")
    }

    func testG09OrdinaryWebhookStillRequiresHTTPS() async throws {
        let h = configured()
        h.config.jobChatIDs = []
        h.config.webhookURL = "http://127.0.0.1/hook"
        let engine = try await h.opened()
        let result = await engine.ingestWatchLine(line())
        XCTAssertEqual(result, .deadLettered("url_not_https"))
        XCTAssertTrue(h.webhook.urls.isEmpty)
        XCTAssertEqual(h.state.deadLetters.first?.kind, "webhook")
    }

    func testG10RetryKeepsTheSelectedJobRouteAcrossConfigRefresh() async throws {
        let h = configured()
        let mutable = MutableConfig(h.config)
        let engine = try GenieEngine(
            configProvider: mutable, initialConfig: h.config, stateStore: h.state,
            allowlistStore: h.allow, replySource: h.replies, sender: h.sender,
            webhook: h.webhook, secrets: h.secrets, lock: h.lock, clock: h.clock, log: h.log
        )
        h.webhook.results = [.success(WebhookHTTPResult(statusCode: 503)), .success(WebhookHTTPResult(statusCode: 200))]
        h.clock.onSleep = {
            mutable.config.jobChatIDs = []
            _ = await engine.ingestWatchLine(watchLine(id: 0, guid: "refresh", chat: 7, fromMe: true, text: "plain"))
        }
        let result = await engine.ingestWatchLine(line())
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(h.clock.slept, [1])
        XCTAssertEqual(h.webhook.urls.map(\.absoluteString), [jobURL, jobURL])
        XCTAssertEqual(h.webhook.secrets, ["job-token", "job-token"])
        XCTAssertTrue(h.state.deadLetters.isEmpty)
    }

    func testG10ClientErrorDeadLettersJobOnce() async throws {
        let h = configured()
        h.webhook.results = [.success(WebhookHTTPResult(statusCode: 400))]
        let engine = try await h.opened()
        let result = await engine.ingestWatchLine(line())
        XCTAssertEqual(result, .deadLettered("webhook_http_400"))
        XCTAssertEqual(h.webhook.urls.map(\.absoluteString), [jobURL])
        XCTAssertTrue(h.clock.slept.isEmpty)
        XCTAssertEqual(h.state.deadLetters.first?.kind, "job_webhook")
        XCTAssertEqual(h.state.deadLetters.first?.attempts, 1)
        XCTAssertEqual(h.log.records.last { $0.code == "webhook_http_400" }?.detail, "job")
    }

    func testG17SnapshotUsesSeparateURLRulesAndNeedsJobChats() async throws {
        let h = configured()
        h.config.replyFetchURL = "http://127.0.0.1:3321/genie/replies"
        h.config.webhookURL = "http://127.0.0.1/hook"
        var engine = try await h.opened()
        var snapshot = await engine.snapshot()
        XCTAssertTrue(snapshot.replyFetchConfigured)
        XCTAssertFalse(snapshot.webhookConfigured)
        XCTAssertTrue(snapshot.jobWebhookConfigured)
        h.config.jobChatIDs = []
        engine = try await h.opened()
        snapshot = await engine.snapshot()
        XCTAssertFalse(snapshot.jobWebhookConfigured)
        h.config.jobChatIDs = [7]
        h.config.jobWebhookURL = ""
        engine = try await h.opened()
        snapshot = await engine.snapshot()
        XCTAssertFalse(snapshot.jobWebhookConfigured)
        h.config.jobWebhookURL = "http://example.com/"
        engine = try await h.opened()
        snapshot = await engine.snapshot()
        XCTAssertFalse(snapshot.jobWebhookConfigured)
    }
}
