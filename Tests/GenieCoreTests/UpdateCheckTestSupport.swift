import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GenieCore

actor ScriptedReleaseTransport: ReleaseTransport {
    enum Step {
        case response(ReleaseHTTPResponse)
        case transportFailure
    }

    private var steps: [Step]
    private(set) var requests: [URLRequest] = []

    init(_ steps: [Step]) { self.steps = steps }

    func send(_ request: URLRequest) async throws -> ReleaseHTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw ScriptedTransportFailure() }
        switch steps.removeFirst() {
        case .response(let response): return response
        case .transportFailure: throw ScriptedTransportFailure()
        }
    }
}

struct ScriptedTransportFailure: Error {}

actor ScriptedReleaseFetcher: ReleaseFetching {
    enum Step {
        case immediate(ReleaseFetchResult)
        case gated
    }

    private var steps: [Step]
    private(set) var calls = 0
    private var pending: [CheckedContinuation<ReleaseFetchResult, Never>] = []
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(_ steps: [Step]) { self.steps = steps }

    func fetch() async -> ReleaseFetchResult {
        calls += 1
        let ready = callWaiters.filter { $0.0 <= calls }
        callWaiters.removeAll { $0.0 <= calls }
        for (_, waiter) in ready { waiter.resume() }
        guard !steps.isEmpty else { return .success([]) }
        switch steps.removeFirst() {
        case .immediate(let result): return result
        case .gated:
            return await withCheckedContinuation { pending.append($0) }
        }
    }

    func waitForCalls(_ target: Int) async {
        guard calls < target else { return }
        await withCheckedContinuation { callWaiters.append((target, $0)) }
    }

    func finishNext(_ result: ReleaseFetchResult) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: result)
    }
}

final class MutableUpdateClock: GenieClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }

    func sleep(seconds: Double) async throws {}
}

actor MemoryUpdateSkipStore: SkipStore {
    private(set) var raw: String?
    private(set) var writes: [String] = []

    func read() async -> Any? { raw }

    func write(_ value: String) async {
        raw = value
        writes.append(value)
    }
}

actor RecordingUpdateLog: UpdateCheckLogging {
    private(set) var events: [UpdateCheckLogEvent] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record(_ event: UpdateCheckLogEvent) {
        events.append(event)
        let ready = waiters.filter { $0.0 <= events.count }
        waiters.removeAll { $0.0 <= events.count }
        for (_, waiter) in ready { waiter.resume() }
    }

    func waitForEvents(_ target: Int) async {
        guard events.count < target else { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}

func updateCheckVersion(_ value: String) -> ReleaseVersion {
    guard let version = ReleaseVersion(raw: value) else { fatalError("test version is valid") }
    return version
}

func updateCheckBuild(_ value: String = "1.1.0") -> UpdateBuild {
    AppVersion.updateBuild(info: ["GenieReleaseVersion": value, "GenieGitCommit": "fe7cf02"])
}

func updateCheckSuccess(_ tag: String) -> ReleaseFetchResult {
    .success([ReleaseEntry(tag: tag, draft: false, prerelease: false)])
}

extension UpdateMenuRow {
    var displayText: String {
        switch self {
        case .label(let text), .action(let text, _): text
        }
    }

    var action: UpdateAction? {
        guard case .action(_, let action) = self else { return nil }
        return action
    }
}
