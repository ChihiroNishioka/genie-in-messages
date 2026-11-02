import XCTest
@testable import GenieCore

/// 定期処理の入口が1つであることと、1周の順番を見る。
final class PollerSingleEntryTests: XCTestCase {
    func testTickRunsLockThenChatsThenHoldsThenReplies() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        let engine = try harness.engine()
        let reader = ScriptedChatLists(script: [
            .parsed(ChatListParse(chats: [], failedLineCount: 0)),
        ])
        let poller = GeniePoller(
            engine: engine,
            reader: reader,
            configProvider: StaticConfig(config: harness.config),
            clock: harness.clock,
            stop: harness.stop
        )
        let report = await poller.tick()
        XCTAssertEqual(report.steps, [
            .lock,
            .chats(.ok),
            .holds,
            .replies(.fetched),
        ])
        XCTAssertFalse(report.skippedBusy)
        XCTAssertFalse(report.stoppedMidway)
        XCTAssertEqual(reader.calls, 1)
    }

    func testRunReadsTheChatListOnTheClock() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        let engine = try harness.engine()
        let reader = ScriptedChatLists(script: [])
        let poller = GeniePoller(
            engine: engine,
            reader: reader,
            configProvider: StaticConfig(config: harness.config),
            clock: harness.clock,
            stop: harness.stop,
            schedule: .production
        )
        let start = harness.clock.current
        harness.clock.onSleep = {
            if harness.clock.current.timeIntervalSince(start) > 120 {
                harness.stop.stop()
            }
        }
        await poller.run()
        XCTAssertEqual(reader.calls, 5)
    }

    func testStoppingBeforeLaunchDoesNotReadOrWatch() async throws {
        let harness = Harness()
        let engine = try harness.engine()
        harness.stop.stop()
        let reader = ScriptedChatLists(script: [.failed])
        var watched = false
        let poller = GeniePoller(
            engine: engine,
            reader: reader,
            configProvider: StaticConfig(config: harness.config),
            clock: harness.clock,
            stop: harness.stop
        )
        let tasks = GenieRuntimeLauncher.launch(poller: poller, stop: harness.stop) {
            watched = true
        }
        let initial = await poller.waitForInitialChatList()
        _ = await tasks.poller.value
        _ = await tasks.supervisor.value
        XCTAssertEqual(initial, .stopped)
        XCTAssertEqual(reader.calls, 0)
        XCTAssertFalse(watched)
    }

    func testStoppingDuringTheChatReadDiscardsTheResult() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        let engine = try harness.engine()
        let reader = ScriptedChatLists(script: [.failed])
        reader.onRead = { harness.stop.stop() }
        let poller = GeniePoller(
            engine: engine,
            reader: reader,
            configProvider: StaticConfig(config: harness.config),
            clock: harness.clock,
            stop: harness.stop
        )
        let report = await poller.tick()
        XCTAssertEqual(report.steps, [.lock, .chats(.discardedAfterStop)])
        XCTAssertTrue(report.stoppedMidway)
        XCTAssertEqual(harness.log.records.filter { $0.code == "chats_failed" }.count, 0)
    }

    func testSourcesUseOnePollerEntry() throws {
        let root = repoRoot().appendingPathComponent("Sources")
        let files = try sourceFiles(in: root)
        var offenders: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            let name = url.lastPathComponent
            for banned in ["runPollerPass", "loadChats(", "reportError", "lastChatRefresh", "lastLoggedListFailure", "keepParseNoticeOnce"] {
                if text.contains(banned) {
                    offenders.append("\(name) \(banned)")
                }
            }
            let calls = text.components(separatedBy: "applyChatList(").count - 1
            if name == "Engine.swift" {
                if calls != 1 { offenders.append("Engine.swift applyChatList \(calls)") }
            } else if name == "GeniePoller.swift" {
                if calls < 1 { offenders.append("GeniePoller.swift applyChatList \(calls)") }
            } else if calls > 0 {
                offenders.append("\(name) applyChatList \(calls)")
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testNewSchedulerTestsDoNotSleep() throws {
        let root = repoRoot().appendingPathComponent("Tests")
        let names = [
            "ListFailureGraceTests.swift",
            "ListStateTransitionTests.swift",
        ]
        for name in names {
            let text = try String(contentsOf: root.appendingPathComponent("GenieCoreTests").appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("Task.sleep"))
            XCTAssertFalse(text.contains("Thread.sleep"))
        }
    }
}

final class ScriptedChatLists: ChatListReading, @unchecked Sendable {
    var script: [ChatListRead]
    private(set) var calls = 0
    var onRead: (() async -> Void)?
    init(script: [ChatListRead]) { self.script = script }
    func read() async -> ChatListRead {
        calls += 1
        await onRead?()
        if script.isEmpty { return .failed }
        return script.removeFirst()
    }
}

private func sourceFiles(in directory: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: nil
    ) else { return [] }
    return enumerator.compactMap { item in
        let url = item as? URL
        guard let url, url.pathExtension == "swift" else { return nil }
        return url
    }
}
