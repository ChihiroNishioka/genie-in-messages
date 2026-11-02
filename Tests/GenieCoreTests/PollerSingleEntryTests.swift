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
        let start = harness.clock.current
        let ok = ChatListRead.parsed(ChatListParse(chats: [], failedLineCount: 0))
        let reader = ScriptedChatLists(script: Array(repeating: ok, count: 8))
        var chatAt: [TimeInterval] = []
        var replyAt: [TimeInterval] = []
        reader.onRead = { chatAt.append(harness.clock.current.timeIntervalSince(start)) }
        harness.replies.onFetch = { replyAt.append(harness.clock.current.timeIntervalSince(start)) }
        let poller = GeniePoller(
            engine: engine,
            reader: reader,
            configProvider: StaticConfig(config: harness.config),
            clock: harness.clock,
            stop: harness.stop,
            schedule: .production
        )
        harness.clock.onSleep = {
            if harness.clock.current.timeIntervalSince(start) > 120 {
                harness.stop.stop()
            }
        }
        await poller.run()
        XCTAssertEqual(chatAt, [0, 30, 60, 90, 120])
        XCTAssertEqual(replyAt, Array(stride(from: 0, through: 120, by: 10)))
        XCTAssertFalse(chatAt.contains(10))
    }

    func testStoppingBeforeLaunchDoesNotReadOrWatch() async throws {
        let harness = Harness()
        let engine = try harness.engine()
        harness.stop.stop()
        let reader = ScriptedChatLists(script: [.failed])
        let watched = LockedFlag()
        let poller = GeniePoller(
            engine: engine,
            reader: reader,
            configProvider: StaticConfig(config: harness.config),
            clock: harness.clock,
            stop: harness.stop
        )
        let tasks = GenieRuntimeLauncher.launch(poller: poller, stop: harness.stop) {
            watched.value = true
        }
        let initial = await poller.waitForInitialChatList()
        _ = await tasks.poller.value
        _ = await tasks.supervisor.value
        XCTAssertEqual(initial, .stopped)
        XCTAssertEqual(reader.calls, 0)
        XCTAssertFalse(watched.value)
    }

    func testStoppingDuringTheChatReadDiscardsTheResult() async throws {
        let harness = Harness()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        let engine = try harness.engine()
        let reader = ScriptedChatLists(script: [.failed])
        let events = EventLog()
        reader.onRead = { harness.stop.stop() }
        let poller = GeniePoller(
            engine: engine,
            reader: reader,
            configProvider: StaticConfig(config: harness.config),
            clock: harness.clock,
            stop: harness.stop,
            probe: RecordingProbe(log: events)
        )
        let report = await poller.tick()
        XCTAssertEqual(report.steps, [.lock, .chats(.discardedAfterStop)])
        XCTAssertTrue(report.stoppedMidway)
        XCTAssertFalse(events.snapshot().contains("chatsReadReturned"))
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
        let app = repoRoot().appendingPathComponent("Sources/GenieMenuBar")
        let appFiles = try sourceFiles(in: app)
        let direct = ["engine.retryHolds", "engine.pollReplies", "engine.refreshLock", "applyChatList(", "func loadChats(", "poller.run(", "waitForInitialChatList("]
        for url in appFiles {
            let text = try String(contentsOf: url, encoding: .utf8)
            for name in direct where text.contains(name) {
                offenders.append("\(url.lastPathComponent) \(name)")
            }
            let launches = text.components(separatedBy: "GenieRuntimeLauncher.launch(").count - 1
            if url.lastPathComponent == "GenieController.swift" && launches != 1 {
                offenders.append("GenieController.swift launch \(launches)")
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testNewSchedulerTestsDoNotSleep() throws {
        let root = repoRoot().appendingPathComponent("Tests")
        let taskSleep = "Task" + ".sleep"
        let threadSleep = "Thread" + ".sleep"
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("Tests を読めない")
        }
        var offenders: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(taskSleep) || text.contains(threadSleep) || text.containsEmptySpin() {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [])
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

private extension String {
    /// 中身が空の while を探す。
    func containsEmptySpin() -> Bool {
        let pattern = "while[^{\\n]*\\{\\s*\\}"
        return range(of: pattern, options: .regularExpression) != nil
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
