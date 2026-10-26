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

    package init() {}

    package func begin(_ process: Process) {
        lock.lock()
        self.process = process
        let stop = stopRequested
        lock.unlock()
        if stop {
            process.terminate()
        }
    }

    package func terminate() {
        lock.lock()
        stopRequested = true
        let process = self.process
        lock.unlock()
        process?.terminate()
    }

    package func resetStop() {
        lock.lock()
        stopRequested = false
        process = nil
        lock.unlock()
    }
}

package enum WatchDirective {
    case next
    case stop
}

package enum WatchProcess {
    package static func run(
        box: ProcessBox,
        executable: String,
        arguments: [String],
        onChunk: @escaping @Sendable (WatchChunk) async -> WatchDirective
    ) async -> Int32 {
        let (stream, continuation) = AsyncStream.makeStream(of: WatchChunk.self, bufferingPolicy: .unbounded)
        async let exitCode: Int32 = withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let code = blocking(box: box, executable: executable, arguments: arguments) { chunk in
                    continuation.yield(chunk)
                }
                continuation.finish()
                cont.resume(returning: code)
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
        return await exitCode
    }

    private static func blocking(
        box: ProcessBox,
        executable: String,
        arguments: [String],
        yield: (WatchChunk) -> Void
    ) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        err.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        do {
            try process.run()
        } catch {
            return -1
        }
        box.begin(process)
        var splitter = WatchSplitter()
        let handle = out.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            for event in splitter.append(chunk) {
                yield(event)
            }
        }
        process.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        return process.terminationStatus
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
