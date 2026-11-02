import Foundation

/// 停止を、controller と poller と Engine で共有する。
package final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var actions: [() -> Void] = []

    package init() {}

    package func stop() {
        let pending: [() -> Void]
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        pending = actions
        actions = []
        lock.unlock()
        for action in pending {
            action()
        }
    }

    package var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// すでに止まっていれば、その場で呼ぶ。
    package func onStop(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if stopped {
            lock.unlock()
            action()
            return
        }
        actions.append(action)
        lock.unlock()
    }
}
