import XCTest
@testable import GenieCore

final class ConfigTests: XCTestCase {
    func testMissingAllowlistIsAllOffAndSecretMustBe600() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = ConfigPaths(root: root, logFile: root.appendingPathComponent("genie.log"))
        try ConfigDirectory.prepare(paths)
        XCTAssertEqual(try FilePermissions.mode(of: paths.root), 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.secretFile.path))
        let loaded = try ConfigLoader.load(from: paths.configFile)
        XCTAssertEqual(loaded.webhookURL, "")
        XCTAssertEqual(loaded.imsgExecutable, "/opt/homebrew/opt/imsg/libexec/imsg")
        XCTAssertFalse(Signal.matches(loaded.marker))
        let allow = try FileAllowlistStore(file: paths.allowlistFile).load()
        XCTAssertTrue(allow.isEmpty)

        let seeded = """
        {"enabled_chat_ids":[1],"enabled_chats":[{"guid":"g","id":1}],"note":"keep-me"}
        """
        try Data(seeded.utf8).write(to: paths.allowlistFile)
        var loadedAllow = try FileAllowlistStore(file: paths.allowlistFile).load()
        loadedAllow.entries.append(AllowedChat(id: 2, guid: "h"))
        try FileAllowlistStore(file: paths.allowlistFile).save(loadedAllow)
        let saved = try String(contentsOf: paths.allowlistFile, encoding: .utf8)
        XCTAssertTrue(saved.contains("keep-me"))
        let again = try FileAllowlistStore(file: paths.allowlistFile).load()
        XCTAssertEqual(again.entries.map(\.id), [1, 2])

        try Data("  token \n".utf8).write(to: paths.secretFile)
        try FilePermissions.set(paths.secretFile, mode: 0o600)
        XCTAssertEqual(try SecretFile.readToken(at: paths.secretFile), "token")
        try FilePermissions.set(paths.secretFile, mode: 0o640)
        XCTAssertThrowsError(try SecretFile.readToken(at: paths.secretFile)) { error in
            XCTAssertEqual(error as? SecretReadError, .insecureMode)
        }
    }

    func testPartialConfigUsesProductDefaults() throws {
        let data = Data("{}".utf8)
        let config = try JSONDecoder().decode(GenieConfig.self, from: data)
        XCTAssertEqual(config.marker, GenieConfig.productDefaults.marker)
        XCTAssertEqual(config.rateLimitCount, 5)
        XCTAssertEqual(config.webhookURL, "")
        XCTAssertEqual(config.replyFetchURL, "")
        XCTAssertEqual(config.notionDataSourceID, "")
        XCTAssertEqual(config.selfSenderName, "me")
        XCTAssertTrue(config.senderNames.isEmpty)
        XCTAssertTrue(config.selfChatIDs.isEmpty)
    }

    func testExampleConfigHasNoPersonalValues() throws {
        let url = repoRoot().appendingPathComponent("config.example.json")
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("@"))
        XCTAssertFalse(text.lowercased().contains("secret"))
        let config = try JSONDecoder().decode(GenieConfig.self, from: data)
        XCTAssertEqual(config.webhookURL, "")
        XCTAssertEqual(config.replyFetchURL, "")
        XCTAssertEqual(config.notionDataSourceID, "")
        XCTAssertEqual(config.selfSenderName, "me")
        XCTAssertTrue(config.senderNames.isEmpty)
        XCTAssertEqual(config.imsgExecutable, "/opt/homebrew/opt/imsg/libexec/imsg")
        XCTAssertFalse(Signal.matches(config.marker))
    }

    func testDeadLetterFileOmitsTheBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = ConfigPaths(root: root, logFile: root.appendingPathComponent("genie.log"))
        let store = FileStateStore(paths: paths)
        let harness = Harness()
        harness.allow.ids = [1]
        harness.config.webhookURL = ""
        let engine = try GenieEngine(
            configProvider: StaticConfig(config: harness.config),
            initialConfig: harness.config,
            stateStore: store,
            allowlistStore: harness.allow,
            replySource: harness.replies,
            sender: harness.sender,
            webhook: harness.webhook,
            secrets: harness.secrets,
            lock: harness.lock,
            clock: harness.clock,
            log: harness.log
        )
        let marker = "DISK_BODY_MARKER"
        _ = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g-disk", chat: 1, fromMe: true, text: "\u{1FA94} \(marker)"
        ))
        let file = try String(contentsOf: paths.deadLetterFile, encoding: .utf8)
        XCTAssertFalse(file.contains(marker))
        XCTAssertTrue(file.contains("webhook_not_configured"))
        XCTAssertTrue(file.contains("g-disk"))
        XCTAssertEqual(try FilePermissions.mode(of: paths.deadLetterFile), 0o600)
    }

    func testLogRotationAndNoBody() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("genie.log")
        let log = FileGenieLog(url: url, maxBytes: 120, keep: 2)
        for index in 0..<8 {
            log.record(level: .info, code: "webhook_delivered_\(index)", chatID: 1, guid: "g\(index)", rowid: Int64(index))
        }
        let current = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(current.contains("hello body"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path) || current.contains("webhook_delivered"))
    }

    func testBundleIsAnAgentWithoutSandbox() throws {
        let info = try String(contentsOf: repoRoot().appendingPathComponent("AppBundle/Info.plist"), encoding: .utf8)
        XCTAssertTrue(info.contains("<key>LSUIElement</key>"))
        XCTAssertTrue(info.contains("NSAppleEventsUsageDescription"))
        XCTAssertFalse(info.contains("app-sandbox"))
        let entitlements = try String(
            contentsOf: repoRoot().appendingPathComponent("AppBundle/entitlements.plist"),
            encoding: .utf8
        )
        XCTAssertTrue(entitlements.contains("com.apple.security.automation.apple-events"))
        XCTAssertFalse(entitlements.contains("app-sandbox"))
        XCTAssertFalse(info.contains("IMCore"))
    }

    func testAssembleScriptRejectsAdHocIdentity() throws {
        let script = repoRoot().appendingPathComponent("scripts/assemble-app.sh")
        let missing = run(script, arguments: [])
        XCTAssertEqual(missing.status, 2)
        let adHoc = run(script, arguments: ["--identity", "-"])
        XCTAssertEqual(adHoc.status, 2)
        let combined = missing.stderr + adHoc.stderr
        XCTAssertTrue(combined.contains("アドホック") || combined.contains("identity") || combined.contains("署名"))
    }

    private func run(_ script: URL, arguments: [String]) -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

extension ConfigTests {
    func testG01JobConfigDefaultsNullAndDeduplication() throws {
        for json in ["{}", "{\"webhook_url\":\"https://example.com/hook\"}", "{\"job_webhook_url\":null,\"job_chat_ids\":null}"] {
            let c = try JSONDecoder().decode(GenieConfig.self, from: Data(json.utf8))
            XCTAssertEqual(c.jobWebhookURL, "")
            XCTAssertEqual(c.jobChatIDs, [])
        }
        let c = try JSONDecoder().decode(GenieConfig.self, from: Data("{\"job_webhook_url\":\" http://127.0.0.1:3321/ingress/genie \",\"job_chat_ids\":[7,7,8]}".utf8))
        XCTAssertEqual(c.jobWebhookURL, "http://127.0.0.1:3321/ingress/genie")
        XCTAssertEqual(c.jobChatIDs, [7,8])
        XCTAssertThrowsError(try JSONDecoder().decode(GenieConfig.self, from: Data("{\"job_chat_ids\":[\"7\"]}".utf8)))
        let example = try Data(contentsOf: repoRoot().appendingPathComponent("config.example.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: example) as? [String: Any])
        XCTAssertEqual(object["job_webhook_url"] as? String, "")
        XCTAssertEqual(object["job_chat_ids"] as? [Int], [])
    }

    func testG01UnreadableJobConfigKeepsPreviousSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConfigPaths(root: root, logFile: root.appendingPathComponent("genie.log"))
        try ConfigDirectory.prepare(paths)
        var c = GenieConfig.productDefaults
        c.webhookURL = "https://example.com/hook"
        try ConfigLoader.write(c, to: paths.configFile)
        let h = Harness()
        h.allow.ids = [7]
        let e = try GenieEngine(configProvider: FileConfigProvider(url: paths.configFile), initialConfig: c,
            stateStore: h.state, allowlistStore: h.allow, replySource: h.replies, sender: h.sender,
            webhook: h.webhook, secrets: h.secrets, lock: h.lock, clock: h.clock, log: h.log)
        try Data("{\"job_chat_ids\":[\"7\"]}".utf8).write(to: paths.configFile)
        let result = await e.ingestWatchLine(watchLine(id: 1, guid: "g-config", chat: 7, fromMe: true, text: "🪔 body"))
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(h.webhook.urls.map(\.absoluteString), [c.webhookURL])
        XCTAssertTrue(h.log.records.contains { $0.code == "config_unreadable" })
    }

    func testG16OldStateAndHTTPCursorRoundTrip() throws {
        let old = try StateCoding.decoder().decode(PersistedState.self, from: Data("{}".utf8))
        XCTAssertNil(old.httpReplyCursor)
        var state = old
        state.httpReplyCursor = "http-next"
        let (decoded, json) = try reloaded(state)
        XCTAssertEqual(decoded.httpReplyCursor, "http-next")
        XCTAssertTrue(json.contains("\"http_reply_cursor\""))
    }

    func testG19JobDocsAndExampleDescribeContract() throws {
        let readme = try String(contentsOf: repoRoot().appendingPathComponent("README.md"), encoding: .utf8)
        let spec = try String(contentsOf: repoRoot().appendingPathComponent("SPEC.md"), encoding: .utf8)
        for text in [readme, spec] {
            for needle in ["job_chat_ids", "job_webhook_url", "job-secret", "http://127.0.0.1:3321/ingress/genie", "http_reply_cursor"] {
                XCTAssertTrue(text.contains(needle), needle)
            }
        }
        for number in ["4.5", "4.9", "5.2"] {
            let section = spec.components(separatedBy: "### \(number)").dropFirst().first?.components(separatedBy: "\n### ").first ?? ""
            XCTAssertTrue(section.contains("job_chat_ids"), number)
            if number == "4.9" {
                XCTAssertTrue(section.contains("`job_chat_ids` は整数配列で既定は空"))
            }
        }
    }
}
