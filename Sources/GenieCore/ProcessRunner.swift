import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

package enum ProcessRunner {
    package struct Output {
        package var stdout: String
        package var stderr: String
        package var exitCode: Int32
        package var timedOut: Bool
    }

    package static func run(executable: String, arguments: [String], timeout: TimeInterval) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: blocking(executable: executable, arguments: arguments, timeout: timeout))
            }
        }
    }

    private static func blocking(executable: String, arguments: [String], timeout: TimeInterval) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let box = CollectedOutput()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.setStdout(out.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            box.setStderr(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        do {
            try process.run()
        } catch {
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            group.wait()
            return Output(stdout: "", stderr: "", exitCode: -1, timedOut: false)
        }
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        var timedOut = false
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < grace {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        group.wait()
        return Output(
            stdout: box.stdout,
            stderr: box.stderr,
            exitCode: process.terminationStatus,
            timedOut: timedOut
        )
    }
}

private final class CollectedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func setStdout(_ data: Data) {
        lock.lock()
        out = data
        lock.unlock()
    }

    func setStderr(_ data: Data) {
        lock.lock()
        err = data
        lock.unlock()
    }

    var stdout: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: out, encoding: .utf8) ?? ""
    }

    var stderr: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: err, encoding: .utf8) ?? ""
    }
}

package final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopRequested = false
    private var userStop = false
    /// 終了で立てる。`resetStop` では消さない。
    private var sealed = false

    package init() {}

    package func begin(_ process: Process) {
        lock.lock()
        let stop = stopRequested
        let wait = sealed
        if !stop {
            self.process = process
        }
        lock.unlock()
        if stop {
            if wait {
                Self.finish(process, timeout: 0.5)
            } else {
                stopProcess(process)
            }
        }
    }

    /// 一時停止。あとから再開しても、勝手に落ちたことにはしない。呼び出し側は待たない。
    package func stopForUser() {
        lock.lock()
        userStop = true
        lock.unlock()
        terminate()
    }

    /// アプリ終了。SIGTERM のあと、残っていれば SIGKILL を送り、子が止まるまで待つ。
    /// このあと `resetStop` されても、新しい子は起動しない。
    package func stopForUserAndWait(timeout: TimeInterval = 0.5) {
        lock.lock()
        userStop = true
        stopRequested = true
        sealed = true
        let process = self.process
        lock.unlock()
        guard let process else { return }
        Self.finish(process, timeout: timeout)
    }

    package func terminate() {
        lock.lock()
        stopRequested = true
        let process = self.process
        lock.unlock()
        guard let process else { return }
        stopProcess(process)
    }

    /// SIGTERM のあと、別スレッドで残っていれば SIGKILL。呼び出し側は待たない。
    private func stopProcess(_ process: Process) {
        DispatchQueue.global(qos: .userInitiated).async {
            Self.finish(process, timeout: 0.5)
        }
    }

    /// 呼び出し側のスレッドで SIGTERM を送り、期限までに残っていれば SIGKILL して止まるまで待つ。
    private static func finish(_ process: Process, timeout: TimeInterval) {
        process.terminate()
        let pid = process.processIdentifier
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(pid, SIGKILL)
            let killed = Date().addingTimeInterval(1)
            while process.isRunning && Date() < killed {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    package func wasStopRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    package func wasUserStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return userStop
    }

    package func resetStop() {
        lock.lock()
        if !sealed {
            stopRequested = false
            userStop = false
        }
        process = nil
        lock.unlock()
    }
}

package enum WatchDirective {
    case next
    case stop
}

package enum WatchEndReason {
    package static let processExited = "process_exited"
    package static let stoppedByApp = "stopped_by_app"
    package static let startFailed = "start_failed"
}

package struct WatchRunResult: Equatable, Sendable {
    package var exitCode: Int32
    package var signal: Int32?
    package var reason: String
    package var lines: Int
    package var maxLineBytes: Int
    package var stderrTail: String

    package func logDetail(rowid: Int64) -> String {
        let exitText = signal == nil ? String(exitCode) : "-"
        let signalText = signal.map(String.init) ?? "-"
        return "exit=\(exitText) signal=\(signalText) reason=\(reason) lines=\(lines) max_line=\(maxLineBytes) rowid=\(rowid) stderr=\(stderrTail)"
    }
}

package enum WatchProcess {
    package static func run(
        box: ProcessBox,
        executable: String,
        arguments: [String],
        onChunk: @escaping @Sendable (WatchChunk) async -> WatchDirective
    ) async -> WatchRunResult {
        let (stream, continuation) = AsyncStream.makeStream(of: WatchChunk.self, bufferingPolicy: .unbounded)
        async let outcome: WatchRunResult = withCheckedContinuation { (cont: CheckedContinuation<WatchRunResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = blocking(box: box, executable: executable, arguments: arguments) { chunk in
                    continuation.yield(chunk)
                }
                continuation.finish()
                cont.resume(returning: result)
            }
        }
        var stop = false
        for await chunk in stream {
            if stop { continue }
            let directive = await onChunk(chunk)
            if directive == .stop {
                stop = true
                box.terminate()
            }
        }
        return await outcome
    }

    /// 標準出力と標準エラーを別スレッドで読み切る。標準入力の書き込み側は、
    /// 子が終わるまで閉じない。imsg が 256 行で終了する、というのは仮説で、実機では未確認。
    private static func blocking(
        box: ProcessBox,
        executable: String,
        arguments: [String],
        yield: (WatchChunk) -> Void
    ) -> WatchRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let input = Pipe()
        let out = Pipe()
        let err = Pipe()
        process.standardInput = input
        process.standardOutput = out
        process.standardError = err
        let stdinWrite = input.fileHandleForWriting
        let heldStdin = dup(stdinWrite.fileDescriptor)
        defer {
            if heldStdin >= 0 { close(heldStdin) }
            try? stdinWrite.close()
        }

        let tail = TailBuffer(limit: 8_192)
        let stderrDone = DispatchGroup()
        stderrDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stderrDone.leave() }
            let handle = err.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                tail.append(chunk)
            }
        }

        do {
            try process.run()
        } catch {
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            stderrDone.wait()
            return WatchRunResult(
                exitCode: -1,
                signal: nil,
                reason: WatchEndReason.startFailed,
                lines: 0,
                maxLineBytes: 0,
                stderrTail: ""
            )
        }
        box.begin(process)

        var splitter = WatchSplitter()
        var lines = 0
        var maxLineBytes = 0
        func note(_ count: Int) {
            lines += 1
            if count > maxLineBytes { maxLineBytes = count }
        }
        let handle = out.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            for event in splitter.append(chunk) {
                switch event {
                case .line(let line):
                    note(line.utf8.count)
                case .tooLarge:
                    note(WatchSplitter.maxBytes)
                }
                yield(event)
            }
        }
        for event in splitter.finish() {
            switch event {
            case .line(let line):
                note(line.utf8.count)
            case .tooLarge:
                note(WatchSplitter.maxBytes)
            }
            yield(event)
        }
        process.waitUntilExit()
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        stderrDone.wait()

        var exitCode = process.terminationStatus
        var signal: Int32?
        #if canImport(Darwin)
        if process.terminationReason == .uncaughtSignal {
            signal = process.terminationStatus
            exitCode = -1
        }
        #endif
        let reason = box.wasStopRequested() ? WatchEndReason.stoppedByApp : WatchEndReason.processExited
        let stderrText = tail.string()
        return WatchRunResult(
            exitCode: exitCode,
            signal: signal,
            reason: reason,
            lines: lines,
            maxLineBytes: maxLineBytes,
            stderrTail: LogRedaction.tail(stderrText)
        )
    }
}

private final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > limit {
            data.removeFirst(data.count - limit)
        }
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let data = self.data
        lock.unlock()
        return String(decoding: data, as: UTF8.self)
    }
}

package enum SendLaunch {
    package static func interpret(stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) -> Result<SendReceipt, SendFailure> {
        if timedOut {
            return .failure(.uncertain)
        }
        if exitCode == -1 && stdout.isEmpty && stderr.isEmpty {
            return .failure(.notStarted)
        }
        return SendResultParser.parse(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }
}
