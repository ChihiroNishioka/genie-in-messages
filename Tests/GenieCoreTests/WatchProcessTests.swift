import XCTest
@testable import GenieCore

final class WatchProcessTests: XCTestCase {
    func testAsyncStreamDeliversBeforeTheProducerFinishes() async {
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .unbounded)
        async let done: Int = withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            DispatchQueue.global().async {
                continuation.yield(1)
                Thread.sleep(forTimeInterval: 0.6)
                continuation.finish()
                cont.resume(returning: 0)
            }
        }
        let started = Date()
        var first: TimeInterval?
        for await _ in stream {
            if first == nil { first = Date().timeIntervalSince(started) }
        }
        _ = await done
        XCTAssertLessThan(first ?? 9, 0.3)
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
        echo 'watch_boom +819012345678 id 12345' >&2
        exit 9
        """)
        let box = ProcessBox()
        let result = await WatchProcess.run(box: box, executable: script, arguments: []) { _ in .next }
        XCTAssertEqual(result.exitCode, 9)
        XCTAssertEqual(result.reason, WatchEndReason.processExited)
        XCTAssertGreaterThanOrEqual(result.lines, 1)
        XCTAssertTrue(result.stderrTail.contains("watch_boom"))
        XCTAssertFalse(result.stderrTail.contains("8190"))
        XCTAssertFalse(result.stderrTail.contains("12345"))
        XCTAssertFalse(result.stderrTail.contains("+"))
        XCTAssertFalse(result.stderrTail.contains("secret"))
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
        XCTAssertTrue(detail.contains("watch_boom"))
        XCTAssertFalse(detail.contains("secret"))
        XCTAssertFalse(detail.contains("8190"))
        XCTAssertFalse(detail.contains("12345"))
    }

    func testStartFailureUsesItsOwnCode() async throws {
        let harness = Harness()
        let engine = try harness.engine()
        await engine.noteWatchEnded(WatchRunResult(
            exitCode: -1,
            signal: nil,
            reason: WatchEndReason.startFailed,
            lines: 0,
            maxLineBytes: 0,
            stderrTail: ""
        ))
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.lastError, "watch_start_failed")
        XCTAssertEqual(harness.log.records.last?.code, "watch_start_failed")
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
