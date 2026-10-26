import Foundation

enum ProcessRunner {
    struct Output {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    static func run(executable: String, arguments: [String]) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: blocking(executable: executable, arguments: arguments))
            }
        }
    }

    private static func blocking(executable: String, arguments: [String]) -> Output {
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
            return Output(stdout: "", stderr: "", exitCode: -1)
        }
        process.waitUntilExit()
        group.wait()
        return Output(stdout: box.stdout, stderr: box.stderr, exitCode: process.terminationStatus)
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

enum WatchProcess {
    static func run(
        box: ProcessBox,
        executable: String,
        arguments: [String],
        onLine: @escaping @Sendable (String) async -> Void
    ) async -> Int32 {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        async let exitCode: Int32 = withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let code = blocking(box: box, executable: executable, arguments: arguments) { line in
                    continuation.yield(line)
                }
                continuation.finish()
                cont.resume(returning: code)
            }
        }
        for await line in stream {
            await onLine(line)
        }
        return await exitCode
    }

    private static func blocking(
        box: ProcessBox,
        executable: String,
        arguments: [String],
        yield: (String) -> Void
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
        var pending = Data()
        let handle = out.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            if pending.count > 1_000_000 {
                pending.removeAll(keepingCapacity: false)
                continue
            }
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending.subdata(in: 0..<newline)
                pending.removeSubrange(0...newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    yield(line)
                }
            }
        }
        process.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        return process.terminationStatus
    }
}
