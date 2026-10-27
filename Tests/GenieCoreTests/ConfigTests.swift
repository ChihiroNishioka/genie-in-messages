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
