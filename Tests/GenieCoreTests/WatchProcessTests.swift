import XCTest
@testable import GenieCore

final class WatchProcessTests: XCTestCase {
    func testAsyncStreamDeliversBeforeTheProducerFinishes() async {
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .unbounded)
        let gate = DispatchSemaphore(value: 0)
        async let deliveredInTime: Bool = withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                continuation.yield(1)
                let arrived = gate.wait(timeout: .now() + 2) == .success
                continuation.finish()
                cont.resume(returning: arrived)
            }
        }
        for await _ in stream {
            gate.signal()
            break
        }
        let arrived = await deliveredInTime
        XCTAssertTrue(arrived)
    }

    func testStdinStaysOpenLongEnoughToEmit() async throws {
        let script = try writeScript("""
        #!/usr/bin/env python3
        import os, select, sys, threading, time
        def die():
            time.sleep(2.5)
            os._exit(9)
        threading.Thread(target=die, daemon=True).start()
        ready, _, _ = select.select([sys.stdin], [], [], 0.5)
        if ready:
            sys.stderr.write("got_data" + chr(10))
            sys.exit(0)
        sys.stdout.write('{"id":4,"guid":"g","chat_id":1,"is_from_me":false,"text":"n","created_at":"t"}' + chr(10))
        sys.stdout.flush()
        time.sleep(30)
        """)
        let box = ProcessBox()
        let started = Date()
        let result = await WatchProcess.run(box: box, executable: script, arguments: []) { chunk in
            if case .line = chunk { return .stop }
            return .next
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertGreaterThanOrEqual(result.lines, 1)
        XCTAssertFalse(result.stderrTail.contains("got_data"))
        XCTAssertEqual(result.reason, WatchEndReason.stoppedByApp)
        #if canImport(Darwin)
        XCTAssertEqual(result.signal, 15)
        XCTAssertTrue(result.logDetail(rowid: 1).contains("exit=-"))
        XCTAssertFalse(result.logDetail(rowid: 1).contains("exit=15"))
        #endif
    }

    func testStderrFloodDoesNotBlockTheBacklogLine() async throws {
        let script = try writeScript("""
        #!/usr/bin/env python3
        import os, sys, threading, time
        def die():
            time.sleep(2.5)
            os._exit(9)
        threading.Thread(target=die, daemon=True).start()
        sys.stderr.write("e" * 300000)
        sys.stderr.flush()
        sys.stdout.write('{"id":7,"guid":"g","chat_id":1,"is_from_me":false,"text":"n","created_at":"t"}' + chr(10))
        sys.stdout.flush()
        time.sleep(30)
        """)
        let box = ProcessBox()
        let started = Date()
        let saw = Flag()
        let result = await WatchProcess.run(box: box, executable: script, arguments: []) { chunk in
            if case .line(let line) = chunk, line.contains("\"id\":7") {
                saw.set()
                return .stop
            }
            return .next
        }
        XCTAssertTrue(saw.get)
        XCTAssertGreaterThanOrEqual(result.lines, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        _ = result
    }

    func testBacklogStaysUpUntilTheAppStopsIt() async throws {
        let script = try writeScript("""
        #!/usr/bin/env python3
        import os, sys, threading, time
        def die():
            time.sleep(4)
            os._exit(9)
        threading.Thread(target=die, daemon=True).start()
        for i in range(1, 401):
            sys.stdout.write('{"id":%d,"guid":"g%d","chat_id":1,"is_from_me":false,"text":"n","created_at":"t"}' % (i, i) + chr(10))
        sys.stdout.flush()
        time.sleep(30)
        """)
        let box = ProcessBox()
        let started = Date()
        let seen = Counter()
        let result = await WatchProcess.run(box: box, executable: script, arguments: []) { chunk in
            if case .line = chunk {
                return seen.increment() >= 400 ? .stop : .next
            }
            return .next
        }
        XCTAssertEqual(seen.current, 400)
        XCTAssertEqual(result.lines, 400)
        XCTAssertEqual(result.reason, WatchEndReason.stoppedByApp)
        XCTAssertGreaterThan(result.maxLineBytes, 10)
        XCTAssertLessThan(result.maxLineBytes, 400)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testExitCodeAndRedactedStderrAreLoggedWithoutTheBody() async throws {
        let script = try writeScript("""
        #!/bin/bash
        /usr/bin/printf '%s\\n' '{"id":1,"guid":"g","chat_id":1,"is_from_me":false,"text":"secret body","created_at":"t"}'
        /usr/bin/printf '%s\\n' 'earlier alice@hidden.example keep-me-out' >&2
        /usr/bin/printf '%s\\n' 'error hello there {"text":"hello there","sender":"bob"} Authorization: Bearer abcDEFghiJKL' >&2
        exit 9
        """)
        let box = ProcessBox()
        let result = await WatchProcess.run(box: box, executable: script, arguments: []) { _ in .next }
        XCTAssertEqual(result.exitCode, 9)
        XCTAssertEqual(result.reason, WatchEndReason.processExited)
        XCTAssertGreaterThanOrEqual(result.lines, 1)
        XCTAssertEqual(result.stderrTail, "error [x] [x] [x] [x] [x] [x] [x]")
        for leaked in ["alice", "example", "hidden", "keep-me-out", "earlier", "hello", "there", "bob", "Bearer", "abcDEF", "Authorization", "text", "sender"] {
            XCTAssertFalse(result.stderrTail.contains(leaked), leaked)
        }
        let harness = Harness()
        let engine = try harness.engine()
        await engine.noteWatchEnded(result)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.lastError, "watch_exited")
        let record = try XCTUnwrap(harness.log.records.last)
        XCTAssertEqual(record.code, "watch_exited")
        let detail = try XCTUnwrap(record.detail)
        XCTAssertTrue(detail.contains("reason=process_exited"))
        XCTAssertTrue(detail.contains("exit=9"))
        XCTAssertTrue(detail.contains("lines="))
        XCTAssertTrue(detail.contains("max_line="))
        XCTAssertTrue(detail.contains("rowid="))
        XCTAssertTrue(detail.contains("stderr=error"))
        for leaked in ["alice", "example", "hello", "there", "bob", "Bearer", "abcDEF", "secret"] {
            XCTAssertFalse(detail.contains(leaked), leaked)
        }
    }

    func testEnglishBodyJsonAndBearerStayOutOfTheLog() {
        let english = LogRedaction.tail("hello there see you tomorrow")
        XCTAssertFalse(english.contains("hello"))
        XCTAssertFalse(english.contains("there"))
        XCTAssertFalse(english.contains("tomorrow"))
        XCTAssertEqual(english, "[x] [x] [x] [x] [x]")

        let json = LogRedaction.tail("{\"text\":\"hello there\",\"sender\":\"bob\"}")
        XCTAssertFalse(json.contains("hello"))
        XCTAssertFalse(json.contains("bob"))
        XCTAssertFalse(json.contains("text"))
        XCTAssertFalse(json.contains("{"))

        let bearer = LogRedaction.tail("Authorization: Bearer abcDEFghiJKL")
        XCTAssertFalse(bearer.contains("Bearer"))
        XCTAssertFalse(bearer.contains("abcDEF"))
        XCTAssertFalse(bearer.contains("Authorization"))
        XCTAssertEqual(bearer, "[x] [x] [x]")

        let diagnostic = LogRedaction.tail("Error: permission denied for chat.db")
        XCTAssertEqual(diagnostic, "error permission denied [x] chat.db")
        XCTAssertEqual(LogRedaction.tail("failed timeout\n   \n"), "failed timeout")
    }

    func testSignalExitIsNotShownAsAStatusCode() {
        let detail = WatchRunResult(
            exitCode: -1,
            signal: 15,
            reason: WatchEndReason.stoppedByApp,
            lines: 1,
            maxLineBytes: 3,
            stderrTail: "watch_boom"
        ).logDetail(rowid: 4)
        XCTAssertTrue(detail.contains("exit=-"))
        XCTAssertTrue(detail.contains("signal=15"))
        XCTAssertFalse(detail.contains("exit=15"))
        XCTAssertFalse(detail.contains("exit=-1"))
    }

    func testPausedStopIsLoggedWithoutChangingTheMenuError() async throws {
        let harness = Harness()
        let engine = try harness.engine()
        await engine.noteWatchEnded(WatchRunResult(
            exitCode: -1,
            signal: 15,
            reason: WatchEndReason.stoppedByApp,
            lines: 2,
            maxLineBytes: 8,
            stderrTail: "watch_boom"
        ), updateMenu: false)
        let snap = await engine.snapshot()
        XCTAssertNil(snap.lastError)
        let record = try XCTUnwrap(harness.log.records.last)
        XCTAssertEqual(record.code, "watch_exited")
        XCTAssertEqual(record.level, LogLevel.info.rawValue)
        XCTAssertTrue(record.detail?.contains("reason=stopped_by_app") == true)
    }

    func testStartFailureUsesItsOwnCode() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("genie-missing-\(UUID().uuidString)")
            .path
        let box = ProcessBox()
        let result = await WatchProcess.run(box: box, executable: missing, arguments: []) { _ in .next }
        XCTAssertEqual(result.reason, WatchEndReason.startFailed)
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertNil(result.signal)
        XCTAssertEqual(result.lines, 0)
        let harness = Harness()
        let engine = try harness.engine()
        await engine.noteWatchEnded(result)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.lastError, "watch_start_failed")
        XCTAssertEqual(harness.log.records.last?.code, "watch_start_failed")
    }

    func testUserStopReturnsWithoutWaitingAndStaysMarked() throws {
        let script = try writeScript("""
        #!/usr/bin/env python3
        import os, signal, threading, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        def die():
            time.sleep(2)
            os._exit(0)
        threading.Thread(target=die, daemon=True).start()
        time.sleep(30)
        """)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: script)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.standardInput = Pipe()
        try process.run()
        let box = ProcessBox()
        box.begin(process)
        let started = Date()
        box.stopForUser()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        XCTAssertTrue(box.wasUserStop())
        XCTAssertTrue(box.wasStopRequested())
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertFalse(process.isRunning)
        box.resetStop()
        XCTAssertFalse(box.wasUserStop())
    }

    private func writeScript(_ body: String) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("genie-watch-\(UUID().uuidString).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
    var get: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
